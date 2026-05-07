#!/bin/bash
# 02-django-deps.sh — apt install everything Django + frontend need.
# Idempotent (apt install is a no-op if packages already present).
set -euo pipefail

apt-get update
apt-get install -y \
    python3.11 python3.11-venv python3.11-dev python3-pip \
    postgresql-client \
    redis-server redis-tools \
    supervisor \
    nginx \
    build-essential libpq-dev libffi-dev libssl-dev libxml2-dev libxslt1-dev \
    curl ca-certificates \
    nodejs npm \
    rsync git \
    sox libsox-fmt-mp3

systemctl enable --now redis-server

# bower for the bblfrontend SPA build pipeline (we don't actually rebuild
# the SPA on first provision — we git-checkout a prod-tested ref — but
# bower needs to be available for ANY future SPA changes built on this box).
npm install -g bower

# Confirm Python 3.11 is the default python3 (Debian 12 default, sanity check).
python3 --version
