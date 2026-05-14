#!/usr/bin/env bash
# create-vms.sh — create demo libvirt VMs for vmetal-sushy-demo
#
# Creates three profiles of VMs:
#   small   — lightweight worker nodes (default: 4x, 2 vCPU, 4 GB RAM, 40 GB disk, BIOS)
#   medium  — balanced worker nodes (default: 1x, 3 vCPU, 6 GB RAM, 60 GB disk, UEFI)
#   large   — compute-heavy demo nodes (default: 2x, 4 vCPU, 8 GB RAM, 80 GB disk, BIOS)
#
# All VMs are attached to the provisioning bridge ($PROVISION_BRIDGE) and
# configured to PXE-boot first (network), falling back to disk. They have
# no install ISO — Ironic handles OS delivery.
#
# By default, the inventory is spread across two simulated racks (`rack-a` and
# `rack-b`) so the generated BareMetalHosts can exercise rack-aware selectors.
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
TOPOLOGY_GENERATOR="${REPO_ROOT}/hack/generate-redfish-topology.py"

# Load defaults
PROVISION_BRIDGE="${PROVISION_BRIDGE:-br-provision}"
PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
SUSHY_PORT="${SUSHY_PORT:-8000}"
LAN_VM_BRIDGE="${LAN_VM_BRIDGE:-}"

SMALL_VM_COUNT="${SMALL_VM_COUNT:-4}"
SMALL_VM_VCPUS="${SMALL_VM_VCPUS:-2}"
SMALL_VM_RAM_MB="${SMALL_VM_RAM_MB:-4096}"
SMALL_VM_DISK_GB="${SMALL_VM_DISK_GB:-40}"
SMALL_VM_NAME_PREFIX="${SMALL_VM_NAME_PREFIX:-vmetal-small}"
SMALL_VM_FIRMWARE="${SMALL_VM_FIRMWARE:-bios}"
SMALL_VM_SECURE_BOOT="${SMALL_VM_SECURE_BOOT:-false}"

MEDIUM_VM_COUNT="${MEDIUM_VM_COUNT:-1}"
MEDIUM_VM_VCPUS="${MEDIUM_VM_VCPUS:-3}"
MEDIUM_VM_RAM_MB="${MEDIUM_VM_RAM_MB:-6144}"
MEDIUM_VM_DISK_GB="${MEDIUM_VM_DISK_GB:-60}"
MEDIUM_VM_NAME_PREFIX="${MEDIUM_VM_NAME_PREFIX:-vmetal-medium}"
MEDIUM_VM_FIRMWARE="${MEDIUM_VM_FIRMWARE:-uefi}"
MEDIUM_VM_SECURE_BOOT="${MEDIUM_VM_SECURE_BOOT:-false}"

LARGE_VM_COUNT="${LARGE_VM_COUNT:-2}"
LARGE_VM_VCPUS="${LARGE_VM_VCPUS:-4}"
LARGE_VM_RAM_MB="${LARGE_VM_RAM_MB:-8192}"
LARGE_VM_DISK_GB="${LARGE_VM_DISK_GB:-80}"
LARGE_VM_NAME_PREFIX="${LARGE_VM_NAME_PREFIX:-vmetal-large}"
LARGE_VM_FIRMWARE="${LARGE_VM_FIRMWARE:-bios}"
LARGE_VM_SECURE_BOOT="${LARGE_VM_SECURE_BOOT:-false}"
RACK_NAMES="${RACK_NAMES:-rack-a,rack-b}"

VM_IMAGE_DIR="${VM_IMAGE_DIR:-/var/lib/libvirt/images}"
OVMF_CODE_PATH="${OVMF_CODE_PATH:-/usr/share/OVMF/OVMF_CODE.secboot.fd}"
OVMF_VARS_PATH="${OVMF_VARS_PATH:-/usr/share/OVMF/OVMF_VARS.fd}"
OVMF_SECURE_BOOT_VARS_PATH="${OVMF_SECURE_BOOT_VARS_PATH:-/usr/share/OVMF/OVMF_VARS.ms.fd}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

INVENTORY_FILE="${REPO_ROOT}/configs/vm-inventory.txt"

IFS=',' read -r -a RACKS <<< "${RACK_NAMES}"

log()  { echo "[create-vms] $*"; }
die()  { echo "[create-vms] ERROR: $*" >&2; exit 1; }

[[ ${#RACKS[@]} -gt 0 ]] || die "RACK_NAMES must contain at least one rack name"
for rack in "${RACKS[@]}"; do
  [[ -n "${rack}" ]] || die "RACK_NAMES cannot contain empty rack names"
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
command -v virsh      &>/dev/null || die "virsh not found — run bootstrap-host.sh first"
command -v virt-install &>/dev/null || die "virt-install not found — run bootstrap-host.sh first"

if ! ip link show "${PROVISION_BRIDGE}" &>/dev/null; then
  die "Bridge '${PROVISION_BRIDGE}' not found — run create-bridges.sh first"
fi

if [[ -n "${LAN_VM_BRIDGE}" ]] && ! ip link show "${LAN_VM_BRIDGE}" &>/dev/null; then
  die "LAN bridge '${LAN_VM_BRIDGE}' not found — run create-bridges.sh first or unset LAN_VM_BRIDGE"
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
#   profile_byte: aa for small, dd for medium, bb for large
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

gen_lan_mac() {
  local profile="$1"
  local index="$2"

  case "${profile}" in
    aa) gen_mac "ac" "${index}" ;;
    dd) gen_mac "dc" "${index}" ;;
    bb) gen_mac "bc" "${index}" ;;
    *) die "Unsupported LAN MAC profile '${profile}'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Helper: normalize booleans from env/defaults.
# ---------------------------------------------------------------------------
is_true() {
  case "${1,,}" in
    true|yes|1|on) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Helper: distribute inventory across simulated racks in round-robin order.
# ---------------------------------------------------------------------------
rack_for_index() {
  local index="$1"
  local rack_index=$(( (index - 1) % ${#RACKS[@]} ))
  echo "${RACKS[$rack_index]}"
}

# ---------------------------------------------------------------------------
# Helper: create one VM
# Usage:
#   create_vm <name> <vcpus> <ram_mb> <disk_gb> <prov_mac> <firmware> <secure_boot> [lan_mac]
# ---------------------------------------------------------------------------
create_vm() {
  local name="$1"
  local vcpus="$2"
  local ram_mb="$3"
  local disk_gb="$4"
  local mac="$5"
  local firmware="${6:-bios}"
  local secure_boot="${7:-false}"
  local lan_mac="${8:-}"
  local disk_path="${VM_IMAGE_DIR}/${name}.qcow2"
  local boot_args="network,hd,menu=off"
  local nvram_template=""
  local secure_flag="no"
  local -a virt_install_args=()

  if sudo virsh dominfo "${name}" &>/dev/null; then
    log "Domain '${name}' already exists — skipping"
    return 0
  fi

  if [[ "${firmware}" == "uefi" ]]; then
    [[ -f "${OVMF_CODE_PATH}" ]] || die "OVMF code image not found at ${OVMF_CODE_PATH}. Run bootstrap-host.sh first or override OVMF_CODE_PATH."
    if is_true "${secure_boot}"; then
      [[ -f "${OVMF_SECURE_BOOT_VARS_PATH}" ]] || die "Secure Boot vars image not found at ${OVMF_SECURE_BOOT_VARS_PATH}. Run bootstrap-host.sh first or override OVMF_SECURE_BOOT_VARS_PATH."
      nvram_template="${OVMF_SECURE_BOOT_VARS_PATH}"
      secure_flag="yes"
    else
      [[ -f "${OVMF_VARS_PATH}" ]] || die "OVMF vars image not found at ${OVMF_VARS_PATH}. Run bootstrap-host.sh first or override OVMF_VARS_PATH."
      nvram_template="${OVMF_VARS_PATH}"
    fi
  elif [[ "${firmware}" != "bios" ]]; then
    die "Unsupported firmware '${firmware}' for ${name}. Use 'bios' or 'uefi'."
  fi

  log "Creating VM: ${name} (${vcpus} vCPU, ${ram_mb} MB RAM, ${disk_gb} GB disk, PXE MAC ${mac}, firmware ${firmware})"

  # Pre-create an empty qcow2 disk. virt-install --import needs an existing disk
  # file; the VM boots from network (PXE via Metal3/Ironic) so the disk starts empty.
  if [[ ! -f "${disk_path}" ]]; then
    sudo qemu-img create -f qcow2 "${disk_path}" "${disk_gb}G"
  fi

  # --import: skip OS install, just define the VM using the existing disk.
  # --boot network,hd: PXE first, then fall through to disk on subsequent boots.
  # The medium profile defaults to UEFI so it can serve as a dedicated firmware
  # demo lane without changing the stock small/large BIOS-style flow.
  if [[ "${firmware}" == "uefi" ]]; then
    boot_args="network,hd,menu=off,loader=${OVMF_CODE_PATH},loader.readonly=yes,loader.type=pflash,loader.secure=${secure_flag},nvram.template=${nvram_template}"
  fi

  virt_install_args=(
    --name "${name}"
    --vcpus "${vcpus}"
    --memory "${ram_mb}"
    --disk "path=${disk_path},format=qcow2,bus=virtio"
    --network "bridge:${PROVISION_BRIDGE},model=virtio,mac=${mac}"
  )

  if [[ -n "${LAN_VM_BRIDGE}" ]]; then
    virt_install_args+=(--network "bridge:${LAN_VM_BRIDGE},model=virtio,mac=${lan_mac}")
  fi

  virt_install_args+=(
    --boot "${boot_args}"
    --os-variant "ubuntu24.04"
    --graphics "none"
    --console "pty,target_type=serial"
    --noautoconsole
    --import
    --noreboot
  )

  sudo virt-install "${virt_install_args[@]}"

  log "VM '${name}' defined successfully."
}

# ---------------------------------------------------------------------------
# Create small VMs
# ---------------------------------------------------------------------------
log "=== Creating ${SMALL_VM_COUNT} small VMs ==="
for i in $(seq 1 "${SMALL_VM_COUNT}"); do
  vm_name="${SMALL_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "aa" "${i}")
  lan_mac=$(gen_lan_mac "aa" "${i}")
  create_vm "${vm_name}" "${SMALL_VM_VCPUS}" "${SMALL_VM_RAM_MB}" "${SMALL_VM_DISK_GB}" "${mac}" "${SMALL_VM_FIRMWARE}" "${SMALL_VM_SECURE_BOOT}" "${lan_mac}"
done

# ---------------------------------------------------------------------------
# Create medium VMs
# ---------------------------------------------------------------------------
log "=== Creating ${MEDIUM_VM_COUNT} medium VMs ==="
for i in $(seq 1 "${MEDIUM_VM_COUNT}"); do
  vm_name="${MEDIUM_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "dd" "${i}")
  lan_mac=$(gen_lan_mac "dd" "${i}")
  create_vm "${vm_name}" "${MEDIUM_VM_VCPUS}" "${MEDIUM_VM_RAM_MB}" "${MEDIUM_VM_DISK_GB}" "${mac}" "${MEDIUM_VM_FIRMWARE}" "${MEDIUM_VM_SECURE_BOOT}" "${lan_mac}"
done

# ---------------------------------------------------------------------------
# Create large VMs
# ---------------------------------------------------------------------------
log "=== Creating ${LARGE_VM_COUNT} large VMs ==="
for i in $(seq 1 "${LARGE_VM_COUNT}"); do
  vm_name="${LARGE_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "bb" "${i}")
  lan_mac=$(gen_lan_mac "bb" "${i}")
  create_vm "${vm_name}" "${LARGE_VM_VCPUS}" "${LARGE_VM_RAM_MB}" "${LARGE_VM_DISK_GB}" "${mac}" "${LARGE_VM_FIRMWARE}" "${LARGE_VM_SECURE_BOOT}" "${lan_mac}"
done

# ---------------------------------------------------------------------------
# Write VM inventory
# Format: <name> <uuid> <mac> <profile> <firmware> <rack> [lan-mac]
# Used by hack/generate-bmh.sh to produce BareMetalHost manifests.
# ---------------------------------------------------------------------------
log "Writing VM inventory to ${INVENTORY_FILE}..."

# Truncate and write header
cat > "${INVENTORY_FILE}" <<'EOF'
# vmetal-sushy-demo VM inventory
# Auto-generated by create-vms.sh — do not edit manually.
# Format: NAME UUID MAC PROFILE FIRMWARE RACK [LAN_MAC]
# Used by hack/generate-bmh.sh to generate rack-aware BareMetalHost manifests.
EOF

for i in $(seq 1 "${SMALL_VM_COUNT}"); do
  vm_name="${SMALL_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "aa" "${i}")
  lan_mac=$(gen_lan_mac "aa" "${i}")
  uuid=$(sudo virsh dominfo "${vm_name}" 2>/dev/null | awk '/^UUID/{print $2}' || echo "UNKNOWN")
  rack=$(rack_for_index "${i}")
  if [[ -n "${LAN_VM_BRIDGE}" ]]; then
    echo "${vm_name} ${uuid} ${mac} small ${SMALL_VM_FIRMWARE} ${rack} ${lan_mac}" >> "${INVENTORY_FILE}"
  else
    echo "${vm_name} ${uuid} ${mac} small ${SMALL_VM_FIRMWARE} ${rack}" >> "${INVENTORY_FILE}"
  fi
done

for i in $(seq 1 "${MEDIUM_VM_COUNT}"); do
  vm_name="${MEDIUM_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "dd" "${i}")
  lan_mac=$(gen_lan_mac "dd" "${i}")
  uuid=$(sudo virsh dominfo "${vm_name}" 2>/dev/null | awk '/^UUID/{print $2}' || echo "UNKNOWN")
  rack=$(rack_for_index "${i}")
  if [[ -n "${LAN_VM_BRIDGE}" ]]; then
    echo "${vm_name} ${uuid} ${mac} medium ${MEDIUM_VM_FIRMWARE} ${rack} ${lan_mac}" >> "${INVENTORY_FILE}"
  else
    echo "${vm_name} ${uuid} ${mac} medium ${MEDIUM_VM_FIRMWARE} ${rack}" >> "${INVENTORY_FILE}"
  fi
done

for i in $(seq 1 "${LARGE_VM_COUNT}"); do
  vm_name="${LARGE_VM_NAME_PREFIX}-${i}"
  mac=$(gen_mac "bb" "${i}")
  lan_mac=$(gen_lan_mac "bb" "${i}")
  uuid=$(sudo virsh dominfo "${vm_name}" 2>/dev/null | awk '/^UUID/{print $2}' || echo "UNKNOWN")
  rack=$(rack_for_index "${i}")
  if [[ -n "${LAN_VM_BRIDGE}" ]]; then
    echo "${vm_name} ${uuid} ${mac} large ${LARGE_VM_FIRMWARE} ${rack} ${lan_mac}" >> "${INVENTORY_FILE}"
  else
    echo "${vm_name} ${uuid} ${mac} large ${LARGE_VM_FIRMWARE} ${rack}" >> "${INVENTORY_FILE}"
  fi
done

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
HOST_IP="${PROVISION_IP}"

echo ""
echo "====================================================================="
printf "%-22s %-38s %-19s %-8s %-8s %-8s %s\n" "NAME" "UUID" "MAC" "PROFILE" "FW" "RACK" "REDFISH URL"
echo "---------------------------------------------------------------------"
while read -r line; do
  [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue
  read -r name uuid mac profile firmware rack <<< "${line}"
  redfish_url="http://${HOST_IP}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"
  printf "%-22s %-38s %-19s %-8s %-8s %-8s %s\n" "${name}" "${uuid}" "${mac}" "${profile}" "${firmware}" "${rack}" "${redfish_url}"
done < "${INVENTORY_FILE}"
echo "====================================================================="
echo ""
echo "Inventory saved to: ${INVENTORY_FILE}"

if [[ -x "${TOPOLOGY_GENERATOR}" ]]; then
  TOPOLOGY_FILE="${REPO_ROOT}/configs/redfish-topology.json"
  python3 "${TOPOLOGY_GENERATOR}" \
    --inventory "${INVENTORY_FILE}" \
    --output "${TOPOLOGY_FILE}"
  echo "Redfish topology saved to: ${TOPOLOGY_FILE}"
fi

echo "Next step: bash scripts/start-sushy-tools.sh"
echo "Then:       bash hack/generate-bmh.sh | kubectl apply -f -"
