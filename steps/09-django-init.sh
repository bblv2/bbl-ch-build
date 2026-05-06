#!/bin/bash
# 09-django-init.sh — collectstatic + migrate + supervisor start + smoke test.
#
# Encodes two hard-won lessons from chb-atl 2026-05-03:
#   1. After any Django version change, plain collectstatic --noinput leaves
#      stale admin/* files behind because mtime comparison skips them.
#      Nuke staticfiles/admin first, THEN collectstatic.
#   2. bbl2022 has out-of-band columns on bridges_cdrreport that match what
#      bridges.0049_auto_20240403_1606 wants to ADD. The migration must be
#      --fake'd. See feedback memory feedback_bbl_prod_schema_drift.md.
set -euo pipefail

DJANGO_DIR=/projects/bbl-django
VENV_DIR=/projects/bbl_env_py3
PY="$VENV_DIR/bin/python"

cd "$DJANGO_DIR"

# ── Static assets — two-step ────────────────────────────────────────
echo "==> Nuking stale staticfiles/admin (defeats mtime-skip)"
rm -rf "$DJANGO_DIR/staticfiles/admin"

echo "==> Running collectstatic"
"$PY" manage.py collectstatic --noinput

# Sanity: a Django-5-era admin asset must serve from the freshly-collected dir
test -f "$DJANGO_DIR/staticfiles/admin/js/theme.js" || {
    echo "$0: collectstatic appears incomplete — admin/js/theme.js missing" >&2
    exit 1
}

# ── Migrations — handle the bridges.0049 schema drift ──────────────
echo "==> Running migrate (will fail at bridges.0049 with DuplicateColumn — expected)"
if "$PY" manage.py migrate --noinput; then
    echo "==> migrate succeeded on first try (bbl2022 already had bridges.0049 applied?)"
else
    echo "==> First migrate failed (presumably bridges.0049 DuplicateColumn). Faking it."
    "$PY" manage.py migrate --fake bridges 0049_auto_20240403_1606
    echo "==> Re-running migrate to pick up everything after"
    "$PY" manage.py migrate --noinput
fi

# Verify zero unapplied
unapplied=$("$PY" manage.py showmigrations 2>&1 | grep -c '\[ \]' || true)
if [[ "$unapplied" -ne 0 ]]; then
    echo "$0: $unapplied migrations still unapplied — abort" >&2
    "$PY" manage.py showmigrations 2>&1 | grep '\[ \]'
    exit 1
fi

# ── Start supervisor ────────────────────────────────────────────────
# `reread + update` re-reads conf.d files and adds new program groups.
# The celery template uses numprocs=1 + process_name=runner%(process_num)s,
# so the actual program is `celery:runner0`. Use `start all` to avoid
# coupling this script to the group/child naming, and tolerate
# "already started" since autostart=true on each program means update
# itself starts them. Burned ch-atl7 here.
supervisorctl reread
supervisorctl update
supervisorctl start all 2>&1 | grep -vE 'already started|ERROR \(no such process\)' || true

# ── Smoke test ──────────────────────────────────────────────────────
sleep 3
curl -sk -o /dev/null -w 'gunicorn http=%{http_code}\n' http://127.0.0.1:8001/bbladmin/login/
curl -sk -o /dev/null -w 'theme.js http=%{http_code}\n' http://127.0.0.1/staticfiles/admin/js/theme.js
