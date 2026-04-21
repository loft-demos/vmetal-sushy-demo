#!/usr/bin/env bash
# install-dnsmasq.sh — configure dnsmasq to resolve *.VDEMO_DOMAIN on the LAN
#
# Installs dnsmasq and configures it to:
#   - Resolve *.VDEMO_DOMAIN (e.g. *.vdemo.local) → GATEWAY_IP
#   - Listen on LAN_INTERFACE and, when present, the provisioning bridge
#   - Forward all other queries to upstream DNS
#
# On Ubuntu 24.04, systemd-resolved owns 127.0.0.53:53. By binding dnsmasq
# exclusively to the LAN interface IP, the two coexist without conflict.
#
# After this script runs, every machine on the LAN can resolve *.VDEMO_DOMAIN
# by pointing its DNS at LAN_IP. Your Mac only needs one resolver file:
#   /etc/resolver/vdemo.local  →  nameserver <LAN_IP>
# Run hack/setup-mac-dns.sh for that step.
#
# Usage:
#   bash scripts/install-dnsmasq.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LAN_INTERFACE="${LAN_INTERFACE:-enp1s0}"
PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
PROVISION_IP="${PROVISION_IP:-}"
VDEMO_DOMAIN="${VDEMO_DOMAIN:-vdemo.local}"
GATEWAY_IP="${GATEWAY_IP:-}"
UPSTREAM_DNS_SERVERS="${UPSTREAM_DNS_SERVERS:-}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

log()  { echo "[install-dnsmasq] $*"; }
die()  { echo "[install-dnsmasq] ERROR: $*" >&2; exit 1; }

collect_dns_servers() {
  if [[ -n "${UPSTREAM_DNS_SERVERS}" ]]; then
    printf '%s\n' "${UPSTREAM_DNS_SERVERS}" | tr ', ' '\n\n' | awk 'NF'
    return
  fi

  if command -v resolvectl &>/dev/null; then
    resolvectl dns "${LAN_INTERFACE}" 2>/dev/null \
      | awk -F': ' 'NF > 1 {print $2}' \
      | tr ' ' '\n'
  fi

  if [[ -r /run/systemd/resolve/resolv.conf ]]; then
    awk '/^nameserver /{print $2}' /run/systemd/resolve/resolv.conf
  fi

  if [[ -r /etc/resolv.conf ]]; then
    awk '/^nameserver /{print $2}' /etc/resolv.conf
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ -z "${GATEWAY_IP}" ]] && die "GATEWAY_IP is not set in .env"

# Resolve the LAN IP from the interface name
LAN_IP=$(ip -4 addr show "${LAN_INTERFACE}" 2>/dev/null \
  | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

[[ -z "${LAN_IP}" ]] && die \
  "Could not find an IPv4 address on ${LAN_INTERFACE}. Check LAN_INTERFACE in .env."

log "LAN interface : ${LAN_INTERFACE} (${LAN_IP})"
log "Wildcard zone : *.${VDEMO_DOMAIN} → ${GATEWAY_IP}"

declare -a UPSTREAM_DNS_LIST=()
declare -A SEEN_DNS=()

while read -r dns_server; do
  [[ -z "${dns_server}" ]] && continue
  [[ "${dns_server}" == "127.0.0.53" || "${dns_server}" == "127.0.0.54" ]] && continue
  [[ "${dns_server}" == "::1" ]] && continue
  [[ -n "${SEEN_DNS[${dns_server}]:-}" ]] && continue
  SEEN_DNS["${dns_server}"]=1
  UPSTREAM_DNS_LIST+=("${dns_server}")
done < <(collect_dns_servers)

if [[ "${#UPSTREAM_DNS_LIST[@]}" -eq 0 ]]; then
  log "No upstream DNS servers detected from ${LAN_INTERFACE}; falling back to 1.1.1.1 and 8.8.8.8"
  UPSTREAM_DNS_LIST=("1.1.1.1" "8.8.8.8")
fi

DNSMASQ_SERVER_LINES=""
for dns_server in "${UPSTREAM_DNS_LIST[@]}"; do
  DNSMASQ_SERVER_LINES+=$'server='"${dns_server}"$'\n'
done
log "Upstream DNS : ${UPSTREAM_DNS_LIST[*]}"

PROVISION_DNS_ENABLED=false
DNSMASQ_INTERFACE_LINES=$'interface='"${LAN_INTERFACE}"
DNSMASQ_LISTEN_ADDRESSES="${LAN_IP}"
PROVISION_DNS_COMMENT="# Provisioning bridge not detected; dnsmasq will listen on the LAN only."

if [[ -n "${PROVISION_IP}" ]] && ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  PROVISION_DNS_ENABLED=true
  DNSMASQ_INTERFACE_LINES+=$'\n'"interface=${PROVISION_BRIDGE}"
  DNSMASQ_LISTEN_ADDRESSES+=",${PROVISION_IP}"
  PROVISION_DNS_COMMENT="# Provisioned nodes can use ${PROVISION_IP} on ${PROVISION_BRIDGE} for DNS."
  log "Provision bridge: ${PROVISION_BRIDGE} (${PROVISION_IP})"
else
  log "Provision bridge: ${PROVISION_BRIDGE} not detected — listening on LAN only"
fi

# ---------------------------------------------------------------------------
# Install dnsmasq
# ---------------------------------------------------------------------------
log "Installing dnsmasq..."
sudo apt-get update -q
sudo apt-get install -y dnsmasq

# ---------------------------------------------------------------------------
# Write config drop-in
# Using bind-interfaces + interface= keeps dnsmasq off 127.0.0.1/127.0.0.53
# so it doesn't fight systemd-resolved.
# ---------------------------------------------------------------------------
CONF_FILE="/etc/dnsmasq.d/vdemo.conf"
log "Writing ${CONF_FILE}..."

sudo tee "${CONF_FILE}" > /dev/null <<EOF
# vmetal-sushy-demo: wildcard DNS for *.${VDEMO_DOMAIN}
# Managed by install-dnsmasq.sh — do not edit manually.

# Bind only to the chosen interfaces so we don't conflict with systemd-resolved
# which owns 127.0.0.53 on Ubuntu 24.04.
bind-interfaces
${DNSMASQ_INTERFACE_LINES}
listen-address=${DNSMASQ_LISTEN_ADDRESSES}
except-interface=lo
${PROVISION_DNS_COMMENT}

# Resolve all *.${VDEMO_DOMAIN} subdomains to the Gateway IP.
# Add more address= lines here for other local domains as needed.
address=/.${VDEMO_DOMAIN}/${GATEWAY_IP}

# Forward everything else to the detected or configured upstream DNS.
no-resolv
${DNSMASQ_SERVER_LINES}

# Don't read /etc/hosts for this interface (avoids stale entries).
no-hosts

# Logging (comment out after confirming everything works)
# log-queries
EOF

# ---------------------------------------------------------------------------
# Ensure nothing OTHER than dnsmasq is on the configured IPs for port 53.
# dnsmasq itself holding the port is fine — we're about to restart it with our
# config. systemd-resolved only ever binds to 127.0.0.53/127.0.0.54.
# ---------------------------------------------------------------------------
DNSMASQ_BIND_IPS=("${LAN_IP}")
if [[ "${PROVISION_DNS_ENABLED}" == "true" ]]; then
  DNSMASQ_BIND_IPS+=("${PROVISION_IP}")
fi

for bind_ip in "${DNSMASQ_BIND_IPS[@]}"; do
  if sudo ss -lnup 2>/dev/null | grep "${bind_ip}:53" | grep -qv "dnsmasq"; then
    die "Port 53 is already in use on ${bind_ip} by a non-dnsmasq process. Check: sudo ss -lnup | grep :53"
  fi
done

# ---------------------------------------------------------------------------
# Enable and restart dnsmasq
# ---------------------------------------------------------------------------
log "Enabling and starting dnsmasq..."
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

# Give it a moment
sleep 1

if ! sudo systemctl is-active --quiet dnsmasq; then
  echo "[install-dnsmasq] ERROR: dnsmasq failed to start." >&2
  sudo systemctl status dnsmasq --no-pager || true
  exit 1
fi

# ---------------------------------------------------------------------------
# Open firewall port if ufw is active
# ---------------------------------------------------------------------------
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  log "ufw is active — allowing DNS (53/udp,53/tcp) on dnsmasq interfaces..."
  sudo ufw allow in on "${LAN_INTERFACE}" to any port 53 proto udp comment "dnsmasq vdemo"
  sudo ufw allow in on "${LAN_INTERFACE}" to any port 53 proto tcp comment "dnsmasq vdemo"
  if [[ "${PROVISION_DNS_ENABLED}" == "true" ]]; then
    sudo ufw allow in on "${PROVISION_BRIDGE}" to any port 53 proto udp comment "dnsmasq vdemo"
    sudo ufw allow in on "${PROVISION_BRIDGE}" to any port 53 proto tcp comment "dnsmasq vdemo"
  fi
fi

# ---------------------------------------------------------------------------
# Quick self-test from the host
# ---------------------------------------------------------------------------
log "Testing resolution from this host..."
if command -v dig &>/dev/null; then
  result=$(dig +short "vcp.${VDEMO_DOMAIN}" @"${LAN_IP}" 2>/dev/null || true)
  if [[ "${result}" == "${GATEWAY_IP}" ]]; then
    log "Self-test passed: vcp.${VDEMO_DOMAIN} → ${result}"
  else
    echo "[install-dnsmasq] WARNING: dig returned '${result}', expected '${GATEWAY_IP}'" >&2
    echo "  Check /etc/dnsmasq.d/vdemo.conf and: sudo journalctl -u dnsmasq -n 20" >&2
  fi
  if [[ "${PROVISION_DNS_ENABLED}" == "true" ]]; then
    provision_result=$(dig +short "vcp.${VDEMO_DOMAIN}" @"${PROVISION_IP}" 2>/dev/null || true)
    if [[ "${provision_result}" == "${GATEWAY_IP}" ]]; then
      log "Provisioning self-test passed: vcp.${VDEMO_DOMAIN} → ${provision_result}"
    else
      echo "[install-dnsmasq] WARNING: dig via ${PROVISION_IP} returned '${provision_result}', expected '${GATEWAY_IP}'" >&2
      echo "  Check that ${PROVISION_BRIDGE} exists and dnsmasq is listening on ${PROVISION_IP}:53" >&2
    fi
  fi
else
  log "dig not available — skipping self-test (install dnsutils to enable)"
fi

echo ""
echo "====================================================================="
echo " dnsmasq configured."
echo " Zone    : *.${VDEMO_DOMAIN} → ${GATEWAY_IP}"
echo " Listens : ${LAN_IP}:53"
if [[ "${PROVISION_DNS_ENABLED}" == "true" ]]; then
  echo "           ${PROVISION_IP}:53"
fi
echo ""
echo " Next: set up your Mac to use this server for ${VDEMO_DOMAIN}:"
echo "   bash hack/setup-mac-dns.sh"
echo "====================================================================="
