#!/bin/bash
# Linode user_data bootstrap. Runs ONCE at first boot via cloud-init.
#
# Substantive work lives in this repo's setup.sh, not here. This file
# only: installs git, clones the build repo, runs setup.sh with args
# passed via the metadata service. Keep this short and boring.
set -euo pipefail

# cloud-init's runcmd does NOT export $HOME; without it any `git config
# --global`, ssh-key lookup against ~/.ssh, etc. dies with
# "fatal: $HOME not set". Pin it before sourcing or running anything
# downstream so every step inherits it. Burned ch-atl6 + ch-atl7 here.
export HOME="${HOME:-/root}"

# Provisioning args come from /etc/bbl-ch-bootstrap.env that the
# linode-cli wrapper writes via user_data. If absent, fall back to
# defaults so manual SSH-and-rerun works too.
ENV_FILE=/etc/bbl-ch-bootstrap.env
if [[ -r "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

: "${BBL_BUILD_REPO:=https://github.com/bblv2/bbl-ch-build.git}"
: "${BBL_BUILD_BRANCH:=master}"
: "${BBL_ROLE:=beta}"
: "${BBL_SIZE:=large}"
: "${BBL_HOSTNAME:=$(hostname -f)}"

apt-get update
apt-get install -y git ca-certificates

mkdir -p /usr/src
git clone --branch "$BBL_BUILD_BRANCH" "$BBL_BUILD_REPO" /usr/src/bbl-ch-build

exec /usr/src/bbl-ch-build/setup.sh \
    role="$BBL_ROLE" \
    size="$BBL_SIZE" \
    hostname="$BBL_HOSTNAME" \
    2>&1 | tee /var/log/bbl-ch-build.log
