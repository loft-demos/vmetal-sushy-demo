#!/usr/bin/env bash
# generate-bmh.sh — generate BareMetalHost and Secret YAML from VM inventory
#
# Reads configs/vm-inventory.txt (written by scripts/create-vms.sh) and
# prints ready-to-apply Kubernetes YAML for each VM: one Secret and one
# BareMetalHost per entry.
#
# Usage:
#   # Preview
#   bash hack/generate-bmh.sh
#
#   # Apply directly
#   bash hack/generate-bmh.sh | kubectl apply -f -
#
#   # Save to file
#   bash hack/generate-bmh.sh > manifests/baremetal/generated-bmh.yaml
#
# Prerequisites:
#   - configs/vm-inventory.txt must exist (run scripts/create-vms.sh first)
#   - .env must be sourced or BMC_USERNAME/BMC_PASSWORD/PROVISION_IP set

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults
BMC_USERNAME="${BMC_USERNAME:-admin}"
BMC_PASSWORD="${BMC_PASSWORD:-password}"
PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
PROVISION_CIDR="${PROVISION_CIDR:-172.22.0.0/24}"
PROVISION_GATEWAY="${PROVISION_GATEWAY:-172.22.0.1}"
SUSHY_PORT="${SUSHY_PORT:-8000}"
# First assignable VM IP — .1 is the bridge, .2 is the DHCP VIP
VM_IP_START="${VM_IP_START:-172.22.0.11}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

INVENTORY_FILE="${REPO_ROOT}/configs/vm-inventory.txt"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${INVENTORY_FILE}" ]] || die "VM inventory not found: ${INVENTORY_FILE}
Run scripts/create-vms.sh first to generate it."

# ---------------------------------------------------------------------------
# Emit YAML for each VM in the inventory
# ---------------------------------------------------------------------------
# Derive the prefix octets and starting last octet from VM_IP_START
ip_prefix="${VM_IP_START%.*}"   # e.g. 172.22.0
ip_last="${VM_IP_START##*.}"    # e.g. 11
prefix_len="${PROVISION_CIDR##*/}"  # e.g. 24
ip_index=0

while read -r line; do
  # Skip comments and blank lines
  [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue

  read -r vm_name uuid mac profile <<< "${line}"

  # Assign sequential IP from provisioning subnet
  vm_ip="${ip_prefix}.$((ip_last + ip_index))"
  ip_index=$((ip_index + 1))

  # Kubernetes resource names must be lowercase DNS labels
  k8s_name="${vm_name}"
  secret_name="${k8s_name}-bmc-creds"
  redfish_addr="redfish+http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"

  cat <<EOF
---
# Secret: BMC credentials for ${vm_name}
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: metal3-system
type: Opaque
stringData:
  username: ${BMC_USERNAME}
  password: ${BMC_PASSWORD}
---
# BareMetalHost: ${vm_name} (profile: ${profile})
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${k8s_name}
  namespace: metal3-system
  labels:
    demo: vmetal
    vmetal-size: ${profile}
  annotations:
    metal3.vcluster.com/ip-address: "${vm_ip}/${prefix_len}"
    metal3.vcluster.com/gateway: "${PROVISION_GATEWAY}"
    metal3.vcluster.com/dns-servers: "8.8.8.8,1.1.1.1"
spec:
  online: true
  automatedCleaningMode: metadata
  bmc:
    address: ${redfish_addr}
    credentialsName: ${secret_name}
    disableCertificateVerification: true
  bootMACAddress: "${mac}"
  rootDeviceHints:
    deviceName: /dev/vda    # virtio block device used by KVM/QEMU VMs
EOF

done < "${INVENTORY_FILE}"
