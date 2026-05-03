#!/bin/bash
# 07-firewall.sh — ufw rules for Django call-handler hosts.
#
# Opens only HTTP, HTTPS, and SSH. No SIP/RTP/WSS/ESL — those live on
# FreeSWITCH boxes (see bbl-fs-build/steps/06-firewall.sh). This box
# only serves HTTP(S) to lb-atl's nginx upstream and the public.
set -euo pipefail

# shellcheck disable=SC1091
. "$BBL_HOST_CONF"

ufw --force reset >/dev/null

# Outbound: allow everything (Django calls Stripe/Mailgun/Telnyx, fetches
# DB at lb-atl, etc.)
ufw default allow outgoing

# Inbound: deny by default
ufw default deny incoming

# Always allow SSH from anywhere (Linode Cloud Firewall should restrict
# this further to known operator IPs; ufw is the safety net)
ufw allow 22/tcp comment 'ssh'

# HTTP — for acme.sh challenge and lb-atl upstream proxy
ufw allow 80/tcp comment 'http'

# HTTPS — direct (acme renewals + ad-hoc operator access)
ufw allow 443/tcp comment 'https'

# Gunicorn local-only on 8001; lb-atl proxies via private network.
# If lb-atl is on a separate subnet/IP, allow that specifically here.
# For now we trust the loopback-binding done in supervisor + Linode VLAN.

# ICMP echo (ping) — debugging
ufw default allow routed
echo y | ufw enable

echo "==> ufw status:"
ufw status verbose | head -20

echo "==> 07-firewall.sh complete"
