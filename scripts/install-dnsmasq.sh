#!/usr/bin/env bash
# install-dnsmasq.sh — configure dnsmasq to resolve *.VDEMO_DOMAIN on the LAN
#
# Installs dnsmasq and configures it to:
#   - Resolve *.VDEMO_DOMAIN (e.g. *.vdemo.local) → GATEWAY_IP
#   - Listen only on LAN_INTERFACE (avoids conflict with systemd-resolved)
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
VDEMO_DOMAIN="${VDEMO_DOMAIN:-vdemo.local}"
GATEWAY_IP="${GATEWAY_IP:-}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

log()  { echo "[install-dnsmasq] $*"; }
die()  { echo "[install-dnsmasq] ERROR: $*" >&2; exit 1; }

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

# Bind only to the LAN interface so we don't conflict with systemd-resolved
# which owns 127.0.0.53 on Ubuntu 24.04.
bind-interfaces
interface=${LAN_INTERFACE}
listen-address=${LAN_IP}
except-interface=lo

# Resolve all *.${VDEMO_DOMAIN} subdomains to the Gateway IP.
# Add more address= lines here for other local domains as needed.
address=/.${VDEMO_DOMAIN}/${GATEWAY_IP}

# Forward everything else to public DNS.
no-resolv
server=1.1.1.1
server=8.8.8.8

# Don't read /etc/hosts for this interface (avoids stale entries).
no-hosts

# Logging (comment out after confirming everything works)
# log-queries
EOF

# ---------------------------------------------------------------------------
# Ensure nothing OTHER than dnsmasq is on the LAN IP port 53.
# dnsmasq itself holding the port is fine — we're about to restart it with our config.
# systemd-resolved only ever binds to 127.0.0.53/127.0.0.54, not the LAN IP.
# ---------------------------------------------------------------------------
if sudo ss -lnup 2>/dev/null | grep "${LAN_IP}:53" | grep -qv "dnsmasq"; then
  die "Port 53 is already in use on ${LAN_IP} by a non-dnsmasq process. Check: sudo ss -lnup | grep :53"
fi

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
  log "ufw is active — allowing DNS (53/udp) from LAN..."
  sudo ufw allow in on "${LAN_INTERFACE}" to any port 53 proto udp comment "dnsmasq vdemo"
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
else
  log "dig not available — skipping self-test (install dnsutils to enable)"
fi

echo ""
echo "====================================================================="
echo " dnsmasq configured."
echo " Zone    : *.${VDEMO_DOMAIN} → ${GATEWAY_IP}"
echo " Listens : ${LAN_IP}:53"
echo ""
echo " Next: set up your Mac to use this server for ${VDEMO_DOMAIN}:"
echo "   bash hack/setup-mac-dns.sh"
echo "====================================================================="
