#!/usr/bin/env bash
# install-sushy-service.sh — install sushy-tools as a systemd service
#
# Installs the venv + config (same as start-sushy-tools.sh) and then
# writes a systemd unit so sushy-tools starts automatically on boot
# and restarts on failure.
#
# Usage:
#   bash scripts/install-sushy-service.sh
#   sudo systemctl status sushy-tools
#
# To uninstall:
#   sudo systemctl disable --now sushy-tools
#   sudo rm /etc/systemd/system/sushy-tools.service

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults
SUSHY_PORT="${SUSHY_PORT:-8000}"
SUSHY_LIBVIRT_URI="${SUSHY_LIBVIRT_URI:-qemu:///system}"
SUSHY_LISTEN_IP="${SUSHY_LISTEN_IP:-}"
SUSHY_VENV="${SUSHY_VENV:-/opt/sushy-tools}"
SUSHY_CONF_DIR="${SUSHY_CONF_DIR:-/etc/sushy-tools}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

CONF_SRC="${REPO_ROOT}/configs/sushy-tools.conf"
CONF_DEST="${SUSHY_CONF_DIR}/emulator.conf"
SERVICE_FILE="/etc/systemd/system/sushy-tools.service"

log()  { echo "[install-sushy-service] $*"; }
die()  { echo "[install-sushy-service] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Install venv and packages (reuse start-sushy-tools.sh logic)
# ---------------------------------------------------------------------------
command -v python3 &>/dev/null || die "python3 not found — run bootstrap-host.sh first"

if [[ ! -x "${SUSHY_VENV}/bin/python3" ]]; then
  log "Creating Python venv at ${SUSHY_VENV}..."
  sudo python3 -m venv "${SUSHY_VENV}"
fi

log "Installing sushy-tools and libvirt-python..."
sudo "${SUSHY_VENV}/bin/pip" install --quiet --upgrade pip
sudo "${SUSHY_VENV}/bin/pip" install --quiet sushy-tools libvirt-python

# ---------------------------------------------------------------------------
# 2. Deploy config
# ---------------------------------------------------------------------------
log "Deploying config to ${CONF_DEST}..."
sudo mkdir -p "${SUSHY_CONF_DIR}"
sudo cp "${CONF_SRC}" "${CONF_DEST}"

if [[ -n "${SUSHY_PORT}" ]]; then
  sudo sed -i "s|^SUSHY_EMULATOR_LISTEN_PORT = .*|SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_PORT}|" "${CONF_DEST}"
fi
if [[ -n "${SUSHY_LIBVIRT_URI}" ]]; then
  sudo sed -i "s|^SUSHY_EMULATOR_LIBVIRT_URI = .*|SUSHY_EMULATOR_LIBVIRT_URI = u'${SUSHY_LIBVIRT_URI}'|" "${CONF_DEST}"
fi
if [[ -n "${SUSHY_LISTEN_IP}" ]]; then
  sudo sed -i "s|^SUSHY_EMULATOR_LISTEN_IP = .*|SUSHY_EMULATOR_LISTEN_IP = u'${SUSHY_LISTEN_IP}'|" "${CONF_DEST}"
fi

# ---------------------------------------------------------------------------
# 3. Write systemd unit
# ---------------------------------------------------------------------------
log "Writing systemd unit to ${SERVICE_FILE}..."

sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=Sushy Tools Redfish Emulator
Documentation=https://docs.openstack.org/sushy-tools/latest/
After=network.target libvirtd.service
Requires=libvirtd.service

[Service]
Type=simple
ExecStart=${SUSHY_VENV}/bin/sushy-emulator --config ${CONF_DEST}
Restart=on-failure
RestartSec=5

# Allow access to libvirt system socket
# The process runs as root so it can reach qemu:///system
User=root

# Log to journald
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sushy-tools

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# 4. Enable and start the service
# ---------------------------------------------------------------------------
log "Reloading systemd and enabling sushy-tools service..."
sudo systemctl daemon-reload
sudo systemctl enable sushy-tools
sudo systemctl restart sushy-tools

# Give it a moment to come up
sleep 2

if sudo systemctl is-active --quiet sushy-tools; then
  log "sushy-tools service is running."
else
  echo "[install-sushy-service] ERROR: Service failed to start." >&2
  sudo systemctl status sushy-tools --no-pager || true
  exit 1
fi

echo ""
echo "====================================================================="
echo " sushy-tools installed as a systemd service."
echo " Status : sudo systemctl status sushy-tools"
echo " Logs   : journalctl -u sushy-tools -f"
echo " Port   : ${SUSHY_PORT}"
echo "====================================================================="
