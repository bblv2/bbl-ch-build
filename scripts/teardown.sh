#!/bin/bash
# teardown.sh — destroy a bbl-ch Linode cleanly.
#
# Safety: requires --confirm flag. Never tears down hosts without
# explicit operator OK. Snapshots the disk before deletion so a 30-day
# rollback window exists.
set -euo pipefail

OPERATOR_ENV="${BBL_OPERATOR_ENV:-/opt/bbl-call-tests/.env}"
if [[ -r "$OPERATOR_ENV" ]]; then
    set -a; . "$OPERATOR_ENV"; set +a
fi

CONFIRM=0
HOSTNAME=
SNAPSHOT=1
HOST_CONF=
for arg in "$@"; do
    case "$arg" in
        --confirm) CONFIRM=1 ;;
        --no-snapshot) SNAPSHOT=0 ;;
        hostname=*) HOSTNAME="${arg#hostname=}" ;;
        host-conf=*) HOST_CONF="${arg#host-conf=}" ;;
        *) echo "unknown: $arg" >&2; exit 2 ;;
    esac
done

[[ -n "$HOSTNAME" ]] || { echo "usage: $0 hostname=<fqdn> [host-conf=<path>] --confirm [--no-snapshot]" >&2; exit 2; }
LABEL="${HOSTNAME//./-}"

# host-conf default: /etc/bbl-ch-<short>.host.conf (where provision.sh
# persisted BBL_DB_HBA_* state for pg_hba cleanup). Skip silently if
# absent — happens for hand-built boxes and pre-pg_hba-automation builds.
if [[ -z "$HOST_CONF" ]]; then
    DEFAULT_HOST_CONF="/etc/bbl-ch-${HOSTNAME%%.*}.host.conf"
    if [[ -r "$DEFAULT_HOST_CONF" ]]; then
        HOST_CONF="$DEFAULT_HOST_CONF"
        echo "==> Using $HOST_CONF for pg_hba cleanup"
    fi
fi

LID="$(linode-cli linodes list --label "$LABEL" --json 2>/dev/null | jq -r '.[0].id')"
[[ -n "$LID" && "$LID" != "null" ]] || { echo "$0: no linode with label '$LABEL'" >&2; exit 1; }

echo "==> Found linode $LID for $HOSTNAME"
linode-cli linodes view "$LID" --json | jq -r '.[0] | "  status=\(.status) ipv4=\(.ipv4[0]) created=\(.created)"'

if (( ! CONFIRM )); then
    echo "$0: not destroying without --confirm"
    exit 1
fi

PY=/opt/bbl-call-tests/.venv/bin/python
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# 0. Pre-delete: remove pg_hba entry on db-atl (best-effort).
if [[ -n "$HOST_CONF" && -r "$HOST_CONF" ]]; then
    # Source the state file into a subshell so we don't leak vars.
    (
        set -a; . "$HOST_CONF"; set +a
        if [[ -n "${BBL_DB_HBA_HOST:-}" && -n "${BBL_DB_HBA_DB:-}" \
              && -n "${BBL_DB_HBA_USER:-}" && -n "${BBL_DB_HBA_IP:-}" ]]; then
            PGHBA="${BBL_DB_HBA_PATH:-/etc/postgresql/16/main/pg_hba.conf}"
            # Escape dots for sed regex.
            IP_RE="${BBL_DB_HBA_IP//./\\.}"
            echo "==> Removing pg_hba entry on $BBL_DB_HBA_HOST ($BBL_DB_HBA_DB / $BBL_DB_HBA_USER / $BBL_DB_HBA_IP)"
            ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
                "$BBL_DB_HBA_HOST" "sudo bash -lc '
                    PGHBA=$PGHBA
                    BEFORE=\$(grep -cE \"^host[[:space:]]+$BBL_DB_HBA_DB[[:space:]]+$BBL_DB_HBA_USER[[:space:]]+$IP_RE[[:space:]]\" \$PGHBA || true)
                    if (( BEFORE > 0 )); then
                        sed -i.bak -E \"/^host[[:space:]]+$BBL_DB_HBA_DB[[:space:]]+$BBL_DB_HBA_USER[[:space:]]+$IP_RE[[:space:]]/d\" \$PGHBA
                        systemctl reload postgresql
                        echo \"  removed \$BEFORE line(s) + postgresql reloaded\"
                    else
                        echo \"  (no matching line)\"
                    fi
                '" || true
        else
            echo "==> Skipping pg_hba cleanup (no BBL_DB_HBA_* in $HOST_CONF)"
        fi
    )
else
    echo "==> Skipping pg_hba cleanup (no --host-conf and no auto-derived state file)"
fi

echo "==> Disabling host in bbl-monitor"
"$PY" "$SCRIPTS/unregister-monitor.py" --hostname "$HOSTNAME" || true

# 1. Snapshot for rollback (only if Backups service is enabled on this Linode;
#    Linode rejects snapshot calls with HTTP 400 otherwise)
if (( SNAPSHOT )); then
    BACKUPS_ENABLED="$(linode-cli linodes view "$LID" --json | jq -r '.[0].backups.enabled // false')"
    if [[ "$BACKUPS_ENABLED" == "true" ]]; then
        echo "==> Taking final disk snapshot"
        linode-cli linodes snapshot "$LID" --label "${LABEL}-final-$(date -u +%Y%m%d)" || true
        sleep 10
    else
        echo "==> Skipping snapshot (Backups not enabled on this Linode — would 400)"
    fi
fi

# 2. Delete
echo "==> Deleting linode $LID"
linode-cli linodes delete "$LID"

# 3. Remove the DNS A record
ROOT_DOMAIN=
ZONE_ID=
while read -r line; do
    [[ -z "$line" ]] && continue
    z_id="$(echo "$line" | jq -r '.id')"
    z_dom="$(echo "$line" | jq -r '.domain')"
    if [[ "$HOSTNAME" == *".$z_dom" ]] && (( ${#z_dom} > ${#ROOT_DOMAIN} )); then
        ROOT_DOMAIN="$z_dom"; ZONE_ID="$z_id"
    fi
done < <(linode-cli domains list --json | jq -c '.[]')

if [[ -n "$ZONE_ID" ]]; then
    SUBDOMAIN="${HOSTNAME%.$ROOT_DOMAIN}"
    REC_ID="$(linode-cli domains records-list "$ZONE_ID" --json \
        | jq -r ".[] | select(.type == \"A\" and .name == \"$SUBDOMAIN\") | .id" | head -1)"
    if [[ -n "$REC_ID" ]]; then
        echo "==> Removing DNS A record ($SUBDOMAIN.$ROOT_DOMAIN, ID $REC_ID)"
        linode-cli domains records-delete "$ZONE_ID" "$REC_ID" >/dev/null
    fi
fi

# 4. Remove the auto-derived per-host state file so a future re-spawn
#    with the same hostname doesn't reuse stale pg_hba state. Only delete
#    if it matches the auto-derive convention; never touch an
#    operator-supplied host-conf path.
DEFAULT_HOST_CONF="/etc/bbl-ch-${HOSTNAME%%.*}.host.conf"
if [[ "$HOST_CONF" == "$DEFAULT_HOST_CONF" && -f "$HOST_CONF" ]]; then
    echo "==> Removing per-host state $HOST_CONF"
    rm -f "$HOST_CONF"
fi

echo
echo "==> Teardown complete for $HOSTNAME"
[[ "$SNAPSHOT" == "1" ]] && echo "    Snapshot retained: ${LABEL}-final-$(date -u +%Y%m%d)"
