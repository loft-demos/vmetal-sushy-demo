#!/usr/bin/env bash
# install-redfish-topology-service.sh — install the topology-aware Redfish stack

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_FILE="/etc/systemd/system/redfish-topology.service"

log()  { echo "[install-redfish-topology-service] $*"; }
die()  { echo "[install-redfish-topology-service] ERROR: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 not found"

log "Writing systemd unit to ${SERVICE_FILE}..."
sudo tee "${SERVICE_FILE}" >/dev/null <<EOF
[Unit]
Description=Topology-aware Redfish emulator stack
After=network.target libvirtd.service
Requires=libvirtd.service

[Service]
Type=simple
WorkingDirectory=${REPO_ROOT}
ExecStart=/bin/bash ${REPO_ROOT}/scripts/start-redfish-topology-stack.sh
Restart=on-failure
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=redfish-topology

[Install]
WantedBy=multi-user.target
EOF

log "Reloading systemd and enabling redfish-topology service..."
sudo systemctl daemon-reload
sudo systemctl enable redfish-topology
sudo systemctl restart redfish-topology
sleep 2

if sudo systemctl is-active --quiet redfish-topology; then
  log "redfish-topology service is running."
else
  echo "[install-redfish-topology-service] ERROR: Service failed to start." >&2
  sudo systemctl status redfish-topology --no-pager || true
  exit 1
fi

echo ""
echo "====================================================================="
echo " redfish-topology installed as a systemd service."
echo " Status : sudo systemctl status redfish-topology"
echo " Logs   : journalctl -u redfish-topology -f"
echo "====================================================================="
