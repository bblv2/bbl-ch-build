#!/bin/bash
# 10b-verify.sh — post-provision assertions for a freshly-built CH host.
#
# Catches the silent regressions: a missing apt package, a missing secret,
# a gunicorn that started but answers 500. Without this, the only way you
# learn the host is half-broken is when a customer call fails through it.
#
# Each check exits non-zero on failure with a label; a partial pass is
# still treated as build failure (operator should fix before rolling
# this host into nginx upstream).

set -euo pipefail

ASSERT_PASS=()
ASSERT_FAIL=()

assert() {
    local label="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        ASSERT_PASS+=("$label")
    else
        ASSERT_FAIL+=("$label")
    fi
}

DJANGO_DIR=/projects/bbl-django
LS=$DJANGO_DIR/local_settings.py

echo "==> Running post-provision verifications"

# ── apt packages BBL Django actually invokes ─────────────────────
assert "sox installed (announce-name silence check)" "which sox"
assert "libsox-fmt-mp3 installed (decodes recorded mp3s)" \
    "dpkg -s libsox-fmt-mp3 2>/dev/null | grep -q 'Status: install ok'"
assert "sox supports mp3 in format list" \
    "sox --help 2>&1 | grep -ow mp3"

# ── secrets actually written to local_settings.py ────────────────
assert "local_settings.py exists" "test -f $LS"
assert "SECRET_KEY in local_settings" "grep -q '^SECRET_KEY' $LS"
assert "DATABASES configured" "grep -q '^DATABASES' $LS"
assert "TELNYX_API_KEY (V2) wired" "grep -q '^TELNYX_API_KEY' $LS"

# ── supervisor + gunicorn actually serving ───────────────────────
assert "supervisor 'bbl' RUNNING" "supervisorctl status bbl | grep -q RUNNING"
assert "gunicorn binds to 127.0.0.1:8001" \
    "ss -lntp 2>/dev/null | grep -q '127.0.0.1:8001'"
assert "Django responds on /bridges/api/v1/bridge/2/" \
    "curl -m 5 -o /dev/null -s -w '%{http_code}' http://127.0.0.1:8001/bridges/api/v1/bridge/2/ | grep -E '^(200|401|403|404)$'"

# ── DB reachable through Django settings ─────────────────────────
assert "Django manage.py check passes" \
    "cd $DJANGO_DIR && /projects/bbl_env_py3/bin/python manage.py check 2>/dev/null"
assert "DB connectivity from Django" \
    "cd $DJANGO_DIR && /projects/bbl_env_py3/bin/python manage.py shell -c 'from django.db import connection; connection.cursor().execute(\"SELECT 1\")'"

# ── nginx serving ───────────────────────────────────────────────
assert "nginx running" "systemctl is-active nginx | grep -q active"
assert "nginx serves /bridges proxy" \
    "curl -m 5 -o /dev/null -s -w '%{http_code}' http://127.0.0.1/bridges/api/v1/bridge/2/ | grep -E '^(200|401|403|404)$'"

# ── Static files (collectstatic ran) ────────────────────────────
assert "staticfiles collected" \
    "test -d $DJANGO_DIR/staticfiles && find $DJANGO_DIR/staticfiles/admin -name '*.css' | head -1 | grep -q css"

# ── Frontend SPA bundle ────────────────────────────────────────
assert "bblfrontend SPA built" \
    "test -f /opt/bblfrontend/build/main.js"

# ── Report ─────────────────────────────────────────────────────
echo
echo "  PASS: ${#ASSERT_PASS[@]}"
echo "  FAIL: ${#ASSERT_FAIL[@]}"
if [[ ${#ASSERT_FAIL[@]} -gt 0 ]]; then
    echo
    echo "  Failed checks:"
    for f in "${ASSERT_FAIL[@]}"; do
        echo "    ✗ $f"
    done
    exit 1
fi
echo "==> All verifications passed."
