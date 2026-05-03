#!/usr/bin/env bash
# redo-redfish-topology-demo.sh — reapply repo-side topology demo changes on the host
#
# This script is intended to be run on the Ubuntu vMetal host after rsyncing
# repo updates from a workstation. It repairs host/runtime drift and can
# optionally recreate BareMetalHosts from the Redfish + rack mapping flow.
#
# Default behavior:
#   - ensure required script permissions
#   - ensure SUSHY_EMULATOR_FEATURE_SET=full is present in configs/sushy-tools.conf
#   - regenerate VM inventory + Redfish topology
#   - reinstall/restart the topology-aware Redfish service
#   - verify /redfish/v1/Systems and /redfish/v1/Chassis are reachable
#
# Optional flags:
#   --recreate-bmhs         Delete and recreate BareMetalHosts from discovery
#   --reapply-nodeprovider  Render and apply manifests/platform/node-provider-customer-topology.yaml
#   --skip-vms              Do not rerun scripts/create-vms.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/configs/sushy-tools.conf"
NODEPROVIDER_MANIFEST="${REPO_ROOT}/manifests/platform/node-provider-customer-topology.yaml"
RACK_TOPOLOGY_FILE="${REPO_ROOT}/configs/rack-topology.csv"
RACK_ASSIGNMENT_FILE="${REPO_ROOT}/configs/rack-assignments.csv"

RECREATE_BMHS=false
REAPPLY_NODEPROVIDER=false
SKIP_VMS=false

for arg in "$@"; do
  case "${arg}" in
    --recreate-bmhs) RECREATE_BMHS=true ;;
    --reapply-nodeprovider) REAPPLY_NODEPROVIDER=true ;;
    --skip-vms) SKIP_VMS=true ;;
    *)
      echo "Unknown flag: ${arg}" >&2
      exit 1
      ;;
  esac
done

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
SUSHY_PORT="${SUSHY_PORT:-8000}"

log() { echo "[redo-redfish-topology-demo] $*"; }
die() { echo "[redo-redfish-topology-demo] ERROR: $*" >&2; exit 1; }

cd "${REPO_ROOT}"

command -v bash >/dev/null 2>&1 || die "bash not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

log "Ensuring local scripts are executable..."
chmod +x \
  scripts/start-redfish-topology-stack.sh \
  scripts/install-redfish-topology-service.sh \
  scripts/redo-redfish-topology-demo.sh \
  hack/discover-redfish-inventory.sh \
  hack/generate-bmh.sh \
  hack/generate-node-provider-pools.py \
  hack/generate-redfish-topology.py \
  hack/redfish-topology-proxy.py

if grep -q '^SUSHY_EMULATOR_FEATURE_SET = ' "${CONFIG_FILE}"; then
  log "Ensuring Redfish feature set is 'full' in ${CONFIG_FILE}..."
  sed -i "s|^SUSHY_EMULATOR_FEATURE_SET = .*|SUSHY_EMULATOR_FEATURE_SET = u'full'|" "${CONFIG_FILE}"
else
  log "Adding SUSHY_EMULATOR_FEATURE_SET = u'full' to ${CONFIG_FILE}..."
  printf "\nSUSHY_EMULATOR_FEATURE_SET = u'full'\n" >> "${CONFIG_FILE}"
fi

if [[ "${SKIP_VMS}" == "false" ]]; then
  log "Refreshing VM inventory and Redfish topology via scripts/create-vms.sh..."
  bash scripts/create-vms.sh
else
  log "--skip-vms specified; not rerunning scripts/create-vms.sh"
fi

log "Reinstalling/restarting topology-aware Redfish service..."
bash scripts/install-redfish-topology-service.sh

log "Waiting for Redfish Systems endpoint..."
tries=0
until curl -fsSL "http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Systems" >/dev/null; do
  tries=$((tries + 1))
  if [[ "${tries}" -ge 20 ]]; then
    die "Redfish Systems endpoint did not become reachable at http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Systems"
  fi
  sleep 2
done

log "Waiting for Redfish Chassis endpoint..."
tries=0
until curl -fsSL "http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Chassis" >/dev/null; do
  tries=$((tries + 1))
  if [[ "${tries}" -ge 20 ]]; then
    die "Redfish Chassis endpoint did not become reachable at http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Chassis"
  fi
  sleep 2
done

log "Redfish topology service is reachable."

if [[ -f "${RACK_TOPOLOGY_FILE}" && -f "${RACK_ASSIGNMENT_FILE}" ]]; then
  log "Rendering data-center scoped NodeProvider manifest..."
  python3 hack/generate-node-provider-pools.py \
    --rack-topology "${RACK_TOPOLOGY_FILE}" \
    --rack-assignments "${RACK_ASSIGNMENT_FILE}" \
    --output "${NODEPROVIDER_MANIFEST}"
else
  log "Skipping NodeProvider render because ${RACK_TOPOLOGY_FILE} or ${RACK_ASSIGNMENT_FILE} is missing."
fi

if [[ "${RECREATE_BMHS}" == "true" ]]; then
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
  log "Deleting existing BareMetalHosts..."
  kubectl delete baremetalhost --all -n metal3-system --ignore-not-found=true
  log "Discovering inventory from Redfish..."
  bash hack/discover-redfish-inventory.sh
  log "Recreating BareMetalHosts from discovered inventory..."
  BMC_SHARED_SECRET_NAME=redfish-shared-creds bash hack/generate-bmh.sh | kubectl apply -f -
fi

if [[ "${REAPPLY_NODEPROVIDER}" == "true" ]]; then
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
  log "Reapplying data-center scoped NodeProvider..."
  kubectl apply -f "${NODEPROVIDER_MANIFEST}"
fi

log "Done."
echo ""
echo "Suggested next checks:"
echo "  curl -fsSL http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Systems | jq ."
echo "  curl -fsSL http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Chassis | jq ."
echo "  sed -n '1,20p' configs/vm-inventory.txt"
