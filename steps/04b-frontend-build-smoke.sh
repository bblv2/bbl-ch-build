#!/bin/bash
# 04b-frontend-build-smoke.sh — verify the SPA build pipeline works on this host.
#
# Why this step exists:
#   01-base.sh + 02-django-deps.sh install nodejs/npm/bower system-wide so
#   "ANY future SPA changes built on this box" can run. 04-frontend-clone.sh
#   then pins a prod-tested build/ tree. But the toolchain only gets exercised
#   later, sometimes weeks after provisioning, the first time someone tries
#   to rebuild. Regressions like the bufferutil@^1.3.0 + node-gyp 9 failure
#   are invisible until that moment.
#
#   This step runs a real build at provision time as a smoke test, then
#   restores build/ to the pinned ref so we still ship the verified-prod
#   artifact (not the freshly-built one).
#
#   If this step fails, provisioning stops and the operator sees the actual
#   build error — not "we'll find out next quarter when someone tries to
#   deploy a CSS fix."

set -euo pipefail

FRONTEND_DIR=/opt/bblfrontend

if [[ ! -d "$FRONTEND_DIR/.git" ]]; then
    echo "$0: $FRONTEND_DIR missing — step 04 must run first" >&2
    exit 1
fi

cd "$FRONTEND_DIR"

# Use the canonical build script if the repo carries one (newer revisions);
# otherwise replicate its behavior inline so this step doesn't depend on a
# specific frontend ref containing bin/build.sh.
if [[ -x bin/build.sh ]]; then
    echo "==> running bin/build.sh (smoke)"
    ./bin/build.sh
else
    echo "==> bin/build.sh not present in this frontend ref; running canonical recipe inline"
    if [[ ! -d node_modules ]] || [[ ! -x node_modules/.bin/webpack ]]; then
        # --ignore-scripts: bufferutil@^1.3.0 in devDependencies fails under
        # node 18+ node-gyp. The package is only used by webpack-dev-server
        # (dev-only) so skipping its postinstall is harmless for the prod
        # build. See feedback_spa_build_ignore_scripts memory.
        echo "==> npm install --ignore-scripts (bufferutil gyp workaround)"
        npm install --ignore-scripts --no-audit --no-fund
    fi
    if [[ ! -d bower_components/angular ]]; then
        echo "==> bower install --allow-root"
        bower install --allow-root
    fi
    echo "==> webpack production build (smoke)"
    npm run build-release
fi

# Restore build/ to the pinned-prod ref. We ship the verified artifact,
# not the freshly-built one. The smoke test only proves the pipeline
# works on this box; the prod build/ is the one operator-blessed at the
# tag captured in BBL_FRONTEND_REF.
echo "==> restoring build/ to pinned ref (smoke output discarded)"
git checkout -- build/ index.html

echo "==> SPA build smoke passed; build/ restored to $(git describe --tags --always HEAD)"
