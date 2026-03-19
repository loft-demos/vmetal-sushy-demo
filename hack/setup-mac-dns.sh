#!/usr/bin/env bash
# setup-mac-dns.sh — configure macOS to resolve *.VDEMO_DOMAIN via the demo host
#
# Creates /etc/resolver/<VDEMO_DOMAIN> pointing at the MINISFORUM's LAN IP.
# macOS reads per-domain resolver files from /etc/resolver/ and forwards all
# queries for that domain (including wildcards) to the listed nameserver.
#
# This means every *.vdemo.local hostname (vcp.vdemo.local, argocd.vdemo.local,
# grafana.vdemo.local, ...) resolves automatically — no /etc/hosts entries needed.
#
# Prerequisites:
#   - install-dnsmasq.sh has been run on the MINISFORUM host
#   - The MINISFORUM is reachable on the LAN
#
# Run this on your Mac (not on the MINISFORUM):
#   bash hack/setup-mac-dns.sh
#
# To remove later:
#   sudo rm /etc/resolver/<VDEMO_DOMAIN>
#   sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VDEMO_DOMAIN="${VDEMO_DOMAIN:-vdemo.local}"
LAN_IP="${LAN_IP:-}"          # IP of the MINISFORUM on your LAN (where dnsmasq listens)
VCP_LOFT_HOST="${VCP_LOFT_HOST:-vcp.vdemo.local}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: This script is for macOS only." >&2
  exit 1
fi

if [[ -z "${LAN_IP}" ]]; then
  echo "ERROR: LAN_IP is not set in .env (the MINISFORUM's LAN IP address where dnsmasq listens)." >&2
  echo "  Add to .env:  LAN_IP=192.168.1.x" >&2
  exit 1
fi

RESOLVER_DIR="/etc/resolver"
RESOLVER_FILE="${RESOLVER_DIR}/${VDEMO_DOMAIN}"

echo ""
echo "====================================================================="
echo " macOS DNS setup for *.${VDEMO_DOMAIN}"
echo " Nameserver : ${LAN_IP} (dnsmasq on MINISFORUM)"
echo " Resolver   : ${RESOLVER_FILE}"
echo "====================================================================="
echo ""

# ---------------------------------------------------------------------------
# Create /etc/resolver/<VDEMO_DOMAIN>
# ---------------------------------------------------------------------------
if [[ -f "${RESOLVER_FILE}" ]]; then
  existing=$(grep -E '^nameserver' "${RESOLVER_FILE}" 2>/dev/null | awk '{print $2}' | head -1 || true)
  if [[ "${existing}" == "${LAN_IP}" ]]; then
    echo "Already configured: ${RESOLVER_FILE} already points to ${LAN_IP}"
    echo ""
  else
    echo "Updating ${RESOLVER_FILE} (was: ${existing}, now: ${LAN_IP})..."
    sudo tee "${RESOLVER_FILE}" > /dev/null <<EOF
# vmetal-sushy-demo: wildcard DNS for *.${VDEMO_DOMAIN}
# Managed by hack/setup-mac-dns.sh — remove with: sudo rm ${RESOLVER_FILE}
nameserver ${LAN_IP}
EOF
    echo "Updated."
    echo ""
  fi
else
  echo "Creating ${RESOLVER_FILE}..."
  sudo mkdir -p "${RESOLVER_DIR}"
  sudo tee "${RESOLVER_FILE}" > /dev/null <<EOF
# vmetal-sushy-demo: wildcard DNS for *.${VDEMO_DOMAIN}
# Managed by hack/setup-mac-dns.sh — remove with: sudo rm ${RESOLVER_FILE}
nameserver ${LAN_IP}
EOF
  echo "Created."
  echo ""
fi

# ---------------------------------------------------------------------------
# Flush DNS cache
# ---------------------------------------------------------------------------
echo "Flushing macOS DNS cache..."
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder 2>/dev/null || true
echo "Done."
echo ""

# ---------------------------------------------------------------------------
# Verify resolution
# ---------------------------------------------------------------------------
echo "Verifying: ${VCP_LOFT_HOST} should resolve to ${LAN_IP}..."
sleep 1   # give mDNSResponder a moment to reload

resolved=$(dig +short "${VCP_LOFT_HOST}" 2>/dev/null | tail -1 || true)

if [[ "${resolved}" == "${LAN_IP}" ]]; then
  echo "  OK: ${VCP_LOFT_HOST} → ${resolved}"
else
  echo "  WARNING: got '${resolved}', expected '${LAN_IP}'"
  echo "  This may be normal if dnsmasq is not yet running on the MINISFORUM."
  echo "  Run:  bash scripts/install-dnsmasq.sh   (on the MINISFORUM)"
  echo "  Then re-run this script to re-verify."
fi

echo ""
echo "====================================================================="
echo " Setup complete."
echo ""
echo " All *.${VDEMO_DOMAIN} hostnames now resolve via ${LAN_IP}."
echo " No /etc/hosts entries needed."
echo ""
echo " Platform UI (once vCluster is running):"
echo "   http://${VCP_LOFT_HOST}"
echo ""
echo " To remove later:"
echo "   sudo rm ${RESOLVER_FILE}"
echo "   sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
echo "====================================================================="
