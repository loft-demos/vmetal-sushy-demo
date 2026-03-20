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
# 3. Create the bridge using ip commands (works without NetworkManager)
# ---------------------------------------------------------------------------
log "Creating bridge '${PROVISION_BRIDGE}' with IP ${PROVISION_IP}/24 (STP disabled)..."

sudo ip link add name "${PROVISION_BRIDGE}" type bridge
sudo ip link set "${PROVISION_BRIDGE}" type bridge stp_state 0
sudo ip addr add "${PROVISION_IP}/24" dev "${PROVISION_BRIDGE}"
sudo ip link set "${PROVISION_BRIDGE}" up

# Make the bridge survive a reboot via a systemd-networkd drop-in.
# This works on Ubuntu 24.04 server (networkd backend) without NetworkManager.
NETDEV_FILE="/etc/systemd/network/10-${PROVISION_BRIDGE}.netdev"
NETWORK_FILE="/etc/systemd/network/10-${PROVISION_BRIDGE}.network"

if [[ ! -f "${NETDEV_FILE}" ]]; then
  log "Writing ${NETDEV_FILE} for persistence across reboots..."
  sudo tee "${NETDEV_FILE}" > /dev/null <<EOF
[NetDev]
Name=${PROVISION_BRIDGE}
Kind=bridge

[Bridge]
STP=no
EOF
fi

if [[ ! -f "${NETWORK_FILE}" ]]; then
  log "Writing ${NETWORK_FILE} for persistence across reboots..."
  sudo tee "${NETWORK_FILE}" > /dev/null <<EOF
[Match]
Name=${PROVISION_BRIDGE}

[Network]
Address=${PROVISION_IP}/24
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
fi

# Reload networkd so it is aware of the new config (the bridge is already up)
sudo systemctl reload-or-restart systemd-networkd 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Enable IP forwarding and NAT so provisioning VMs can reach the internet
#
# VMs on the provisioning bridge get DNS servers (8.8.8.8/1.1.1.1) from the
# vCP DHCP proxy, but their queries go nowhere without masquerade. IP forwarding
# + NAT lets them reach the internet through the host's LAN interface for:
#   - DNS resolution
#   - Container image pulls (ghcr.io, docker.io, registry.k8s.io, etc.)
# ---------------------------------------------------------------------------
LAN_INTERFACE="${LAN_INTERFACE:-enp1s0}"

log "Enabling IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1
SYSCTL_CONF="/etc/sysctl.d/99-vmetal-forward.conf"
if [[ ! -f "${SYSCTL_CONF}" ]]; then
  echo "net.ipv4.ip_forward=1" | sudo tee "${SYSCTL_CONF}" > /dev/null
fi

log "Adding FORWARD rules for ${PROVISION_BRIDGE} ↔ ${LAN_INTERFACE}..."
# Ubuntu's default FORWARD policy is DROP. Without these rules, forwarded
# packets from the provisioning subnet are silently dropped even with MASQUERADE set.
if ! sudo iptables -C FORWARD -i "${PROVISION_BRIDGE}" -o "${LAN_INTERFACE}" -j ACCEPT 2>/dev/null; then
  sudo iptables -I FORWARD 1 -i "${PROVISION_BRIDGE}" -o "${LAN_INTERFACE}" -j ACCEPT
  log "FORWARD outbound rule added."
else
  log "FORWARD outbound rule already present — skipping."
fi
if ! sudo iptables -C FORWARD -i "${LAN_INTERFACE}" -o "${PROVISION_BRIDGE}" \
    -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
  sudo iptables -I FORWARD 2 -i "${LAN_INTERFACE}" -o "${PROVISION_BRIDGE}" \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
  log "FORWARD inbound (established) rule added."
else
  log "FORWARD inbound rule already present — skipping."
fi

log "Adding NAT masquerade rule for ${PROVISION_CIDR} via ${LAN_INTERFACE}..."
if ! sudo iptables -t nat -C POSTROUTING \
    -s "${PROVISION_CIDR}" ! -d "${PROVISION_CIDR}" \
    -o "${LAN_INTERFACE}" -j MASQUERADE 2>/dev/null; then
  sudo iptables -t nat -A POSTROUTING \
    -s "${PROVISION_CIDR}" ! -d "${PROVISION_CIDR}" \
    -o "${LAN_INTERFACE}" -j MASQUERADE
  log "NAT rule added."
else
  log "NAT rule already present — skipping."
fi

# Persist iptables rules across reboots
if ! command -v netfilter-persistent &>/dev/null; then
  log "Installing iptables-persistent..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
fi
sudo netfilter-persistent save

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
if ! ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  die "Bridge '${PROVISION_BRIDGE}' was not created."
fi

log "Bridge '${PROVISION_BRIDGE}' is up:"
ip addr show "${PROVISION_BRIDGE}"

echo ""
echo "====================================================================="
echo " Provisioning bridge ready."
echo " Bridge : ${PROVISION_BRIDGE}"
echo " Host IP: ${PROVISION_IP}/24"
echo " Network: ${PROVISION_CIDR}"
echo " NAT out : ${LAN_INTERFACE} (VMs can reach internet)"
echo ""
echo " Do NOT start a DHCP server on this bridge."
echo " Metal3/Ironic (deployed by vMetal) will provide DHCP."
echo "====================================================================="
