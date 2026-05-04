#!/bin/bash
# 03-django-clone.sh — git-clone bbl-django, create venv, pip install requirements.
# Idempotent: re-running pulls latest of BBL_DJANGO_BRANCH and re-installs.
set -euo pipefail

source "${BBL_HOST_CONF:-/etc/bbl-ch-host.conf}"

: "${BBL_DJANGO_REPO:?BBL_DJANGO_REPO not set in host.conf}"
: "${BBL_DJANGO_BRANCH:?BBL_DJANGO_BRANCH not set in host.conf}"

DJANGO_DIR=/projects/bbl-django
VENV_DIR=/projects/bbl_env_py3

mkdir -p /projects

# ── Clone or fast-forward bbl-django ────────────────────────────────
if [[ -d "$DJANGO_DIR/.git" ]]; then
    echo "==> bbl-django already cloned; fetching"
    git -C "$DJANGO_DIR" fetch --quiet origin
    git -C "$DJANGO_DIR" checkout --quiet "$BBL_DJANGO_BRANCH"
    git -C "$DJANGO_DIR" reset --quiet --hard "origin/$BBL_DJANGO_BRANCH"
else
    echo "==> Cloning $BBL_DJANGO_REPO @ $BBL_DJANGO_BRANCH"
    git clone --branch "$BBL_DJANGO_BRANCH" "$BBL_DJANGO_REPO" "$DJANGO_DIR"
fi

# ── Create or reuse venv ─────────────────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
    echo "==> Creating venv at $VENV_DIR"
    python3.11 -m venv "$VENV_DIR"
fi

echo "==> Installing requirements"
"$VENV_DIR/bin/pip" install --upgrade pip wheel
"$VENV_DIR/bin/pip" install -r "$DJANGO_DIR/requirements.txt"

# Quick check — the django-upgrade branch should have Django 5.2.x
"$VENV_DIR/bin/python" -c 'import django; print("django", django.__version__)'
