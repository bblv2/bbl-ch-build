#!/bin/bash
# provision.sh — create a new Django call-handler Linode using bbl-ch-build.
#
# Usage:
#   scripts/provision.sh role=beta size=medium n=4
#       shortcut → hostname=ch-atl4.bblapp.io  (prod naming convention)
#   scripts/provision.sh role=beta size=medium hostname=ch-test-1.bblapp.io
#   scripts/provision.sh role=prod size=large  hostname=ch-atl-3.bblapp.io
#
# n= and hostname= are mutually exclusive. n= refuses to clobber an
# already-provisioned ch-atl<N> (Linode label collision OR DNS already
# pointing somewhere else) — guards against e.g. n=1 silently repointing
# production's ch-atl1.bblapp.io at a fresh empty box.
#
# host-conf= is optional and now only used as an escape hatch — for
# normal provisioning the script assembles the new box's host.conf
# from four overlays (in order; later overrides earlier):
#   1. seeds/defaults.conf                       (this repo, VCS)
#   2. seeds/hosts/<short>.conf                  (this repo, VCS, optional)
#   3. /etc/bbl-ch-secrets.conf                  (loose on rpt, required)
#   4. /etc/bbl-ch-secrets.d/<short>.conf        (loose on rpt, optional)
# BBL_DOMAIN is appended last from hostname=.
#
# Prerequisites:
#   - linode-cli installed and authenticated (`linode-cli configure`)
#   - /etc/bbl-ch-secrets.conf populated once with BBL_DJANGO_SECRET_KEY,
#     BBL_DB_PASSWORD, BBL_STRIPE_SECRET_KEY, BBL_TELNYX_*, BBL_REDIS_TRACE_URL.
#     See seeds/secrets.example.conf for the field list.
set -euo pipefail

# Source operator-side env (BBL_MONITOR_DSN, TELNYX_API_KEY) needed by
# register*.py. On rpt this lives at /opt/bbl-call-tests/.env. Override
# via BBL_OPERATOR_ENV=/path/to/env if running from elsewhere.
OPERATOR_ENV="${BBL_OPERATOR_ENV:-/opt/bbl-call-tests/.env}"
if [[ -r "$OPERATOR_ENV" ]]; then
    set -a; . "$OPERATOR_ENV"; set +a
fi

# ── Parse args ───────────────────────────────────────────────────────
declare -A ARGS=( [role]= [size]= [hostname]= [host-conf]= [region]=us-southeast [n]= )
for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -n "${ARGS[$k]+_}" ]] || { echo "unknown arg: $k" >&2; exit 2; }
    ARGS[$k]="$v"
done

# n= shortcut: expand to ch-atl<N>.bblapp.io (prod convention). Mutually
# exclusive with hostname=.
if [[ -n "${ARGS[n]}" ]]; then
    if [[ -n "${ARGS[hostname]}" ]]; then
        echo "$0: pass either n= or hostname=, not both" >&2
        exit 2
    fi
    if ! [[ "${ARGS[n]}" =~ ^[0-9]+$ ]]; then
        echo "$0: n= must be a non-negative integer (got '${ARGS[n]}')" >&2
        exit 2
    fi
    ARGS[hostname]="ch-atl${ARGS[n]}.bblapp.io"
    echo "==> n=${ARGS[n]} → hostname=${ARGS[hostname]}"
fi

for required in role size; do
    [[ -n "${ARGS[$required]}" ]] || { echo "$0: $required is required" >&2; exit 2; }
done
[[ -n "${ARGS[hostname]}" ]] || { echo "$0: hostname= or n= is required" >&2; exit 2; }

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

# ── Refuse-to-clobber: bail if a Linode with this label already exists,
# OR if DNS already resolves the hostname to a non-matching IP. Catches
# the n=1 → ch-atl1.bblapp.io footgun (production lives there).
EXISTING_LINODE="$(linode-cli linodes list --json \
    | jq -r --arg L "$LABEL" '.[] | select(.label == $L) | "\(.id) \(.ipv4[0]) \(.status)"')"
if [[ -n "$EXISTING_LINODE" ]]; then
    echo "$0: Linode label '$LABEL' already exists: $EXISTING_LINODE" >&2
    echo "    pick a different n= / hostname=, or destroy the existing Linode first." >&2
    exit 2
fi
DNS_CURRENT="$(dig +short "${ARGS[hostname]}" @ns1.linode.com 2>/dev/null | tail -1)"
if [[ -n "$DNS_CURRENT" ]]; then
    echo "$0: DNS for '${ARGS[hostname]}' already points at $DNS_CURRENT" >&2
    echo "    pick a different n= / hostname=, or remove the existing A record first." >&2
    exit 2
fi

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

# ── Assemble host.conf from VCS seeds + loose secrets ────────────────
# Layered overlay (later overrides earlier):
#   1. seeds/defaults.conf                       — VCS, required
#   2. seeds/hosts/<short>.conf                  — VCS, optional
#   3. /etc/bbl-ch-secrets.conf                  — loose on rpt, required
#   4. /etc/bbl-ch-secrets.d/<short>.conf        — loose on rpt, optional
# BBL_DOMAIN is appended last from hostname=.
#
# host-conf= remains as an escape hatch for one-off boxes that need an
# entirely custom file (e.g. a foreign-cluster trial box). When supplied
# it short-circuits the overlay assembly.
SHORT_HOST="${ARGS[hostname]%%.*}"
SEEDS_DIR="$BUILD_DIR/seeds"
DEFAULTS="$SEEDS_DIR/defaults.conf"
PER_HOST_DEFAULTS="$SEEDS_DIR/hosts/${SHORT_HOST}.conf"
SECRETS="${BBL_CH_SECRETS:-/etc/bbl-ch-secrets.conf}"
PER_HOST_SECRETS="/etc/bbl-ch-secrets.d/${SHORT_HOST}.conf"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if [[ -n "${ARGS[host-conf]}" ]]; then
    HOST_CONF="${ARGS[host-conf]}"
    [[ -r "$HOST_CONF" ]] || { echo "$0: cannot read $HOST_CONF" >&2; exit 2; }
    echo "==> Using operator-supplied host.conf: $HOST_CONF (skipping overlay assembly)"
else
    [[ -r "$DEFAULTS" ]] || { echo "$0: missing $DEFAULTS (VCS-tracked)" >&2; exit 2; }
    [[ -r "$SECRETS" ]]  || { echo "$0: missing $SECRETS — copy from $SEEDS_DIR/secrets.example.conf and fill in real values" >&2; exit 2; }
    HOST_CONF="$TMPDIR/host.conf"
    {
        echo "# Assembled by bbl-ch-build/scripts/provision.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Layers:"
        echo "#   1. $DEFAULTS"
        [[ -r "$PER_HOST_DEFAULTS" ]] && echo "#   2. $PER_HOST_DEFAULTS"
        echo "#   3. $SECRETS"
        [[ -r "$PER_HOST_SECRETS" ]] && echo "#   4. $PER_HOST_SECRETS"
        echo "#   5. BBL_DOMAIN appended from hostname="
        echo
        cat "$DEFAULTS"
        if [[ -r "$PER_HOST_DEFAULTS" ]]; then
            echo
            echo "# ── overlay: seeds/hosts/${SHORT_HOST}.conf ─────────────────────"
            cat "$PER_HOST_DEFAULTS"
        fi
        echo
        echo "# ── overlay: $SECRETS (secrets, loose on rpt) ──────────────"
        cat "$SECRETS"
        if [[ -r "$PER_HOST_SECRETS" ]]; then
            echo
            echo "# ── overlay: /etc/bbl-ch-secrets.d/${SHORT_HOST}.conf ───────────"
            cat "$PER_HOST_SECRETS"
        fi
        echo
        echo "# ── derived ─────────────────────────────────────────────────────"
        echo "BBL_DOMAIN=${ARGS[hostname]}"
    } > "$HOST_CONF"
    chmod 0600 "$HOST_CONF"
    echo "==> Assembled host.conf at $HOST_CONF (defaults + ${PER_HOST_DEFAULTS##*/seeds/}${PER_HOST_DEFAULTS:+ + }secrets$([[ -r $PER_HOST_SECRETS ]] && echo " + secrets.d/${SHORT_HOST}.conf"))"
fi

# Construct cloud-init user_data combining:
#   - /etc/bbl-ch-host.conf       (operator-supplied host knobs + secrets)
#   - /etc/bbl-ch-bootstrap.env   (build args for bootstrap.sh)
#   - /root/.ssh/id_rsa           (operator's github SSH key — needed by step 03 + 04
#                                  to clone PRIVATE bbl-django + bblfrontend repos)
#   - /root/.ssh/known_hosts      (github.com entries so SSH doesn't prompt)
#   - bootstrap.sh runs as the cloud-init script (curls from PUBLIC bbl-ch-build)
#
# Security note: the github SSH key is the operator's `st_github` (which has
# push access to all bblv2 repos). It's exposed to anyone with API access to
# this Linode account. Acceptable for short-lived test boxes; replace with a
# per-box deploy key for long-lived prod boxes.
SSH_KEY_FILE="${BBL_OPERATOR_GITHUB_KEY:-/root/.ssh/st_github}"
[[ -r "$SSH_KEY_FILE" ]] || { echo "$0: cannot read SSH key at $SSH_KEY_FILE" >&2; exit 2; }
SSH_KEY_B64=$(base64 -w 0 < "$SSH_KEY_FILE")
GITHUB_HOSTKEYS_B64=$(ssh-keyscan -t rsa,ed25519,ecdsa github.com 2>/dev/null | base64 -w 0)

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
  - path: /root/.ssh/id_rsa
    permissions: '0600'
    owner: root:root
    encoding: base64
    content: ${SSH_KEY_B64}
  - path: /root/.ssh/known_hosts
    permissions: '0644'
    owner: root:root
    encoding: base64
    content: ${GITHUB_HOSTKEYS_B64}
runcmd:
  - bash -c 'curl -fsSL https://raw.githubusercontent.com/bblv2/bbl-ch-build/master/bootstrap.sh | bash >>/var/log/bbl-ch-build.log 2>&1'
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
    if ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "root@$LINODE_IP" 'test -f /etc/bbl-ch-build' 2>/dev/null; then
        break
    fi
    sleep 10
done

echo "==> Done. Build summary:"
ssh -o BatchMode=yes -o LogLevel=ERROR "root@$LINODE_IP" 'cat /etc/bbl-ch-build' || true

# ── post-build registration steps (operator-side) ──────────────────
PY=/opt/bbl-call-tests/.venv/bin/python
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# 1. Always: register in bbl-monitor (every linode goes here)
echo
echo "==> Registering ${ARGS[hostname]} in bbl-monitor"
CPU_COUNT=$(ssh -o BatchMode=yes -o LogLevel=ERROR "root@$LINODE_IP" 'nproc' 2>/dev/null || echo 1)
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
