#!/usr/bin/env bash
# setup-mac-dns.sh - configure macOS to resolve *.VDEMO_DOMAIN via a chosen DNS server
#
# Creates /etc/resolver/<VDEMO_DOMAIN> so macOS forwards all queries for that
# domain (including wildcards) to a specific nameserver.
#
# Default mode uses the MINISFORUM's LAN IP. Optional modes let you switch to a
# Tailscale-reachable DNS server, inspect the current setup, or remove it.
#
# Common usage on your Mac:
#   bash hack/setup-mac-dns.sh
#   bash hack/setup-mac-dns.sh lan
#   bash hack/setup-mac-dns.sh tailscale 100.x.y.z
#   bash hack/setup-mac-dns.sh status
#   bash hack/setup-mac-dns.sh off
#
# To remove later:
#   sudo rm /etc/resolver/<VDEMO_DOMAIN>
#   sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="${1:-lan}"
DNS_SERVER_OVERRIDE="${2:-}"
EXPECTED_IP_OVERRIDE="${3:-}"

VDEMO_DOMAIN="${VDEMO_DOMAIN:-vdemo.local}"
LAN_IP="${LAN_IP:-}"          # IP of the MINISFORUM on your LAN (where dnsmasq listens)
GATEWAY_IP="${GATEWAY_IP:-}"  # IP returned for *.VDEMO_DOMAIN by dnsmasq/MetalLB
TAILSCALE_DNS_IP="${TAILSCALE_DNS_IP:-}"            # Optional Tailscale IP of a DNS server for *.VDEMO_DOMAIN
TAILSCALE_EXPECTED_IP="${TAILSCALE_EXPECTED_IP:-}"  # Optional expected answer in tailscale mode
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

RESOLVER_DIR="/etc/resolver"
RESOLVER_FILE="${RESOLVER_DIR}/${VDEMO_DOMAIN}"

flush_cache() {
  echo "Flushing macOS DNS cache..."
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder 2>/dev/null || true
  echo "Done."
  echo ""
}

print_status() {
  echo ""
  echo "====================================================================="
  echo " macOS DNS status for *.${VDEMO_DOMAIN}"
  echo " Resolver   : ${RESOLVER_FILE}"
  echo "====================================================================="
  if [[ -f "${RESOLVER_FILE}" ]]; then
    cat "${RESOLVER_FILE}"
    echo ""
    current_nameserver=$(awk '/^nameserver /{print $2; exit}' "${RESOLVER_FILE}" 2>/dev/null || true)
    if [[ -n "${current_nameserver}" ]]; then
      echo " Current nameserver: ${current_nameserver}"
    fi
  else
    echo " Resolver file is not present."
  fi
  echo ""

  resolved=$(resolve_host "${VCP_LOFT_HOST}" || true)
  if [[ -n "${resolved}" ]]; then
    echo " ${VCP_LOFT_HOST} -> ${resolved}"
  else
    echo " ${VCP_LOFT_HOST} is not resolving right now"
  fi
  echo "====================================================================="
}

resolve_host() {
  local host="$1"

  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "${host}" 2>/dev/null \
      | awk '/^ip_address: /{print $2}' \
      | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}'
    return
  fi

  if command -v dig >/dev/null 2>&1; then
    dig +short "${host}" 2>/dev/null \
      | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}'
  fi
}

write_resolver() {
  local mode="$1"
  local nameserver="$2"

  echo ""
  echo "====================================================================="
  echo " macOS DNS setup for *.${VDEMO_DOMAIN}"
  echo " Mode       : ${mode}"
  echo " Nameserver : ${nameserver}"
  echo " Resolver   : ${RESOLVER_FILE}"
  echo "====================================================================="
  echo ""

  if [[ -f "${RESOLVER_FILE}" ]]; then
    existing=$(awk '/^nameserver /{print $2; exit}' "${RESOLVER_FILE}" 2>/dev/null || true)
    if [[ "${existing}" == "${nameserver}" ]]; then
      echo "Already configured: ${RESOLVER_FILE} already points to ${nameserver}"
      echo ""
    else
      echo "Updating ${RESOLVER_FILE} (was: ${existing}, now: ${nameserver})..."
      sudo tee "${RESOLVER_FILE}" > /dev/null <<EOF
# vmetal-sushy-demo: wildcard DNS for *.${VDEMO_DOMAIN}
# Managed by hack/setup-mac-dns.sh
nameserver ${nameserver}
EOF
      echo "Updated."
      echo ""
    fi
  else
    echo "Creating ${RESOLVER_FILE}..."
    sudo mkdir -p "${RESOLVER_DIR}"
    sudo tee "${RESOLVER_FILE}" > /dev/null <<EOF
# vmetal-sushy-demo: wildcard DNS for *.${VDEMO_DOMAIN}
# Managed by hack/setup-mac-dns.sh
nameserver ${nameserver}
EOF
    echo "Created."
    echo ""
  fi
}

verify_resolution() {
  local nameserver="$1"
  local expected_ip="$2"

  if [[ -n "${expected_ip}" ]]; then
    echo "Verifying: ${VCP_LOFT_HOST} should resolve to ${expected_ip}..."
  else
    echo "Verifying: ${VCP_LOFT_HOST} resolves through ${nameserver}..."
  fi
  sleep 1

  resolved=$(resolve_host "${VCP_LOFT_HOST}" || true)

  if [[ -n "${expected_ip}" && "${resolved}" == "${expected_ip}" ]]; then
    echo "  OK: ${VCP_LOFT_HOST} -> ${resolved}"
  elif [[ -z "${expected_ip}" && -n "${resolved}" ]]; then
    echo "  OK: ${VCP_LOFT_HOST} -> ${resolved}"
  else
    if [[ -n "${expected_ip}" ]]; then
      echo "  WARNING: got '${resolved}', expected '${expected_ip}'"
    else
      echo "  WARNING: ${VCP_LOFT_HOST} did not resolve"
    fi
    echo "  If you are using a different DNS or routed IP over Tailscale,"
    echo "  set TAILSCALE_EXPECTED_IP or pass it as the third argument."
  fi

  echo ""
  echo "====================================================================="
  echo " Setup complete."
  echo ""
  echo " All *.${VDEMO_DOMAIN} queries now use ${nameserver} as the DNS server."
  echo " No /etc/hosts entries needed."
  echo ""
  echo " Platform UI (once vCluster is running):"
  echo "   https://${VCP_LOFT_HOST}"
  echo ""
  echo " Other modes:"
  echo "   bash hack/setup-mac-dns.sh lan"
  echo "   bash hack/setup-mac-dns.sh tailscale <tailscale-dns-ip> [expected-ip]"
  echo "   bash hack/setup-mac-dns.sh status"
  echo "   bash hack/setup-mac-dns.sh off"
  echo "====================================================================="
}

case "${MODE}" in
  lan)
    if [[ -z "${LAN_IP}" ]]; then
      echo "ERROR: LAN_IP is not set in .env (the MINISFORUM's LAN IP address where dnsmasq listens)." >&2
      echo "  Add to .env:  LAN_IP=192.168.1.x" >&2
      exit 1
    fi
    DNS_SERVER="${DNS_SERVER_OVERRIDE:-${LAN_IP}}"
    EXPECTED_IP="${EXPECTED_IP_OVERRIDE:-${GATEWAY_IP:-}}"
    ;;
  tailscale)
    DNS_SERVER="${DNS_SERVER_OVERRIDE:-${TAILSCALE_DNS_IP:-}}"
    EXPECTED_IP="${EXPECTED_IP_OVERRIDE:-${TAILSCALE_EXPECTED_IP:-${GATEWAY_IP:-}}}"
    if [[ -z "${DNS_SERVER}" ]]; then
      echo "ERROR: tailscale mode needs a DNS server IP." >&2
      echo "  Set TAILSCALE_DNS_IP in .env or run:" >&2
      echo "  bash hack/setup-mac-dns.sh tailscale <tailscale-dns-ip> [expected-ip]" >&2
      exit 1
    fi
    ;;
  status)
    print_status
    exit 0
    ;;
  off)
    echo "Removing ${RESOLVER_FILE}..."
    sudo rm -f "${RESOLVER_FILE}"
    flush_cache
    print_status
    exit 0
    ;;
  *)
    echo "Usage: bash hack/setup-mac-dns.sh [lan|tailscale|status|off] [dns-server-ip] [expected-ip]" >&2
    exit 1
    ;;
esac

write_resolver "${MODE}" "${DNS_SERVER}"
flush_cache
verify_resolution "${DNS_SERVER}" "${EXPECTED_IP}"
