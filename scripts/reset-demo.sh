#!/usr/bin/env bash
# reset-demo.sh — full teardown of the vmetal-sushy-demo local environment
#
# Stops sushy-tools, destroys all demo VMs, and removes the provisioning
# bridge. Does NOT touch vCluster Platform or any Kubernetes resources —
# remove BareMetalHost and NodeProvider resources from the platform first.
#
# Usage:
#   bash scripts/reset-demo.sh
#
# To skip individual steps, comment them out below or pass flags:
#   --keep-bridge   Skip bridge removal
#   --keep-vms      Skip VM destruction

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
SUSHY_PORT="${SUSHY_PORT:-8000}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

KEEP_BRIDGE=false
KEEP_VMS=false

for arg in "$@"; do
  case "${arg}" in
    --keep-bridge) KEEP_BRIDGE=true ;;
    --keep-vms)    KEEP_VMS=true ;;
    *) echo "Unknown flag: ${arg}" >&2; exit 1 ;;
  esac
done

log()  { echo "[reset-demo] $*"; }
warn() { echo "[reset-demo] WARNING: $*" >&2; }

echo ""
echo "====================================================================="
echo " vmetal-sushy-demo FULL TEARDOWN"
echo ""
echo " This will:"
[[ "${KEEP_VMS}" == "false" ]]    && echo "   - Destroy all demo libvirt VMs"
[[ "${KEEP_BRIDGE}" == "false" ]] && echo "   - Remove the provisioning bridge (${PROVISION_BRIDGE})"
echo "   - Stop sushy-tools (process or service)"
echo ""
echo " It will NOT remove vCluster Platform or Kubernetes resources."
echo " Remove BareMetalHost and NodeProvider resources from the platform first."
echo "====================================================================="
echo ""
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# 1. Stop sushy-tools
# ---------------------------------------------------------------------------
log "Stopping sushy-tools..."

if sudo systemctl is-active --quiet sushy-tools 2>/dev/null; then
  log "Stopping sushy-tools systemd service..."
  sudo systemctl stop sushy-tools
  sudo systemctl disable sushy-tools 2>/dev/null || true
else
  # Kill any foreground process listening on the sushy port
  if ss -ltnup 2>/dev/null | grep -q ":${SUSHY_PORT}"; then
    log "Killing sushy-emulator process on port ${SUSHY_PORT}..."
    sudo fuser -k "${SUSHY_PORT}/tcp" 2>/dev/null || warn "fuser failed — sushy may already be stopped"
  else
    log "sushy-tools does not appear to be running."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Destroy VMs
# ---------------------------------------------------------------------------
if [[ "${KEEP_VMS}" == "false" ]]; then
  log "Destroying demo VMs..."
  bash "${REPO_ROOT}/scripts/destroy-vms.sh"
else
  log "--keep-vms specified — skipping VM destruction"
fi

# ---------------------------------------------------------------------------
# 3. Remove the provisioning bridge
# ---------------------------------------------------------------------------
if [[ "${KEEP_BRIDGE}" == "false" ]]; then
  if ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
    log "Removing bridge '${PROVISION_BRIDGE}'..."
    sudo ip link set "${PROVISION_BRIDGE}" down 2>/dev/null || true
    sudo ip link delete "${PROVISION_BRIDGE}" type bridge 2>/dev/null || \
      warn "Could not delete bridge interface — it may already be gone"
    sudo rm -f \
      "/etc/systemd/network/10-${PROVISION_BRIDGE}.netdev" \
      "/etc/systemd/network/10-${PROVISION_BRIDGE}.network"
    sudo systemctl reload-or-restart systemd-networkd 2>/dev/null || true
  else
    log "Bridge '${PROVISION_BRIDGE}' does not exist — nothing to remove."
  fi
else
  log "--keep-bridge specified — skipping bridge removal"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo " Teardown complete."
echo ""
echo " Remaining libvirt domains:"
sudo virsh list --all
echo ""
echo " Remaining network interfaces:"
ip -brief link show type bridge 2>/dev/null || true
echo ""
echo " Manual follow-up (in vCluster Platform if still running):"
echo "   kubectl -n metal3-system delete baremetalhost --all"
echo "   kubectl delete nodeprovider metal3-provider"
echo "====================================================================="
