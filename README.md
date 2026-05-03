# bbl-build-ch

Provisioning script for BBL Django call-handler boxes on Linode. The role currently filled by `ch-atl1.bblapp.io` (and historically `ch-atl2`). NOT for FreeSWITCH boxes — for those use [`bbl-fs-build`](https://github.com/bblv2/bbl-fs-build).

Sibling repo: `bbl-fs-build`. Same shape (cloud-init bootstrap + numbered idempotent steps + linode-cli provision script + per-host conf), with all FreeSWITCH/DID/Telnyx/B2 bits stripped and Django-stack steps added.

## Goals

- **Cheap and disposable.** Spin up a new ch box in ~5–10 minutes; tear it down in 30 seconds. No bespoke per-host snowflakes.
- **Portable.** Plain shell + cloud-init `user_data`. Same script could provision on AWS, Hetzner, or bare metal with minor adjustments.
- **Auditable.** Every box writes `/etc/bbl-build-ch` recording exactly what it was built from (build commit, django commit, frontend commit, kernel, build time).
- **Self-securing.** `ufw` opens only 22/80/443. fail2ban watches sshd. acme.sh issues + auto-renews TLS for the Django domain. Monitor agent auto-registers on https://monitor.rpt.bblapp.io/servers.

## What's on a ch box

- **Django** at `/projects/bbl-django` running on Python 3.11 in venv `/projects/bbl_env_py3`
- **gunicorn** managed by supervisor (4 workers + master, listening 127.0.0.1:8001)
- **celery worker + embedded beat** (`-B`) managed by supervisor
- **bblfrontend** AngularJS SPA at `/opt/bblfrontend/build/` — git-checked-out at the prod-tagged commit
- **nginx** locally for static files (frontend SPA, Django staticfiles); customer-facing TLS terminates at lb-atl
- **PostgreSQL client tools** (no local DB; the shared bbl2022 lives on lb-atl)
- **Redis client tools** (no local Redis; uses lb-atl)

## Sizes (same SKU table as bbl-fs-build)

```
small   g6-standard-2     2c  4G   $24/mo    dev / staging
medium  g6-dedicated-4    4c  8G   $72/mo    small workloads
large   g6-dedicated-8    8c 16G   $144/mo   standard prod
xlarge  g6-dedicated-16  16c 32G   $288/mo   high-headroom prod
```

Pick to match expected load. ch-atl1 today is roughly large-equivalent.

## Provisioning a new box

```bash
# 1. Prerequisites (one-time on operator's machine — same as bbl-fs-build)
brew install linode-cli jq                # macOS
linode-cli configure                       # paste API token
sudo cp host.conf.example /etc/bbl-build-ch.host.conf
sudo $EDITOR /etc/bbl-build-ch.host.conf  # fill in shared secrets

# 2. Provision
./scripts/provision.sh \
    role=prod \
    size=large \
    hostname=ch-atl3.bblapp.io

# 3. Wait 5–10 min (Django + frontend cloning + pip install take longer than FS apt-install)
ssh root@<linode-ip> tail -f /var/log/bbl-build-ch.log
```

The provision script will print the new Linode's public IPv4 (you'll need this for DNS + the lb-atl nginx upstream entry).

## What the build does (steps in order)

```
01-base.sh             OS hardening: apt update, debug tools, haveged, chrony,
                       locale, timezone, sysctls, fail2ban with sshd jail
02-django-deps.sh      apt install python3.11, supervisor, nginx, postgresql-
                       client, redis-tools, build-essential, nodejs, npm, bower
03-django-clone.sh     git clone bbl-django @ BBL_DJANGO_BRANCH; create
                       /projects/bbl_env_py3 venv; pip install requirements.txt
04-frontend-clone.sh   git clone bblfrontend @ BBL_FRONTEND_REF (tagged commit
                       captured from prod ch-atl1's build dir); ready-to-serve,
                       no rebuild
05-django-config.sh    Render /etc/supervisor/conf.d/{bbl,celery}.conf, nginx
                       site config, host-specific Django settings file
                       (bbl/<hostname>.py with DATABASES + secrets from
                       host.conf)
06-cert.sh             acme.sh + Let's Encrypt cert for the Django domain
07-firewall.sh         ufw rules: SSH/HTTP/HTTPS only; everything else dropped
08-monitor-collector.sh
                       Install /usr/local/bin/mcp-collector.sh + cron entry;
                       box auto-appears on https://monitor.rpt.bblapp.io/servers
09-django-init.sh      collectstatic (with the nuke-pattern from the chb-atl
                       2026-05-03 lesson — sudo rm -rf staticfiles/admin first
                       to defeat the mtime-skip behavior); manage.py migrate
                       --noinput WITH the bridges.0049 --fake step (see
                       feedback memory feedback_bbl_prod_schema_drift.md and
                       starry-marinating-sunrise plan section 0e-fix);
                       supervisorctl start bbl celery; smoke test
10-finalize.sh         Write /etc/bbl-build-ch (build manifest), render motd,
                       sanity checks, surface "ready to add to nginx upstream"
                       message
```

Each step is small and idempotent — safe to re-run after a failure. Logs go to `/var/log/bbl-build-ch.log` via `tee` from `bootstrap.sh`.

## Security

- `host.conf` is **never committed**. `.gitignore` blocks it. `host.conf.example` shows what fields exist with empty values.
- Django SECRET_KEY, DB password, Redis URL, Stripe keys, Mailgun key, Telnyx user/token live in `/etc/bbl-build-ch-host.conf` (mode 600). Nowhere else on disk except inside the rendered Django settings file (also mode 600).
- TLS cert and key in `/etc/letsencrypt/live/<domain>/`.

## Status

**SCAFFOLDED — stubs, not production-ready.**

Adapted-from-bbl-fs-build files (1:1 patterns, work as-is): `bootstrap.sh`, `setup.sh`, `scripts/provision.sh` (TODO: rename references), `conf/linode-sizes.conf`, `host.conf.example` (rewritten for Django), `steps/01-base.sh` (kept), `steps/06-cert.sh` (renamed from old 04), `steps/07-firewall.sh` (renamed; needs port edits), `steps/08-monitor-collector.sh` (renamed from old 06b), `steps/10-finalize.sh` (renamed from old 07; needs Django-shape).

NEW step stubs (need fleshing out before first real provision):
- `steps/02-django-deps.sh`
- `steps/03-django-clone.sh`
- `steps/04-frontend-clone.sh`
- `steps/05-django-config.sh`
- `steps/09-django-init.sh`

See each stub's TODO comments for what each needs to do.
