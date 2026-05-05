#!/bin/bash
# 05-django-config.sh — render supervisor + nginx + per-host Django settings.
# Idempotent: re-running overwrites with current template values.
set -euo pipefail

source "${BBL_HOST_CONF:-/etc/bbl-ch-host.conf}"

: "${BBL_HOSTNAME:?BBL_HOSTNAME not set}"
: "${BBL_DB_HOST:?BBL_DB_HOST not set in host.conf}"
: "${BBL_DB_NAME:?BBL_DB_NAME not set in host.conf}"
: "${BBL_DB_USER:?BBL_DB_USER not set in host.conf}"
: "${BBL_DB_PASSWORD:?BBL_DB_PASSWORD not set in host.conf}"
: "${BBL_DJANGO_SECRET_KEY:?BBL_DJANGO_SECRET_KEY not set in host.conf}"

# Defaults that can be overridden in host.conf
BBL_GUNICORN_BIND="${BBL_GUNICORN_BIND:-127.0.0.1:8001}"
BBL_GUNICORN_WORKERS="${BBL_GUNICORN_WORKERS:-9}"
BBL_RUN_BEAT="${BBL_RUN_BEAT:-false}"   # SAFE DEFAULT: no beat; flip to true later
BBL_DOMAIN_ALIASES="${BBL_DOMAIN_ALIASES:-}"
BBL_ROLE="${BBL_ROLE:-prod}"

# SESSION_COOKIE_DOMAIN: defaults from role so operators only override for unusual setups.
# beta → bblapp.io (lbb-atl/beta.bblapp.io frontend domain)
# prod → brandedbridgeline.com (lb-atl/app.brandedbridgeline.com customer domain)
if [[ -z "${BBL_SESSION_COOKIE_DOMAIN:-}" ]]; then
    if [[ "$BBL_ROLE" == "beta" ]]; then
        BBL_SESSION_COOKIE_DOMAIN=".bblapp.io"
    else
        BBL_SESSION_COOKIE_DOMAIN=".brandedbridgeline.com"
    fi
fi

DJANGO_DIR=/projects/bbl-django
TPL=/usr/src/bbl-ch-build/templates  # same path bootstrap.sh clones to

# ── Critical /projects/bbl symlink ──────────────────────────────────
# Many BBL configs / cron jobs / nginx blocks reference /projects/bbl as
# the project root, but the real code now lives at /projects/bbl-django.
# A symlink keeps both paths working without rewriting every reference.
if [[ ! -L /projects/bbl ]]; then
    if [[ -e /projects/bbl ]]; then
        echo "$0: /projects/bbl exists and isn't a symlink — refusing to overwrite" >&2
        exit 1
    fi
    ln -s /projects/bbl-django /projects/bbl
    echo "==> Created /projects/bbl → /projects/bbl-django symlink"
fi

# Ensure bbl user exists (gunicorn + celery run as this user per supervisor templates)
if ! id bbl >/dev/null 2>&1; then
    useradd --system --shell /bin/bash --home /projects/bbl-django bbl
    echo "==> Created bbl user"
fi
chown -R bbl:bbl "$DJANGO_DIR"

# Django CACHES config has relative-path file caches ('cache' and
# 'slack-cache'). Django resolves them relative to CWD, which depends on
# where manage.py is invoked from. chb-atl has /projects/bbl-django/cache/
# pre-existing — pre-create both here so cache backends don't crash on first
# write.
install -d -m 0700 -o bbl -g bbl "$DJANGO_DIR/cache" "$DJANGO_DIR/slack-cache"

# ── Log directories ─────────────────────────────────────────────────
mkdir -p /var/log/supervisor

# Django LOGGING config (in atl_settings.py) expects /var/log/bbl/{accounts,
# general,requests}.log. Without the dir, app boot fails with
# "ValueError: Unable to configure handler 'accounts_log_file'".
mkdir -p /var/log/bbl
chown bbl:bbl /var/log/bbl
chmod 0775 /var/log/bbl

# ── Supervisor configs ──────────────────────────────────────────────

if [[ "$BBL_RUN_BEAT" == "true" ]]; then
    BBL_CELERY_BEAT_FLAG="-B"
    echo "==> celery beat ENABLED on this host (BBL_RUN_BEAT=true)"
else
    BBL_CELERY_BEAT_FLAG=""
    echo "==> celery beat DISABLED on this host (BBL_RUN_BEAT=false). Flip via host.conf + re-run step or edit /etc/supervisor/conf.d/celery.conf manually."
fi

sed -e "s|__BBL_GUNICORN_BIND__|$BBL_GUNICORN_BIND|g" \
    -e "s|__BBL_GUNICORN_WORKERS__|$BBL_GUNICORN_WORKERS|g" \
    "$TPL/bbl-supervisor.conf.template" > /etc/supervisor/conf.d/bbl.conf

sed -e "s|__BBL_CELERY_BEAT_FLAG__|$BBL_CELERY_BEAT_FLAG|g" \
    "$TPL/celery-supervisor.conf.template" > /etc/supervisor/conf.d/celery.conf

echo "==> Wrote /etc/supervisor/conf.d/{bbl,celery}.conf"

# ── nginx site ──────────────────────────────────────────────────────
sed -e "s|__BBL_HOSTNAME__|$BBL_HOSTNAME|g" \
    -e "s|__BBL_DOMAIN_ALIASES__|$BBL_DOMAIN_ALIASES|g" \
    "$TPL/nginx-bbl-site.template" > /etc/nginx/sites-available/bbl

# Enable site (idempotent: ln -sfn replaces existing symlink)
ln -sfn /etc/nginx/sites-available/bbl /etc/nginx/sites-enabled/bbl
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t
systemctl reload nginx
echo "==> nginx site enabled + reloaded"

# ── Django settings — two-file architecture ─────────────────────────
#
# bbl/settings.py has a hostname dispatcher that does Python 3 absolute
# imports.  For ch-atl* hosts it runs: from atl_settings import *
# which finds the TOP-LEVEL atl_settings.py (project root), NOT bbl/atl_settings.py.
# That top-level file is the "role overlay" — written here from host.conf.
#
# Execution order inside settings.py:
#   1. line ~477  : from local_settings import *   ← secrets overlay (this step)
#   2. line  750  : SESSION_COOKIE_DOMAIN = ".brandedbridgeline.com"  (hardcoded)
#   3. line ~841  : from atl_settings import *     ← role overlay (WINS — runs last)
#
# local_settings.py is still needed for:
#   - SECRET_KEY (settings.py never resets it after line 477)
#   - DATABASES fallback for non-ch-atl* hostnames (e.g. ch-test-*) that
#     don't hit the atl_settings branch
#   - Optional per-host secrets (Redis, Stripe, Mailgun, Telnyx, etc.)

# ── Role overlay: atl_settings.py (top-level, wins for ch-atl* hosts) ──
ROLE_SETTINGS="$DJANGO_DIR/atl_settings.py"
cat > "$ROLE_SETTINGS" <<PYSETTINGS
"""Role overlay for $BBL_HOSTNAME ($BBL_ROLE). Written by bbl-ch-build step 05.

settings.py dispatches via hostname: ch-atl* -> from atl_settings import *
Python 3 absolute import finds THIS file (project root) not bbl/atl_settings.py.
bbl/atl_settings.py has production-hard-coded values (bbl2022, .brandedbridgeline.com);
this file layers the host-specific DB and the correct cookie domain for the role.
"""
from bbl.atl_settings import *

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql_psycopg2",
        "NAME": "$BBL_DB_NAME",
        "USER": "$BBL_DB_USER",
        "PASSWORD": "$BBL_DB_PASSWORD",
        "HOST": "$BBL_DB_HOST",
        "PORT": "${BBL_DB_PORT:-5432}",
    }
}
SESSION_COOKIE_DOMAIN = "$BBL_SESSION_COOKIE_DOMAIN"
PYSETTINGS
chmod 600 "$ROLE_SETTINGS"
chown bbl:bbl "$ROLE_SETTINGS"

# ── Secrets overlay: local_settings.py ──────────────────────────────
HOST_SETTINGS="$DJANGO_DIR/local_settings.py"
cat > "$HOST_SETTINGS" <<PYSETTINGS
"""Secrets overlay for $BBL_HOSTNAME. Written by bbl-ch-build step 05.

Loaded by bbl/settings.py at line ~477 (before the hostname dispatcher).
DATABASES and SESSION_COOKIE_DOMAIN here are fallbacks for non-ch-atl* hostnames
(e.g. ch-test-*) that don't hit the atl_settings dispatcher branch.
For ch-atl* nodes, atl_settings.py (role overlay) wins those values instead."""
from bbl.atl_settings import *

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql_psycopg2",
        "NAME": "$BBL_DB_NAME",
        "USER": "$BBL_DB_USER",
        "PASSWORD": "$BBL_DB_PASSWORD",
        "HOST": "$BBL_DB_HOST",
        "PORT": "${BBL_DB_PORT:-5432}",
    }
}
SECRET_KEY = "$BBL_DJANGO_SECRET_KEY"
SESSION_COOKIE_DOMAIN = "$BBL_SESSION_COOKIE_DOMAIN"
PYSETTINGS

# Optional secrets — append only if set in host.conf
[[ -n "${BBL_REDIS_URL:-}" ]] && echo "REDIS_URL = '$BBL_REDIS_URL'" >> "$HOST_SETTINGS"
[[ -n "${BBL_STRIPE_SECRET_KEY:-}" ]] && echo "STRIPE_SECRET_KEY = '$BBL_STRIPE_SECRET_KEY'" >> "$HOST_SETTINGS"
[[ -n "${BBL_STRIPE_PUBLIC_KEY:-}" ]] && echo "STRIPE_PUBLIC_KEY = '$BBL_STRIPE_PUBLIC_KEY'" >> "$HOST_SETTINGS"
[[ -n "${BBL_STRIPE_WEBHOOK_SECRET:-}" ]] && echo "STRIPE_WEBHOOK_SECRET = '$BBL_STRIPE_WEBHOOK_SECRET'" >> "$HOST_SETTINGS"
[[ -n "${BBL_MAILGUN_API_KEY:-}" ]] && echo "MAILGUN_API_KEY = '$BBL_MAILGUN_API_KEY'" >> "$HOST_SETTINGS"
[[ -n "${BBL_MAILGUN_DOMAIN:-}" ]] && echo "MAILGUN_DOMAIN = '$BBL_MAILGUN_DOMAIN'" >> "$HOST_SETTINGS"
[[ -n "${BBL_TELNYX_USER:-}" ]] && echo "TELNYX_USER = '$BBL_TELNYX_USER'" >> "$HOST_SETTINGS"
[[ -n "${BBL_TELNYX_TOKEN:-}" ]] && echo "TELNYX_TOKEN = '$BBL_TELNYX_TOKEN'" >> "$HOST_SETTINGS"
[[ -n "${BBL_BUGCATCHER_DSN:-}" ]] && echo "BUGCATCHER_DSN = '$BBL_BUGCATCHER_DSN'" >> "$HOST_SETTINGS"

chmod 600 "$HOST_SETTINGS"
chown bbl:bbl "$HOST_SETTINGS"

echo "==> Wrote $ROLE_SETTINGS (role: $BBL_ROLE, cookie: $BBL_SESSION_COOKIE_DOMAIN)"
echo "==> Wrote $HOST_SETTINGS (secrets overlay)"

# Sanity: Django can load + see DATABASES
# Run from $DJANGO_DIR so relative paths in settings (cache, staticfiles, etc.)
# resolve correctly. Without the cd, Django uses CWD = wherever setup.sh was
# invoked from (usually /usr/src/bbl-ch-build) and tries to mkdir cache there.
( cd "$DJANGO_DIR" && sudo -u bbl /projects/bbl_env_py3/bin/python manage.py check 2>&1 | tail -5 )

echo "==> 05-django-config complete"
