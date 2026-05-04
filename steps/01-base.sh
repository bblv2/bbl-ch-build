#!/bin/bash
# 01-base.sh — OS-level setup for Django call-handler boxes.
#
# Adapted from bbl-fs-build/steps/01-base.sh; strips FreeSWITCH/RTP-
# specific bits (SignalWire repo, RTP sysctls, FreeSWITCH fail2ban
# jail). Keeps the Django-relevant pieces: base packages, time/entropy,
# locale/timezone, sane FD limits, CPU governor, fail2ban for sshd.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update + base packages"
apt-get update -q
apt-get install -y -q \
    curl gnupg lsb-release ca-certificates apt-transport-https \
    git rsync \
    chrony haveged \
    fail2ban ufw \
    tcpdump dnsutils net-tools jq \
    cron logrotate

echo "==> Locale + timezone"
timedatectl set-timezone UTC
sed -i '/^# en_US.UTF-8/s/^# //' /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null
update-locale LANG=en_US.UTF-8

echo "==> Entropy + NTP"
systemctl enable --now haveged
systemctl enable --now chrony

echo "==> Kernel sysctls for HTTP-heavy workload"
cat > /etc/sysctl.d/99-bbl-ch.conf <<'SYSCTL'
# More backlog for HTTPS bursts (Stripe webhooks, customer dial-in storms)
net.core.somaxconn          = 4096
net.core.netdev_max_backlog = 16384
# Larger conntrack table for high request rates
net.netfilter.nf_conntrack_max = 524288
SYSCTL
sysctl -q --system || true

echo "==> File-descriptor limit (gunicorn + celery want plenty)"
cat > /etc/security/limits.d/99-bbl-ch.conf <<'LIMITS'
*  soft  nofile  1048576
*  hard  nofile  1048576
LIMITS

echo "==> CPU governor → performance"
if command -v cpupower >/dev/null; then
    cpupower frequency-set -g performance >/dev/null 2>&1 || true
fi

echo "==> fail2ban for sshd (default jail is enough; FS-specific jail removed)"
# Default Debian fail2ban ships with [sshd] jail enabled — no override needed.
systemctl enable --now fail2ban

echo "==> 01-base.sh complete"
