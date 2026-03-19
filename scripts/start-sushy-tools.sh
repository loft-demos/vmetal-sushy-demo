#!/usr/bin/env bash
# start-sushy-tools.sh — install and run sushy-tools in the foreground
#
# Installs sushy-tools into a Python venv (idempotent), deploys the config
# file, then starts the Redfish emulator in the foreground.
#
# To run as a persistent background service instead, use:
#   bash scripts/install-sushy-service.sh
#
# Usage:
#   bash scripts/start-sushy-tools.sh
#
# Prerequisites: bootstrap-host.sh must have been run (libvirt-dev required
# for the libvirt-python pip dependency).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults
SUSHY_PORT="${SUSHY_PORT:-8000}"
SUSHY_LIBVIRT_URI="${SUSHY_LIBVIRT_URI:-qemu:///system}"
SUSHY_LISTEN_IP="${SUSHY_LISTEN_IP:-}"
SUSHY_VENV="${SUSHY_VENV:-/opt/sushy-tools}"
SUSHY_CONF_DIR="${SUSHY_CONF_DIR:-/etc/sushy-tools}"
PROVISION_IP="${PROVISION_IP:-172.22.0.1}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

CONF_SRC="${REPO_ROOT}/configs/sushy-tools.conf"
CONF_DEST="${SUSHY_CONF_DIR}/emulator.conf"

log()  { echo "[sushy-tools] $*"; }
die()  { echo "[sushy-tools] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Preflight checks
# ---------------------------------------------------------------------------
command -v python3 &>/dev/null || die "python3 not found — run bootstrap-host.sh first"
command -v virsh   &>/dev/null || die "virsh not found — run bootstrap-host.sh first"

if ! sudo virsh list &>/dev/null; then
  die "Cannot connect to libvirt. Is libvirtd running? Does your user have libvirt group access?"
fi

# ---------------------------------------------------------------------------
# 2. Create Python venv if not present
# ---------------------------------------------------------------------------
if [[ ! -x "${SUSHY_VENV}/bin/python3" ]]; then
  log "Creating Python venv at ${SUSHY_VENV}..."
  sudo python3 -m venv "${SUSHY_VENV}"
else
  log "Python venv already exists at ${SUSHY_VENV}."
fi

# ---------------------------------------------------------------------------
# 3. Install sushy-tools and libvirt-python into venv
# ---------------------------------------------------------------------------
log "Installing sushy-tools and libvirt-python (this may take a moment)..."
sudo "${SUSHY_VENV}/bin/pip" install --quiet --upgrade pip
sudo "${SUSHY_VENV}/bin/pip" install --quiet sushy-tools libvirt-python

log "Installed version: $(${SUSHY_VENV}/bin/sushy-emulator --version 2>&1 || true)"

# ---------------------------------------------------------------------------
# 4. Deploy config file
# ---------------------------------------------------------------------------
log "Deploying config to ${CONF_DEST}..."
sudo mkdir -p "${SUSHY_CONF_DIR}"
sudo cp "${CONF_SRC}" "${CONF_DEST}"

# Apply .env overrides to the deployed config
# We sed-replace the relevant Python config values if env vars are non-empty.
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
# 5. Start sushy-emulator in the foreground
# ---------------------------------------------------------------------------
LISTEN_ADDR="${SUSHY_LISTEN_IP:-0.0.0.0}"

echo ""
echo "====================================================================="
echo " Starting sushy-tools Redfish emulator"
echo " Listening : ${LISTEN_ADDR}:${SUSHY_PORT}"
echo " Config    : ${CONF_DEST}"
echo " libvirt   : ${SUSHY_LIBVIRT_URI}"
echo ""
echo " Press Ctrl+C to stop."
echo " To run as a systemd service: bash scripts/install-sushy-service.sh"
echo "====================================================================="
echo ""

# Brief pause to let the user read the banner before log output starts
sleep 1

exec sudo "${SUSHY_VENV}/bin/sushy-emulator" --config "${CONF_DEST}"
