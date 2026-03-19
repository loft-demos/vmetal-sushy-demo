#!/usr/bin/env bash
# print-hosts-entry.sh — print the /etc/hosts line to add on your Mac
#
# vCluster Platform requires a resolvable FQDN (not a bare IP) for cookie
# domains and OAuth redirects. The simplest solution for a same-LAN demo is
# to add one line to /etc/hosts on your Mac.
#
# Run this on the MINISFORUM host (after .env is configured):
#   bash hack/print-hosts-entry.sh
#
# Then copy the printed line and on your Mac run:
#   sudo sh -c 'echo "<line>" >> /etc/hosts'
#
# To remove it later, delete the line with your editor or:
#   sudo sed -i '' '/vmetal\.demo\.local/d' /etc/hosts   # macOS sed syntax

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"
VCP_LOFT_HOST="${VCP_LOFT_HOST:-vmetal.demo.local}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

[[ -z "${METALLB_IP_RANGE}" ]] && {
  echo "ERROR: METALLB_IP_RANGE is not set in .env" >&2
  exit 1
}

# Extract the first (or only) IP from the range (format: "x.x.x.x-x.x.x.x" or "x.x.x.x-x.x.x.x")
METALLB_IP="${METALLB_IP_RANGE%%-*}"

HOSTS_LINE="${METALLB_IP}  ${VCP_LOFT_HOST}"

echo ""
echo "Add this line to /etc/hosts on your Mac:"
echo ""
echo "  ${HOSTS_LINE}"
echo ""
echo "Quick command to add it (run on your Mac):"
echo ""
echo "  sudo sh -c 'echo \"${HOSTS_LINE}\" >> /etc/hosts'"
echo ""
echo "Verify resolution from your Mac after adding:"
echo ""
echo "  ping -c1 ${VCP_LOFT_HOST}"
echo "  # expected: replies from ${METALLB_IP}"
echo ""
echo "Platform UI will be at: http://${VCP_LOFT_HOST}"
