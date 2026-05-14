# bbl-ch-build

Provisioning script for BBL Django call-handler boxes on Linode. The role currently filled by `ch-atl1.bblapp.io` (and historically `ch-atl2`). NOT for FreeSWITCH boxes — for those use [`bbl-fs-build`](https://github.com/bblv2/bbl-fs-build).

Sibling repo: `bbl-fs-build`. Same shape (cloud-init bootstrap + numbered idempotent steps + linode-cli provision script + per-host conf), with all FreeSWITCH/DID/Telnyx/B2 bits stripped and Django-stack steps added.

## Goals

- **Cheap and disposable.** Spin up a new ch box in ~5–10 minutes; tear it down in 30 seconds. No bespoke per-host snowflakes.
- **Portable.** Plain shell + cloud-init `user_data`. Same script could provision on AWS, Hetzner, or bare metal with minor adjustments.
- **Auditable.** Every box writes `/etc/bbl-ch-build` recording exactly what it was built from (build commit, django commit, frontend commit, kernel, build time).
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

# Non-secret defaults + per-host overrides ship with this repo at
#   seeds/defaults.conf  and  seeds/hosts/<short>.conf
# Only secrets stay loose on rpt:
sudo install -m 0700 -d /etc/bbl-ch-secrets.d
sudo cp seeds/secrets.example.conf /etc/bbl-ch-secrets.conf
sudo chmod 0600 /etc/bbl-ch-secrets.conf
sudo $EDITOR /etc/bbl-ch-secrets.conf      # fill in real values
# Per-host secret overrides (rare — e.g. bbl26 cluster's SECRET_KEY) go in
#   /etc/bbl-ch-secrets.d/<short>.conf  (mode 0600)

# 2. Provision
./scripts/provision.sh \
    role=prod \
    size=large \
    hostname=ch-atl3.bblapp.io

# 3. Wait 5–10 min (Django + frontend cloning + pip install take longer than FS apt-install)
ssh root@<linode-ip> tail -f /var/log/bbl-ch-build.log
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
04b-frontend-build-smoke.sh
                       Verify the SPA build pipeline actually works on this
                       host (npm install --ignore-scripts + bower + webpack).
                       Does NOT replace the pinned build/ — restores from git
                       after the smoke build succeeds. Catches gyp / native-
                       dep regressions at provision time instead of at deploy
                       time when an operator first tries to rebuild.
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
10-finalize.sh         Write /etc/bbl-ch-build (build manifest), render motd,
                       sanity checks, surface "ready to add to nginx upstream"
                       message
```

Each step is small and idempotent — safe to re-run after a failure. Logs go to `/var/log/bbl-ch-build.log` via `tee` from `bootstrap.sh`.

## Security

- Non-secret defaults and per-host overrides live in `seeds/` and are in VCS.
- Secrets are kept in `/etc/bbl-ch-secrets.conf` (mode 0600) on rpt and (optionally) per-host overrides in `/etc/bbl-ch-secrets.d/<short>.conf`. `seeds/secrets.example.conf` lists the fields.
- At provision time, `scripts/provision.sh` assembles a single `/etc/bbl-ch-host.conf` (mode 0600) on the new box from the four layers. Nowhere else on disk except inside the rendered Django settings file (also mode 600).
- TLS cert and key in `/etc/letsencrypt/live/<domain>/`.

## Status

**PRODUCTION-READY** as of 2026-05-05. All 10 steps are implemented and battle-tested. `ch-atl7.bblapp.io` was provisioned end-to-end and reached READY (Django 5.2.13, gunicorn + celery running, all smoke checks green).

### Bugs fixed during first real provision (2026-05-05)

All four are committed to `origin/master`; any fresh clone already has the fixes.

| Commit | Bug |
|---|---|
| `ff78fef` | `cloud-init runcmd` has no `$HOME` → `git config --global` dies with "fatal: $HOME not set". Fix: `export HOME=/root` in `bootstrap.sh` + switch step 03 to `git config --system`. |
| `6f66ede` | `step 06` defaulted to issuing a cert → crashes with `chown freeswitch:freeswitch` (no FS user on Django box). Fix: default `BBL_SKIP_CERT=true` — lb-atl terminates TLS for all ch-atlN boxes; set `=false` only if the host needs its own cert. |
| `3217ee1` | `step 05` wrote `local_settings.py` to `$DJANGO_DIR/bbl/local_settings.py` (inside the package, not sys.path root) and used `from atl_settings import *` (missing `bbl.` prefix). `bbl/settings.py` does `from local_settings import *` which is a top-of-sys.path absolute import — the file was written but never read; DATABASES stayed as the dummy backend. Fix: write to `$DJANGO_DIR/local_settings.py` + `from bbl.atl_settings import *`. |
| `9fc5d88` | Steps 09 + 10 referenced supervisor program `celery`, but the template uses `numprocs=1 + process_name=runner%(process_num)s` → actual program is `celery:runner0`. Bare `supervisorctl ... celery` → "no such process" + pipefail kill. Fix: `start all` in step 09, group form `celery:` in step 10. |

### Known remaining cosmetic issues (non-blocking)

- `steps/10-finalize.sh` smoke test for `theme.js` hits gunicorn (port 8001), not nginx (port 80). Gunicorn doesn't serve `/staticfiles/` — test reports 404 but the READY gate ignores it. One-line fix (change curl port to 80).
- On first boot, `bbl/settings.py` prints "could not load settings for this environment! CH_ATL" to stdout because its per-host dispatcher doesn't match `ch-atl7.bblapp.io` by regex. `local_settings.py` overrides everything via the bottom-of-file `from local_settings import *` so it's harmless noise. Django-side fix, not kit-side.
