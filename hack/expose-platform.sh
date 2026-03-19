#!/usr/bin/env bash
# expose-platform.sh — forward vCluster Platform UI to all interfaces
#
# Use this as a quick alternative to MetalLB if you just want to reach the
# Platform UI from your Mac browser without configuring a LAN IP.
#
# The Platform will be reachable at http://<HOST_LAN_IP>:8080
#
# Usage:
#   bash hack/expose-platform.sh
#   # Then open http://<MINISFORUM_LAN_IP>:8080 in your Mac browser
#
# Note: kubectl port-forward drops connections on inactivity. For a proper
# persistent LAN IP, use MetalLB (configured automatically by install-vcluster.sh).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KUBECONFIG_PATH="/var/lib/vcluster/kubeconfig.yaml"
LOCAL_PORT="${1:-8080}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

[[ -f "${KUBECONFIG_PATH}" ]] || {
  echo "ERROR: ${KUBECONFIG_PATH} not found — run install-vcluster.sh first" >&2
  exit 1
}

# Print the host's LAN IP for convenience
LAN_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '172\.22\.' | head -1)

echo ""
echo "====================================================================="
echo " Forwarding vCluster Platform UI → 0.0.0.0:${LOCAL_PORT}"
echo ""
echo " Open from your Mac browser:"
echo "   http://${LAN_IP:-<HOST_LAN_IP>}:${LOCAL_PORT}"
echo ""
echo " Press Ctrl+C to stop."
echo "====================================================================="
echo ""

exec sudo KUBECONFIG="${KUBECONFIG_PATH}" kubectl port-forward \
  -n vcluster-platform \
  svc/vcluster-platform \
  "${LOCAL_PORT}:80" \
  --address 0.0.0.0
