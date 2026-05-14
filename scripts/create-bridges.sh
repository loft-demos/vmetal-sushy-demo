#!/usr/bin/env bash
# create-bridges.sh — create Linux bridges for the vmetal-sushy-demo
#
# Creates br-provision (or $PROVISION_BRIDGE) as an isolated Linux bridge with
# STP disabled. Metal3/Ironic will provide DHCP on this network — do NOT
# attach another DHCP server to this bridge.
#
# Optionally creates a second VM LAN bridge (for example br-lan) that enslaves
# a dedicated physical NIC. This is the safe dual-NIC topology:
#   - keep host SSH / management on LAN_INTERFACE
#   - dedicate LAN_VM_INTERFACE to VM LAN access through LAN_VM_BRIDGE
#
# Run after bootstrap-host.sh:
#   bash scripts/create-bridges.sh
#
# Safe to re-run — repairs bridge settings if they drift after a reboot.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults, then overlay with .env if present
PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
PROVISION_CIDR="${PROVISION_CIDR:-172.22.0.0/24}"
LAN_INTERFACE="${LAN_INTERFACE:-enp1s0}"
LAN_VM_BRIDGE="${LAN_VM_BRIDGE:-}"
LAN_VM_INTERFACE="${LAN_VM_INTERFACE:-}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

PROVISION_PREFIX="${PROVISION_CIDR#*/}"
PROVISION_ADDR="${PROVISION_IP}/${PROVISION_PREFIX}"
log()  { echo "[create-bridges] $*"; }
warn() { echo "[create-bridges] WARNING: $*" >&2; }
die()  { echo "[create-bridges] ERROR: $*" >&2; exit 1; }

PROVISION_NETDEV_FILE="/etc/systemd/network/10-${PROVISION_BRIDGE}.netdev"
PROVISION_NETWORK_FILE="/etc/systemd/network/10-${PROVISION_BRIDGE}.network"
LAN_NETDEV_FILE=""
LAN_NETWORK_FILE=""
LAN_SLAVE_FILE=""

if [[ -n "${LAN_VM_BRIDGE}" ]]; then
  LAN_NETDEV_FILE="/etc/systemd/network/20-${LAN_VM_BRIDGE}.netdev"
  LAN_NETWORK_FILE="/etc/systemd/network/20-${LAN_VM_BRIDGE}.network"
fi
if [[ -n "${LAN_VM_BRIDGE}" && -n "${LAN_VM_INTERFACE}" ]]; then
  LAN_SLAVE_FILE="/etc/systemd/network/20-${LAN_VM_INTERFACE}-to-${LAN_VM_BRIDGE}.network"
fi

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

write_provision_networkd_files() {
  log "Writing ${PROVISION_NETDEV_FILE} for persistence across reboots..."
  sudo tee "${PROVISION_NETDEV_FILE}" > /dev/null <<EOF
[NetDev]
Name=${PROVISION_BRIDGE}
Kind=bridge

[Bridge]
STP=no
EOF

  log "Writing ${PROVISION_NETWORK_FILE} for persistence across reboots..."
  sudo tee "${PROVISION_NETWORK_FILE}" > /dev/null <<EOF
[Match]
Name=${PROVISION_BRIDGE}

[Network]
Address=${PROVISION_ADDR}
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes
KeepConfiguration=static
EOF
}

write_lan_bridge_networkd_files() {
  [[ -n "${LAN_VM_BRIDGE}" ]] || return 0
  [[ -n "${LAN_VM_INTERFACE}" ]] || return 0

  log "Writing ${LAN_NETDEV_FILE} for persistence across reboots..."
  sudo tee "${LAN_NETDEV_FILE}" > /dev/null <<EOF
[NetDev]
Name=${LAN_VM_BRIDGE}
Kind=bridge

[Bridge]
STP=no
EOF

  log "Writing ${LAN_NETWORK_FILE} for persistence across reboots..."
  sudo tee "${LAN_NETWORK_FILE}" > /dev/null <<EOF
[Match]
Name=${LAN_VM_BRIDGE}

[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes
EOF

  log "Writing ${LAN_SLAVE_FILE} for persistence across reboots..."
  sudo tee "${LAN_SLAVE_FILE}" > /dev/null <<EOF
[Match]
Name=${LAN_VM_INTERFACE}

[Network]
Bridge=${LAN_VM_BRIDGE}
EOF
}

# ---------------------------------------------------------------------------
# 2. Create or repair the bridge using ip commands (works without NetworkManager)
# ---------------------------------------------------------------------------
if ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  log "Bridge '${PROVISION_BRIDGE}' already exists — repairing state if needed..."
else
  log "Creating bridge '${PROVISION_BRIDGE}' with IP ${PROVISION_ADDR} (STP disabled)..."
  sudo ip link add name "${PROVISION_BRIDGE}" type bridge
fi

sudo ip link set "${PROVISION_BRIDGE}" type bridge stp_state 0
sudo ip link set "${PROVISION_BRIDGE}" up
write_provision_networkd_files

# Reload networkd so it is aware of the new config (the bridge is already up)
sudo systemctl reload-or-restart systemd-networkd 2>/dev/null || true

if ip -4 addr show dev "${PROVISION_BRIDGE}" | grep -qw "${PROVISION_ADDR}"; then
  log "Bridge address ${PROVISION_ADDR} already present."
else
  log "Assigning ${PROVISION_ADDR} to ${PROVISION_BRIDGE}..."
  sudo ip addr add "${PROVISION_ADDR}" dev "${PROVISION_BRIDGE}"
fi

# ---------------------------------------------------------------------------
# 3. Optionally create a second VM LAN bridge backed by a dedicated NIC
# ---------------------------------------------------------------------------
if [[ -n "${LAN_VM_BRIDGE}" || -n "${LAN_VM_INTERFACE}" ]]; then
  [[ -n "${LAN_VM_BRIDGE}" ]] || die "LAN_VM_INTERFACE requires LAN_VM_BRIDGE to be set"
  [[ -n "${LAN_VM_INTERFACE}" ]] || die "LAN_VM_BRIDGE requires LAN_VM_INTERFACE to be set"
  [[ "${LAN_VM_BRIDGE}" != "${PROVISION_BRIDGE}" ]] || die "LAN_VM_BRIDGE must differ from PROVISION_BRIDGE"
  [[ "${LAN_VM_INTERFACE}" != "${LAN_INTERFACE}" ]] || die "LAN_VM_INTERFACE matches LAN_INTERFACE. Keep SSH on one NIC and dedicate a second NIC to VM LAN bridging."

  ip link show "${LAN_VM_INTERFACE}" &>/dev/null || die "LAN VM interface '${LAN_VM_INTERFACE}' not found"

  if ip -4 addr show dev "${LAN_VM_INTERFACE}" | grep -q 'inet '; then
    die "LAN VM interface '${LAN_VM_INTERFACE}' already has an IPv4 address. Use a dedicated second NIC with no host IP so SSH stays on ${LAN_INTERFACE}."
  fi

  if ip link show "${LAN_VM_BRIDGE}" &>/dev/null; then
    log "LAN bridge '${LAN_VM_BRIDGE}' already exists — repairing state if needed..."
  else
    log "Creating LAN bridge '${LAN_VM_BRIDGE}' for VM workload traffic..."
    sudo ip link add name "${LAN_VM_BRIDGE}" type bridge
  fi

  sudo ip link set "${LAN_VM_BRIDGE}" type bridge stp_state 0
  sudo ip link set "${LAN_VM_BRIDGE}" up
  sudo ip link set "${LAN_VM_INTERFACE}" down || true
  sudo ip link set "${LAN_VM_INTERFACE}" master "${LAN_VM_BRIDGE}"
  sudo ip link set "${LAN_VM_INTERFACE}" up
  write_lan_bridge_networkd_files
  sudo systemctl reload-or-restart systemd-networkd 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Enable IP forwarding and NAT so provisioning VMs can reach the internet
#
# Provisioned VMs can use the host's dnsmasq on PROVISION_IP for split-horizon
# demo DNS such as *.vdemo.local. They still need outbound connectivity for
# container image pulls and any direct internet access after boot.
# ---------------------------------------------------------------------------
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
if ! ip -4 addr show dev "${PROVISION_BRIDGE}" | grep -qw "${PROVISION_ADDR}"; then
  die "Bridge '${PROVISION_BRIDGE}' is missing ${PROVISION_ADDR}."
fi

log "Bridge '${PROVISION_BRIDGE}' is up:"
ip addr show "${PROVISION_BRIDGE}"

echo ""
echo "====================================================================="
echo " Provisioning bridge ready."
echo " Bridge : ${PROVISION_BRIDGE}"
echo " Host IP: ${PROVISION_ADDR}"
echo " Network: ${PROVISION_CIDR}"
echo " NAT out : ${LAN_INTERFACE} (VMs can reach internet)"
if [[ -n "${LAN_VM_BRIDGE}" && -n "${LAN_VM_INTERFACE}" ]]; then
  echo " VM LAN  : ${LAN_VM_BRIDGE} via ${LAN_VM_INTERFACE} (dedicated second NIC)"
fi
echo ""
echo " Do NOT start a DHCP server on this bridge."
echo " Metal3/Ironic (deployed by vMetal) will provide DHCP."
echo "====================================================================="
