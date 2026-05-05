#!/bin/bash
# 10-finalize.sh — write build manifest, render motd, surface "ready" message.
set -euo pipefail

source "${BBL_HOST_CONF:-/etc/bbl-ch-host.conf}"

BUILD_DIR="${BBL_BUILD_DIR:-/usr/src/bbl-ch-build}"
DJANGO_DIR=/projects/bbl-django
FRONTEND_DIR=/opt/bblfrontend

# ── Build manifest ──────────────────────────────────────────────────
build_commit=$(cd "$BUILD_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
django_commit=$(cd "$DJANGO_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
django_branch=$(cd "$DJANGO_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
frontend_commit=$(cd "$FRONTEND_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
frontend_ref=$(cd "$FRONTEND_DIR" && git describe --tags --always 2>/dev/null || echo "unknown")
django_version=$(/projects/bbl_env_py3/bin/python -c 'import django; print(django.__version__)' 2>/dev/null || echo "?")
python_version=$(/projects/bbl_env_py3/bin/python --version 2>&1 | awk '{print $2}')
kernel=$(uname -r)
# Use the group form `celery:` — the celery program runs under group
# `celery:runner0` (numprocs=1 + process_name= renames the child),
# so plain `status celery` returns "no such process" + nonzero exit
# and pipefail kills the script. `|| true` belt-and-suspenders.
celery_running=$(supervisorctl status celery: 2>&1 | head -1 || true)
gunicorn_running=$(supervisorctl status bbl 2>&1 | head -1 || true)

cat > /etc/bbl-ch-build <<MANIFEST
# bbl-ch-build — build manifest
# Auto-generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by /usr/src/bbl-ch-build/steps/10-finalize.sh

hostname:           $BBL_HOSTNAME
role:               ${BBL_ROLE:-?}
size:               ${BBL_SIZE:-?}

bbl-ch-build:       $build_commit  ($BUILD_DIR)
bbl-django:         $django_commit
  branch:           $django_branch
bblfrontend:        $frontend_commit
  ref:              $frontend_ref

django version:     $django_version
python:             $python_version
kernel:             $kernel

supervisor status:
  $gunicorn_running
  $celery_running

beat enabled:       ${BBL_RUN_BEAT:-false}
db host:            ${BBL_DB_HOST:-?}
db name:            ${BBL_DB_NAME:-?}

built at:           $(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST

cat /etc/bbl-ch-build
echo

# ── motd ────────────────────────────────────────────────────────────
cat > /etc/motd <<MOTD

╔═══════════════════════════════════════════════════════════════════╗
║  $BBL_HOSTNAME — BBL Django call-handler box                      
║                                                                   
║  Provisioned with bbl-ch-build (build commit $build_commit)
║  Django $django_version on Python $python_version
║  bbl-django @ $django_branch ($(echo $django_commit | cut -c1-8))
║                                                                   
║  Status:           supervisorctl status                           
║  Restart Django:   sudo supervisorctl restart bbl                 
║  Restart Celery:   sudo supervisorctl restart celery              
║  Log:              tail -f /var/log/supervisor/{bbl,celery}.stderr.log
║  Build manifest:   cat /etc/bbl-ch-build                          
╚═══════════════════════════════════════════════════════════════════╝

MOTD

# ── Final smoke + ready message ────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════"
echo "==> FINAL CHECKS"
echo "════════════════════════════════════════════════════════════════"
echo

GUNICORN_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8001/bbladmin/login/ 2>&1 || echo "ERR")
THEME_JS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8001/staticfiles/admin/js/theme.js 2>&1 || echo "ERR")
NGINX_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/nginx_status 2>&1 || echo "ERR")
SPA_INDEX=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/app/ 2>&1 || echo "ERR")

echo "gunicorn /bbladmin/login/         $GUNICORN_HEALTH  (expect 200)"
echo "gunicorn /staticfiles/admin/js/theme.js   $THEME_JS  (expect 200)"
echo "nginx /nginx_status               $NGINX_HEALTH  (expect 200)"
echo "nginx /app/  (frontend SPA)       $SPA_INDEX  (expect 200)"
echo

if [[ "$GUNICORN_HEALTH" == "200" && "$NGINX_HEALTH" == "200" && "$SPA_INDEX" == "200" ]]; then
    echo "════════════════════════════════════════════════════════════════"
    echo "==> ✓ READY: $BBL_HOSTNAME is serving cleanly."
    echo "    Next: add to lb-atl nginx upstream at weight=0, then ramp."
    echo "    Public IP: $(curl -s -4 ifconfig.me || echo '?')"
    echo "════════════════════════════════════════════════════════════════"
else
    echo "════════════════════════════════════════════════════════════════"
    echo "==> ⚠️  NOT READY — one or more smoke checks failed."
    echo "    Check supervisor: supervisorctl status"
    echo "    Check logs: /var/log/supervisor/bbl.stderr.log"
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi
