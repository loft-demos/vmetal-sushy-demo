#!/usr/bin/env bash
# create-bridges.sh — create the provisioning Linux bridge for vmetal-sushy-demo
#
# Creates br-provision (or $PROVISION_BRIDGE) as an isolated Linux bridge with
# STP disabled. Metal3/Ironic will provide DHCP on this network — do NOT
# attach another DHCP server to this bridge.
#
# For a single-machine demo the bridge does not need a physical NIC enslaved.
# VMs attach to it directly and the host bridge IP is the gateway/Redfish endpoint.
#
# Run after bootstrap-host.sh:
#   bash scripts/create-bridges.sh
#
# Safe to re-run — exits cleanly if the bridge already exists.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults, then overlay with .env if present
PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
PROVISION_CIDR="${PROVISION_CIDR:-172.22.0.0/24}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

log()  { echo "[create-bridges] $*"; }
warn() { echo "[create-bridges] WARNING: $*" >&2; }
die()  { echo "[create-bridges] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Check for subnet conflicts with existing libvirt networks
# ---------------------------------------------------------------------------
log "Checking for subnet conflicts..."

# Extract existing libvirt network subnets (requires virsh)
if command -v virsh &>/dev/null; then
  existing_nets=$(sudo virsh net-list --all 2>/dev/null | awk 'NR>2 && NF {print $1}')
  for net in ${existing_nets}; do
    net_xml=$(sudo virsh net-dumpxml "${net}" 2>/dev/null || true)
    if echo "${net_xml}" | grep -q "${PROVISION_CIDR%%/*}"; then
      warn "libvirt network '${net}' may overlap with ${PROVISION_CIDR}. Inspect with: sudo virsh net-dumpxml ${net}"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 2. Check if bridge already exists
# ---------------------------------------------------------------------------
if ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  log "Bridge '${PROVISION_BRIDGE}' already exists — nothing to do."
  ip addr show "${PROVISION_BRIDGE}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Create the bridge using nmcli
# ---------------------------------------------------------------------------
log "Creating bridge '${PROVISION_BRIDGE}' with IP ${PROVISION_IP}/24 (STP disabled)..."

sudo nmcli conn add \
  ifname "${PROVISION_BRIDGE}" \
  type bridge \
  con-name "${PROVISION_BRIDGE}" \
  bridge.stp no \
  ipv4.method manual \
  ipv4.addresses "${PROVISION_IP}/24" \
  ipv6.method disabled

log "Bringing up '${PROVISION_BRIDGE}'..."
sudo nmcli conn up "${PROVISION_BRIDGE}"

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------
if ! ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  die "Bridge '${PROVISION_BRIDGE}' was not created. Check NetworkManager logs."
fi

log "Bridge '${PROVISION_BRIDGE}' is up:"
ip addr show "${PROVISION_BRIDGE}"

echo ""
echo "====================================================================="
echo " Provisioning bridge ready."
echo " Bridge : ${PROVISION_BRIDGE}"
echo " Host IP: ${PROVISION_IP}/24"
echo " Network: ${PROVISION_CIDR}"
echo ""
echo " Do NOT start a DHCP server on this bridge."
echo " Metal3/Ironic (deployed by vMetal) will provide DHCP."
echo "====================================================================="
