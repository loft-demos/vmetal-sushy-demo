#!/usr/bin/env bash
# destroy-vms.sh — remove all demo libvirt VMs for vmetal-sushy-demo
#
# Destroys (force-powers-off) and undefines all VMs whose names match
# $SMALL_VM_NAME_PREFIX-N, $MEDIUM_VM_NAME_PREFIX-N, and $LARGE_VM_NAME_PREFIX-N,
# then removes their disk images and the VM inventory file.
#
# Usage:
#   bash scripts/destroy-vms.sh
#
# This is called by reset-demo.sh but can also be run independently.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults
SMALL_VM_COUNT="${SMALL_VM_COUNT:-3}"
SMALL_VM_NAME_PREFIX="${SMALL_VM_NAME_PREFIX:-vmetal-small}"
MEDIUM_VM_COUNT="${MEDIUM_VM_COUNT:-0}"
MEDIUM_VM_NAME_PREFIX="${MEDIUM_VM_NAME_PREFIX:-vmetal-medium}"
LARGE_VM_COUNT="${LARGE_VM_COUNT:-2}"
LARGE_VM_NAME_PREFIX="${LARGE_VM_NAME_PREFIX:-vmetal-large}"
VM_IMAGE_DIR="${VM_IMAGE_DIR:-/var/lib/libvirt/images}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

INVENTORY_FILE="${REPO_ROOT}/configs/vm-inventory.txt"

log()  { echo "[destroy-vms] $*"; }
warn() { echo "[destroy-vms] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# Helper: destroy and undefine one VM
# ---------------------------------------------------------------------------
destroy_vm() {
  local name="$1"

  if ! sudo virsh dominfo "${name}" &>/dev/null; then
    log "Domain '${name}' does not exist — skipping"
    return 0
  fi

  # Force power off if running
  local state
  state=$(sudo virsh domstate "${name}" 2>/dev/null || echo "unknown")
  if [[ "${state}" != "shut off" && "${state}" != "unknown" ]]; then
    log "Force-stopping VM '${name}'..."
    sudo virsh destroy "${name}" || warn "virsh destroy '${name}' returned non-zero (may already be stopped)"
  fi

  # Undefine and remove NVRAM (if any)
  log "Undefining VM '${name}'..."
  sudo virsh undefine "${name}" --nvram 2>/dev/null || sudo virsh undefine "${name}" || warn "Could not undefine '${name}'"

  # Remove disk image
  local disk_path="${VM_IMAGE_DIR}/${name}.qcow2"
  if [[ -f "${disk_path}" ]]; then
    log "Removing disk image: ${disk_path}"
    sudo rm -f "${disk_path}"
  fi
}

# ---------------------------------------------------------------------------
# Destroy small VMs
# ---------------------------------------------------------------------------
log "=== Destroying ${SMALL_VM_COUNT} small VMs ==="
for i in $(seq 1 "${SMALL_VM_COUNT}"); do
  destroy_vm "${SMALL_VM_NAME_PREFIX}-${i}"
done

# ---------------------------------------------------------------------------
# Destroy medium VMs
# ---------------------------------------------------------------------------
log "=== Destroying ${MEDIUM_VM_COUNT} medium VMs ==="
for i in $(seq 1 "${MEDIUM_VM_COUNT}"); do
  destroy_vm "${MEDIUM_VM_NAME_PREFIX}-${i}"
done

# ---------------------------------------------------------------------------
# Destroy large VMs
# ---------------------------------------------------------------------------
log "=== Destroying ${LARGE_VM_COUNT} large VMs ==="
for i in $(seq 1 "${LARGE_VM_COUNT}"); do
  destroy_vm "${LARGE_VM_NAME_PREFIX}-${i}"
done

# ---------------------------------------------------------------------------
# Remove inventory file
# ---------------------------------------------------------------------------
if [[ -f "${INVENTORY_FILE}" ]]; then
  log "Removing VM inventory: ${INVENTORY_FILE}"
  rm -f "${INVENTORY_FILE}"
fi

log "All demo VMs destroyed."
echo ""
echo "Remaining libvirt domains:"
sudo virsh list --all
