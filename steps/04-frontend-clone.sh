#!/bin/bash
# 04-frontend-clone.sh — git-clone bblfrontend at the prod-tested ref.
# Per project_bbl_frontend_layout memory: prefer git-checkout over rsync
# of /opt/bblfrontend/build/. The ref captured below should be a tag or
# commit that contains the verified-working build/ tree.
#
# Workflow before first provision:
#   ssh ch-atl1.bblapp.io
#   cd /opt/bblfrontend
#   git add build/ && git commit -m "Snapshot prod build $(date +%F)"
#   git tag prod-$(date +%F-%H%M)
#   git push origin master --tags
#   # Then in /etc/bbl-build-ch.host.conf set BBL_FRONTEND_REF=prod-2026-MM-DD-HHMM
set -euo pipefail

source "${BBL_HOST_CONF:-/etc/bbl-build-ch-host.conf}"

: "${BBL_FRONTEND_REPO:?BBL_FRONTEND_REPO not set in host.conf}"
: "${BBL_FRONTEND_REF:?BBL_FRONTEND_REF not set in host.conf}"

FRONTEND_DIR=/opt/bblfrontend

if [[ -d "$FRONTEND_DIR/.git" ]]; then
    echo "==> bblfrontend already cloned; fetching"
    git -C "$FRONTEND_DIR" fetch --quiet origin --tags
else
    echo "==> Cloning $BBL_FRONTEND_REPO"
    git clone "$BBL_FRONTEND_REPO" "$FRONTEND_DIR"
fi

echo "==> Checking out $BBL_FRONTEND_REF"
git -C "$FRONTEND_DIR" checkout --quiet "$BBL_FRONTEND_REF"

# Sanity: build/ must exist and contain main.js
if [[ ! -f "$FRONTEND_DIR/build/main.js" ]]; then
    echo "$0: $FRONTEND_DIR/build/main.js missing — was the prod build committed before tagging?" >&2
    exit 1
fi

# Bump the cache buster so browsers don't serve stale main.js after deploy
sed -i "s/main.js?_cb=[0-9]*/main.js?_cb=$(date +%s%N | cut -c1-13)/" \
    "$FRONTEND_DIR/build/index.html" || true

echo "==> bblfrontend build:"
ls -la "$FRONTEND_DIR/build/main.js" "$FRONTEND_DIR/build/index.html" 2>&1 | head
