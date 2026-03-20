#!/usr/bin/env bash
# install-image-server.sh — install systemd service to serve cached OS images
#
# Creates a systemd service that runs a simple HTTP server on PROVISION_IP:IMAGE_SERVER_PORT
# to serve files from IMAGE_CACHE_DIR. The IPA ramdisk on provisioning VMs has no DNS or
# internet access; it can only reach 172.22.0.1 on the provisioning bridge.
#
# Usage:
#   bash scripts/install-image-server.sh
#
# Normally called automatically by cache-os-image.sh. Can be run standalone to
# (re)install the service unit without re-downloading the image.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
IMAGE_SERVER_PORT="${IMAGE_SERVER_PORT:-9000}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/srv/os-images}"

log() { echo "[install-image-server] $*"; }

# ---------------------------------------------------------------------------
# Write the systemd unit
# ---------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/os-image-server.service"

log "Writing ${SERVICE_FILE}..."

sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=OS Image HTTP Server for Metal3/Ironic provisioning
Documentation=https://github.com/loft-demos/vmetal-sushy-demo
After=network.target
Wants=network.target

[Service]
Type=simple
# Serve IMAGE_CACHE_DIR on PROVISION_IP:IMAGE_SERVER_PORT.
# Python's http.server is sufficient for a demo — images are fetched infrequently.
ExecStart=/usr/bin/python3 -m http.server ${IMAGE_SERVER_PORT} --bind ${PROVISION_IP} --directory ${IMAGE_CACHE_DIR}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=os-image-server

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
log "Service unit installed at ${SERVICE_FILE}"
log "Run: sudo systemctl enable --now os-image-server"
