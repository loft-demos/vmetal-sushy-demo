#!/usr/bin/env bash
# create-vms.sh — create demo libvirt VMs for vmetal-sushy-demo
#
# Creates two profiles of VMs:
#   small  — lightweight worker nodes (default: 3x, 2 vCPU, 4 GB RAM, 40 GB disk)
#   large  — compute-heavy demo nodes (default: 2x, 4 vCPU, 8 GB RAM, 80 GB disk)
#
# All VMs are attached to the provisioning bridge ($PROVISION_BRIDGE) and
# configured to PXE-boot first (network), falling back to disk. They have
# no install ISO — Ironic handles OS delivery.
#
# After creation, a VM inventory is written to configs/vm-inventory.txt
# which is used by hack/generate-bmh.sh to produce BareMetalHost manifests.
#
# Run after create-bridges.sh:
#   bash scripts/create-vms.sh
#
# Safe to re-run — existing domains are skipped.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults
PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
SUSHY_PORT="${SUSHY_PORT:-8000}"

SMALL_VM_COUNT="${SMALL_VM_COUNT:-3}"
SMALL_VM_VCPUS="${SMALL_VM_VCPUS:-2}"
SMALL_VM_RAM_MB="${SMALL_VM_RAM_MB:-4096}"
SMALL_VM_DISK_GB="${SMALL_VM_DISK_GB:-40}"
SMALL_VM_NAME_PREFIX="${SMALL_VM_NAME_PREFIX:-vmetal-small}"

LARGE_VM_COUNT="${LARGE_VM_COUNT:-2}"
LARGE_VM_VCPUS="${LARGE_VM_VCPUS:-4}"
LARGE_VM_RAM_MB="${LARGE_VM_RAM_MB:-8192}"
LARGE_VM_DISK_GB="${LARGE_VM_DISK_GB:-80}"
LARGE_VM_NAME_PREFIX="${LARGE_VM_NAME_PREFIX:-vmetal-large}"

VM_IMAGE_DIR="${VM_IMAGE_DIR:-/var/lib/libvirt/images}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

INVENTORY_FILE="${REPO_ROOT}/configs/vm-inventory.txt"

log()  { echo "[create-vms] $*"; }
die()  { echo "[create-vms] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
command -v virsh      &>/dev/null || die "virsh not found — run bootstrap-host.sh first"
command -v virt-install &>/dev/null || die "virt-install not found — run bootstrap-host.sh first"

if ! ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  die "Bridge '${PROVISION_BRIDGE}' not found — run create-bridges.sh first"
fi

# Ensure image directory exists
if [[ ! -d "${VM_IMAGE_DIR}" ]]; then
  log "Creating VM image directory: ${VM_IMAGE_DIR}"
  sudo mkdir -p "${VM_IMAGE_DIR}"
fi

# ---------------------------------------------------------------------------
# Helper: generate a deterministic MAC from a stable index
# Uses the locally-administered prefix 52:54:00 (standard for KVM/QEMU VMs)
# Format: 52:54:00:<profile_byte>:<hi>:<lo>
#   profile_byte: aa for small, bb for large
#   hi / lo: VM index (up to 255 each, so supports up to 65535 VMs — plenty)
# ---------------------------------------------------------------------------
gen_mac() {
  local profile="$1"   # "aa" or "bb"
  local index="$2"     # 1-based integer
  local hi lo
  hi=$(printf '%02x' $(( (index - 1) / 256 )))
  lo=$(printf '%02x' $(( (index - 1) % 256 )))
  echo "52:54:00:${profile}:${hi}:${lo}"
}

# ---------------------------------------------------------------------------
# Helper: create one VM
# Usage: create_vm <name> <vcpus> <ram_mb> <disk_gb> <mac>
# ---------------------------------------------------------------------------
create_vm() {
  local name="$1"
  local vcpus="$2"
  local ram_mb="$3"
  local disk_gb="$4"
  local mac="$5"
  local disk_path="${VM_IMAGE_DIR}/${name}.qcow2"

  if sudo virsh dominfo "${name}" &>/dev/null; then
    log "Domain '${name}' already exists — skipping"
    return 0
  fi

  log "Creating VM: ${name} (${vcpus} vCPU, ${ram_mb} MB RAM, ${disk_gb} GB disk, MAC ${mac})"

  # Pre-create an empty qcow2 disk. virt-install --import needs an existing disk
  # file; the VM boots from network (PXE via Metal3/Ironic) so the disk starts empty.
  if [[ ! -f "${disk_path}" ]]; then
    sudo qemu-img create -f qcow2 "${disk_path}" "${disk_gb}G"
  fi

  # --import: skip OS install, just define the VM using the existing disk.
  # --boot network,hd: PXE first, then fall through to disk on subsequent boots.
  sudo virt-install \
    --name "${name}" \
    --vcpus "${vcpus}" \
    --memory "${ram_mb}" \
    --disk "path=${disk_path},format=qcow2,bus=virtio" \
    --network "bridge:${PROVISION_BRIDGE},model=virtio,mac=${mac}" \
    --boot "network,hd,menu=off" \
    --os-variant "ubuntu24.04" \
    --graphics "none" \
    --console "pty,target_type=serial" \
    --noautoconsole \
    --import \
    --noreboot

  log "VM '${name}' defined successfully."
}

# ---------------------------------------------------------------------------
# Create small VMs
# ---------------------------------------------------------------------------
log "=== Creating ${SMALL_VM_COUNT} small VMs ==="
for i in $(seq 1 "${SMALL_VM_COUNT}"); do
  vm_name="${SMALL_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "aa" "${i}")
  create_vm "${vm_name}" "${SMALL_VM_VCPUS}" "${SMALL_VM_RAM_MB}" "${SMALL_VM_DISK_GB}" "${mac}"
done

# ---------------------------------------------------------------------------
# Create large VMs
# ---------------------------------------------------------------------------
log "=== Creating ${LARGE_VM_COUNT} large VMs ==="
for i in $(seq 1 "${LARGE_VM_COUNT}"); do
  vm_name="${LARGE_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "bb" "${i}")
  create_vm "${vm_name}" "${LARGE_VM_VCPUS}" "${LARGE_VM_RAM_MB}" "${LARGE_VM_DISK_GB}" "${mac}"
done

# ---------------------------------------------------------------------------
# Write VM inventory
# Format: <name> <uuid> <mac> <profile>
# Used by hack/generate-bmh.sh to produce BareMetalHost manifests.
# ---------------------------------------------------------------------------
log "Writing VM inventory to ${INVENTORY_FILE}..."

# Truncate and write header
cat > "${INVENTORY_FILE}" <<'EOF'
# vmetal-sushy-demo VM inventory
# Auto-generated by create-vms.sh — do not edit manually.
# Format: NAME UUID MAC PROFILE
# Used by hack/generate-bmh.sh to generate BareMetalHost manifests.
EOF

for i in $(seq 1 "${SMALL_VM_COUNT}"); do
  vm_name="${SMALL_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "aa" "${i}")
  uuid=$(sudo virsh dominfo "${vm_name}" 2>/dev/null | awk '/^UUID/{print $2}' || echo "UNKNOWN")
  echo "${vm_name} ${uuid} ${mac} small" >> "${INVENTORY_FILE}"
done

for i in $(seq 1 "${LARGE_VM_COUNT}"); do
  vm_name="${LARGE_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "bb" "${i}")
  uuid=$(sudo virsh dominfo "${vm_name}" 2>/dev/null | awk '/^UUID/{print $2}' || echo "UNKNOWN")
  echo "${vm_name} ${uuid} ${mac} large" >> "${INVENTORY_FILE}"
done

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
HOST_IP="${PROVISION_IP}"

echo ""
echo "====================================================================="
printf "%-22s %-38s %-19s %-8s %s\n" "NAME" "UUID" "MAC" "PROFILE" "REDFISH URL"
echo "---------------------------------------------------------------------"
while read -r line; do
  [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue
  read -r name uuid mac profile <<< "${line}"
  redfish_url="http://${HOST_IP}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"
  printf "%-22s %-38s %-19s %-8s %s\n" "${name}" "${uuid}" "${mac}" "${profile}" "${redfish_url}"
done < "${INVENTORY_FILE}"
echo "====================================================================="
echo ""
echo "Inventory saved to: ${INVENTORY_FILE}"
echo "Next step: bash scripts/start-sushy-tools.sh"
echo "Then:       bash hack/generate-bmh.sh | kubectl apply -f -"
