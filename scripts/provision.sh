#!/bin/bash
# provision.sh — create a new Django call-handler Linode using bbl-ch-build.
#
# Usage:
#   scripts/provision.sh role=beta size=medium hostname=ch-test-1.bblapp.io
#   scripts/provision.sh role=prod size=large  hostname=ch-atl-3.bblapp.io
#
# host-conf= is optional. If omitted, the script reads shared secrets
# from /etc/bbl-ch.host.conf, derives a per-host file at
# /etc/bbl-ch-<short>.host.conf with BBL_DOMAIN auto-set from hostname=,
# and reuses the per-host file across re-provisions. Operators no longer need to copy
# the previous host's conf file forward by hand.
#
# Prerequisites:
#   - linode-cli installed and authenticated (`linode-cli configure`)
#   - /etc/bbl-ch.host.conf populated once with BBL_DJANGO_REPO, BBL_FRONTEND_REF,
#     BBL_DB_PASSWORD, BBL_DJANGO_SECRET_KEY, etc. (see host.conf.example for the field list).
set -euo pipefail

# Source operator-side env (BBL_MONITOR_DSN, TELNYX_API_KEY) needed by
# register*.py. On rpt this lives at /opt/bbl-call-tests/.env. Override
# via BBL_OPERATOR_ENV=/path/to/env if running from elsewhere.
OPERATOR_ENV="${BBL_OPERATOR_ENV:-/opt/bbl-call-tests/.env}"
if [[ -r "$OPERATOR_ENV" ]]; then
    set -a; . "$OPERATOR_ENV"; set +a
fi

# ── Parse args ───────────────────────────────────────────────────────
declare -A ARGS=( [role]= [size]= [hostname]= [host-conf]= [region]=us-southeast )
for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -n "${ARGS[$k]+_}" ]] || { echo "unknown arg: $k" >&2; exit 2; }
    ARGS[$k]="$v"
done
for required in role size hostname; do
    [[ -n "${ARGS[$required]}" ]] || { echo "$0: $required is required" >&2; exit 2; }
done

# Hostname format precheck. Must be FQDN with at least one dot, and
# the part before the first dot must be non-empty. Rejects shorthand
# like 'ch-test-1' that would otherwise propagate as BBL_DOMAIN and
# fail later at DNS / TLS time.
if [[ "${ARGS[hostname]}" != *.*  || "${ARGS[hostname]%%.*}" == "" ]]; then
    echo "$0: hostname='${ARGS[hostname]}' must be a fully-qualified domain (e.g. ch-test-1.bblapp.io)" >&2
    exit 2
fi

# ── Resolve size → SKU ───────────────────────────────────────────────
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIZES_FILE="$BUILD_DIR/conf/linode-sizes.conf"
SKU="$(awk -v size="${ARGS[size]}" '$1 == size {print $2}' "$SIZES_FILE")"
[[ -n "$SKU" ]] || { echo "$0: unknown size '${ARGS[size]}' — see $SIZES_FILE" >&2; exit 2; }

LABEL="${ARGS[hostname]//./-}"
ROOT_PASS="$(openssl rand -base64 24)"

echo "==> Provisioning ${ARGS[hostname]} as Linode $SKU in ${ARGS[region]}"

# ── DNS: find the Linode-managed zone for this hostname ─────────────
# Resolve BEFORE writing any per-host conf, so a typo'd hostname can't
# leave an orphan /etc/bbl-ch-<bad>.host.conf behind.
ROOT_DOMAIN=
ZONE_ID=
while read -r line; do
    [[ -z "$line" ]] && continue
    z_id="$(echo "$line" | jq -r '.id')"
    z_dom="$(echo "$line" | jq -r '.domain')"
    if [[ "${ARGS[hostname]}" == *".$z_dom" ]]; then
        # Take longest match (e.g., a.b.example.com prefers example.com over com)
        if (( ${#z_dom} > ${#ROOT_DOMAIN} )); then
            ROOT_DOMAIN="$z_dom"
            ZONE_ID="$z_id"
        fi
    fi
done < <(linode-cli domains list --json | jq -c '.[]')

if [[ -z "$ZONE_ID" ]]; then
    echo "$0: no Linode-managed zone matches '${ARGS[hostname]}' — add the zone in Linode DNS Manager first" >&2
    exit 1
fi
SUBDOMAIN="${ARGS[hostname]%.$ROOT_DOMAIN}"
echo "    DNS zone:    $ROOT_DOMAIN (ID $ZONE_ID), subdomain '$SUBDOMAIN'"

# ── Resolve host.conf ────────────────────────────────────────────────
# host-conf= is an escape hatch. Default flow: per-host file lives at
# /etc/bbl-ch-<short>.host.conf and is auto-derived from the shared
# secrets file at /etc/bbl-ch.host.conf on first provision. Re-provisions
# reuse the existing per-host file across re-provisions.
SHORT_HOST="${ARGS[hostname]%%.*}"
PER_HOST_CONF="/etc/bbl-ch-${SHORT_HOST}.host.conf"
SHARED_CONF="${BBL_CH_SHARED_CONF:-/etc/bbl-ch.host.conf}"

if [[ -n "${ARGS[host-conf]}" ]]; then
    HOST_CONF="${ARGS[host-conf]}"
    [[ -r "$HOST_CONF" ]] || { echo "$0: cannot read $HOST_CONF" >&2; exit 2; }
elif [[ -r "$PER_HOST_CONF" ]]; then
    HOST_CONF="$PER_HOST_CONF"
    echo "==> Reusing existing per-host conf: $HOST_CONF"
elif [[ -r "$SHARED_CONF" ]]; then
    echo "==> Creating $PER_HOST_CONF from $SHARED_CONF (BBL_DOMAIN=${ARGS[hostname]})"
    install -m 0600 /dev/null "$PER_HOST_CONF"
    cat "$SHARED_CONF" >> "$PER_HOST_CONF"
    if grep -q '^BBL_DOMAIN=' "$PER_HOST_CONF"; then
        sed -i "s|^BBL_DOMAIN=.*|BBL_DOMAIN=${ARGS[hostname]}|" "$PER_HOST_CONF"
    else
        echo "BBL_DOMAIN=${ARGS[hostname]}" >> "$PER_HOST_CONF"
    fi
    HOST_CONF="$PER_HOST_CONF"
else
    echo "$0: no host-conf= supplied and neither $PER_HOST_CONF nor $SHARED_CONF exists." >&2
    echo "    Populate $SHARED_CONF once (cp host.conf.example) and re-run." >&2
    exit 2
fi

# Sanity: BBL_DOMAIN in the host.conf must match hostname=, or the box
# identifies itself as something else (wrong TLS cert FQDN, wrong
# Telnyx connection, etc.). Bit fs-test-4 on 2026-05-02 (FS-build); same trap applies here when an
# fs-test-3 host.conf was reused.
EXISTING_DOMAIN="$(awk -F= '/^BBL_DOMAIN=/{print $2; exit}' "$HOST_CONF" | tr -d ' \r')"
if [[ -n "$EXISTING_DOMAIN" && "$EXISTING_DOMAIN" != "${ARGS[hostname]}" ]]; then
    echo "$0: BBL_DOMAIN in $HOST_CONF is '$EXISTING_DOMAIN' but hostname= is '${ARGS[hostname]}'." >&2
    echo "    Fix the conf, or omit host-conf= to auto-derive." >&2
    exit 2
fi

# ── Build user_data: bootstrap.sh + the operator's host.conf ─────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Construct cloud-init user_data combining:
#   - /etc/bbl-ch-host.conf  (operator-supplied host knobs + secrets)
#   - /etc/bbl-ch-bootstrap.env (build args for bootstrap.sh)
#   - bootstrap.sh runs as the cloud-init script
cat > "$TMPDIR/user_data.yaml" <<EOF
#cloud-config
write_files:
  - path: /etc/bbl-ch-host.conf
    permissions: '0600'
    owner: root:root
    content: |
$(sed 's/^/      /' "$HOST_CONF")
  - path: /etc/bbl-ch-bootstrap.env
    permissions: '0644'
    content: |
      BBL_ROLE=${ARGS[role]}
      BBL_SIZE=${ARGS[size]}
      BBL_HOSTNAME=${ARGS[hostname]}
runcmd:
  - bash -c 'curl -fsSL https://raw.githubusercontent.com/bblv2/bbl-ch-build/main/bootstrap.sh | bash >>/var/log/bbl-ch-build.log 2>&1'
EOF

# ── Create the Linode ────────────────────────────────────────────────
SSH_KEY="${SSH_PUBLIC_KEY:-$(cat ~/.ssh/st_github.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub)}"

linode-cli linodes create \
    --type "$SKU" \
    --region "${ARGS[region]}" \
    --image linode/debian12 \
    --label "$LABEL" \
    --root_pass "$ROOT_PASS" \
    --authorized_keys "$SSH_KEY" \
    --metadata.user_data "$(base64 < "$TMPDIR/user_data.yaml" | tr -d '\n')" \
    --tags "bbl-ch,bbl-ch-${ARGS[role]},bbl-ch-${ARGS[size]}" \
    --no-defaults \
    --json > "$TMPDIR/linode.json"

LINODE_ID="$(jq -r '.[0].id' "$TMPDIR/linode.json")"
LINODE_IP="$(jq -r '.[0].ipv4[0]' "$TMPDIR/linode.json")"

echo
echo "  Linode ID:   $LINODE_ID"
echo "  Public IPv4: $LINODE_IP"
echo "  Root pass:   $ROOT_PASS  (write this down — Linode does not store it)"

# ── Create DNS A record + wait for propagation ───────────────────────
# Idempotent: if a record for this subdomain already exists, update it
# instead of failing.
echo "==> Setting DNS: $SUBDOMAIN.$ROOT_DOMAIN → $LINODE_IP (TTL 300)"
EXISTING_RECORD_ID="$(linode-cli domains records-list "$ZONE_ID" --json \
    | jq -r ".[] | select(.type == \"A\" and .name == \"$SUBDOMAIN\") | .id" | head -1)"
if [[ -n "$EXISTING_RECORD_ID" ]]; then
    echo "    A record exists (ID $EXISTING_RECORD_ID); updating target"
    linode-cli domains records-update "$ZONE_ID" "$EXISTING_RECORD_ID" \
        --target "$LINODE_IP" --ttl_sec 300 >/dev/null
else
    linode-cli domains records-create "$ZONE_ID" \
        --type A --name "$SUBDOMAIN" --target "$LINODE_IP" --ttl_sec 300 >/dev/null
fi

# Wait for the auth NS to serve the new record. Linode publishes
# changes within ~30s; we cap at 5 min.
echo "==> Waiting for DNS propagation on ns1.linode.com..."
for _ in $(seq 1 30); do
    actual="$(dig +short @ns1.linode.com "${ARGS[hostname]}" 2>/dev/null | tail -1)"
    if [[ "$actual" == "$LINODE_IP" ]]; then
        echo "    DNS propagated: ${ARGS[hostname]} → $LINODE_IP"
        break
    fi
    sleep 10
done
[[ "$(dig +short @ns1.linode.com "${ARGS[hostname]}" 2>/dev/null | tail -1)" == "$LINODE_IP" ]] \
    || { echo "WARN: DNS hasn't propagated after 5 min; cert step may fail. Continuing." >&2; }

echo
echo "==> Waiting for cloud-init to finish bbl-ch-build (~5 min)..."
echo "    Tail with:  ssh root@$LINODE_IP tail -f /var/log/bbl-ch-build.log"


# ── Don't proceed until /etc/bbl-ch-build appears (setup.sh has finished)
for _ in $(seq 1 60); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "root@$LINODE_IP" 'test -f /etc/bbl-ch-build' 2>/dev/null; then
        break
    fi
    sleep 10
done

echo "==> Done. Build summary:"
ssh -o BatchMode=yes "root@$LINODE_IP" 'cat /etc/bbl-ch-build' || true

# ── post-build registration steps (operator-side) ──────────────────
PY=/opt/bbl-call-tests/.venv/bin/python
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# 1. Always: register in bbl-monitor (every linode goes here)
echo
echo "==> Registering ${ARGS[hostname]} in bbl-monitor"
CPU_COUNT=$(ssh -o BatchMode=yes "root@$LINODE_IP" 'nproc' 2>/dev/null || echo 1)
"$PY" "$SCRIPTS/register-monitor.py" \
    --hostname "${ARGS[hostname]}" \
    --cpu-count "$CPU_COUNT" \
    --role "${ARGS[role]}"

# 2. role-specific registration
# (none for ch boxes — register-monitor above is the full operator-side
# registration. The next step is to add this host to lb-atl nginx upstream
# at weight=0 manually, then ramp.)

echo
echo "==> Provision complete."
echo "    Next: add to lb-atl nginx upstream at weight=0, then ramp."
