#!/bin/bash
# bbl-ch-build setup.sh — orchestrator for Django call-handler box provisioning.
#
# Adapted from bbl-fs-build/setup.sh (BBL FreeSWITCH provisioning) with the
# FS-specific bits stripped. This builds boxes that run Django + gunicorn +
# celery + nginx + the bblfrontend SPA — i.e., the role currently filled by
# ch-atl1 (and historically ch-atl2). NOT for FreeSWITCH boxes.
#
# Each step in steps/ is small, idempotent, and logs to stdout/stderr (we
# tee to /var/log/bbl-ch-build.log via bootstrap.sh). Add a step file
# instead of inflating this one.
set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────
declare -A ARGS=( [role]= [size]=large [hostname]= )
for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -n "${ARGS[$k]+_}" ]] || { echo "unknown arg: $k" >&2; exit 2; }
    ARGS[$k]="$v"
done

for required in role hostname; do
    if [[ -z "${ARGS[$required]}" ]]; then
        echo "$0: $required is required" >&2
        echo "usage: $0 role=<beta|prod> size=<small|medium|large|xlarge> hostname=<fqdn>" >&2
        exit 2
    fi
done

case "${ARGS[role]}" in beta|prod) ;; *) echo "role must be beta|prod" >&2; exit 2;; esac
case "${ARGS[size]}" in small|medium|large|xlarge) ;; *) echo "unknown size: ${ARGS[size]}" >&2; exit 2;; esac

export BBL_ROLE="${ARGS[role]}"
export BBL_SIZE="${ARGS[size]}"
export BBL_HOSTNAME="${ARGS[hostname]}"
export BBL_BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
export BBL_HOST_CONF=/etc/bbl-ch-host.conf

# ── Environment sanity ───────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "$0: must run as root" >&2
    exit 1
fi

if ! grep -q '^ID=debian' /etc/os-release || ! grep -q '^VERSION_ID="12"' /etc/os-release; then
    echo "$0: only tested on Debian 12 (Bookworm); refusing to proceed" >&2
    exit 1
fi

# ── Hostname ─────────────────────────────────────────────────────────
echo "==> Setting hostname to $BBL_HOSTNAME"
hostnamectl set-hostname "$BBL_HOSTNAME"
short="${BBL_HOSTNAME%%.*}"
if ! grep -q "$BBL_HOSTNAME" /etc/hosts; then
    sed -i "1i 127.0.1.1 $BBL_HOSTNAME $short" /etc/hosts
fi

# ── Run steps in order ───────────────────────────────────────────────
echo "==> bbl-ch-build starting: role=$BBL_ROLE size=$BBL_SIZE hostname=$BBL_HOSTNAME"
echo "==> $(date -u)"

cd "$BBL_BUILD_DIR"
for step in steps/[0-9]*.sh; do
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "==> $step"
    echo "════════════════════════════════════════════════════════════════"
    bash "$step"
done

echo
echo "════════════════════════════════════════════════════════════════"
echo "==> bbl-ch-build complete  $(date -u)"
echo "════════════════════════════════════════════════════════════════"
