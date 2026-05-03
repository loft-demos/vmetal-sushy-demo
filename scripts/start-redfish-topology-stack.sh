#!/usr/bin/env bash
# start-redfish-topology-stack.sh — run sushy-emulator behind a topology proxy
#
# The proxy serves Chassis resources with mock Location.Placement data while
# forwarding all other Redfish traffic to the live libvirt-backed emulator.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

SUSHY_PORT="${SUSHY_PORT:-8000}"
SUSHY_UPSTREAM_PORT="${SUSHY_UPSTREAM_PORT:-8001}"
SUSHY_LIBVIRT_URI="${SUSHY_LIBVIRT_URI:-qemu:///system}"
SUSHY_LISTEN_IP="${SUSHY_LISTEN_IP:-}"
SUSHY_VENV="${SUSHY_VENV:-/opt/sushy-tools}"
SUSHY_CONF_DIR="${SUSHY_CONF_DIR:-/etc/sushy-tools}"
REDFISH_TOPOLOGY_FILE="${REDFISH_TOPOLOGY_FILE:-${REPO_ROOT}/configs/redfish-topology.json}"
PROXY_SCRIPT="${REPO_ROOT}/hack/redfish-topology-proxy.py"
TOPOLOGY_GENERATOR="${REPO_ROOT}/hack/generate-redfish-topology.py"
CONF_SRC="${REPO_ROOT}/configs/sushy-tools.conf"
CONF_DEST="${SUSHY_CONF_DIR}/emulator-topology.conf"

log()  { echo "[start-redfish-topology-stack] $*"; }
die()  { echo "[start-redfish-topology-stack] ERROR: $*" >&2; exit 1; }

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v virsh >/dev/null 2>&1 || die "virsh not found"

if ! as_root virsh list >/dev/null 2>&1; then
  die "Cannot connect to libvirt. Is libvirtd running?"
fi

if [[ ! -f "${REDFISH_TOPOLOGY_FILE}" ]]; then
  inventory_file="${REPO_ROOT}/configs/vm-inventory.txt"
  [[ -f "${inventory_file}" ]] || die "Missing ${inventory_file}; run scripts/create-vms.sh first"
  log "Generating ${REDFISH_TOPOLOGY_FILE} from ${inventory_file}..."
  python3 "${TOPOLOGY_GENERATOR}" \
    --inventory "${inventory_file}" \
    --output "${REDFISH_TOPOLOGY_FILE}"
fi

if [[ ! -x "${SUSHY_VENV}/bin/python3" ]]; then
  log "Creating Python venv at ${SUSHY_VENV}..."
  as_root python3 -m venv "${SUSHY_VENV}"
fi

log "Installing sushy-tools and libvirt-python..."
as_root "${SUSHY_VENV}/bin/pip" install --quiet --upgrade pip
as_root "${SUSHY_VENV}/bin/pip" install --quiet sushy-tools libvirt-python

log "Deploying config to ${CONF_DEST}..."
as_root mkdir -p "${SUSHY_CONF_DIR}"
as_root cp "${CONF_SRC}" "${CONF_DEST}"
as_root sed -i "s|^SUSHY_EMULATOR_LISTEN_PORT = .*|SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_UPSTREAM_PORT}|" "${CONF_DEST}"
as_root sed -i "s|^SUSHY_EMULATOR_LIBVIRT_URI = .*|SUSHY_EMULATOR_LIBVIRT_URI = u'${SUSHY_LIBVIRT_URI}'|" "${CONF_DEST}"
if [[ -n "${SUSHY_LISTEN_IP}" ]]; then
  as_root sed -i "s|^SUSHY_EMULATOR_LISTEN_IP = .*|SUSHY_EMULATOR_LISTEN_IP = u'${SUSHY_LISTEN_IP}'|" "${CONF_DEST}"
fi

LISTEN_ADDR="${SUSHY_LISTEN_IP:-0.0.0.0}"
cleanup() {
  if [[ -n "${upstream_pid:-}" ]]; then
    kill "${upstream_pid}" >/dev/null 2>&1 || true
    wait "${upstream_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo ""
echo "====================================================================="
echo " Starting Redfish topology stack"
echo " Proxy listen : ${LISTEN_ADDR}:${SUSHY_PORT}"
echo " Upstream     : 127.0.0.1:${SUSHY_UPSTREAM_PORT}"
echo " Topology     : ${REDFISH_TOPOLOGY_FILE}"
echo " Config       : ${CONF_DEST}"
echo "====================================================================="
echo ""

as_root "${SUSHY_VENV}/bin/sushy-emulator" --config "${CONF_DEST}" &
upstream_pid=$!
sleep 1

exec python3 "${PROXY_SCRIPT}" \
  --listen-host "${LISTEN_ADDR}" \
  --listen-port "${SUSHY_PORT}" \
  --upstream-url "http://127.0.0.1:${SUSHY_UPSTREAM_PORT}" \
  --topology-file "${REDFISH_TOPOLOGY_FILE}"
