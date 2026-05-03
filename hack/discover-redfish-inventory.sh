#!/usr/bin/env bash
# discover-redfish-inventory.sh — build normalized hardware inventory from Redfish
#
# This script queries a Redfish endpoint, discovers Systems, follows Chassis and
# EthernetInterfaces links when available, and writes a normalized inventory file
# consumable by hack/generate-bmh.sh.
#
# Inventory format:
#   NAME UUID MAC PROFILE FIRMWARE RACK CUSTOMER BMC_ADDRESS
#
# The physical topology should come from Redfish where possible:
#   Systems -> Links.Chassis -> Chassis.Location.Placement.Rack
#
# Customer assignment is intentionally kept outside Redfish. In real environments
# that mapping usually lives in CMDB / CRM / rack-allocation data, not in the
# BMC itself. This script models that with configs/rack-assignments.csv.
#
# Usage:
#   bash hack/discover-redfish-inventory.sh
#
# Optional environment overrides:
#   REDFISH_BASE_URL=http://172.22.0.1:8000/redfish/v1
#   REDFISH_USERNAME=admin
#   REDFISH_PASSWORD=password
#   RACK_ASSIGNMENT_FILE=configs/rack-assignments.csv
#   INVENTORY_FILE=configs/vm-inventory.txt
#   DEFAULT_PROFILE=large
#   DEFAULT_FIRMWARE=uefi
#   DEFAULT_CUSTOMER=unassigned
#   ALLOW_TOPOLOGY_FALLBACK=false

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
SUSHY_PORT="${SUSHY_PORT:-8000}"
BMC_USERNAME="${BMC_USERNAME:-admin}"
BMC_PASSWORD="${BMC_PASSWORD:-password}"
REDFISH_BASE_URL="${REDFISH_BASE_URL:-http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1}"
REDFISH_USERNAME="${REDFISH_USERNAME:-${BMC_USERNAME}}"
REDFISH_PASSWORD="${REDFISH_PASSWORD:-${BMC_PASSWORD}}"
RACK_ASSIGNMENT_FILE="${RACK_ASSIGNMENT_FILE:-${REPO_ROOT}/configs/rack-assignments.csv}"
INVENTORY_FILE="${INVENTORY_FILE:-${REPO_ROOT}/configs/vm-inventory.txt}"
DEFAULT_PROFILE="${DEFAULT_PROFILE:-large}"
DEFAULT_FIRMWARE="${DEFAULT_FIRMWARE:-uefi}"
DEFAULT_CUSTOMER="${DEFAULT_CUSTOMER:-unassigned}"
ALLOW_TOPOLOGY_FALLBACK="${ALLOW_TOPOLOGY_FALLBACK:-false}"

log() { echo "[discover-redfish-inventory] $*"; }
warn() { echo "[discover-redfish-inventory] WARNING: $*" >&2; }
die() { echo "[discover-redfish-inventory] ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

case "${REDFISH_BASE_URL}" in
  http://*)
    REDFISH_AUTHORITY="${REDFISH_BASE_URL#http://}"
    REDFISH_AUTHORITY="${REDFISH_AUTHORITY%%/*}"
    REDFISH_HTTP_SCHEME="http"
    REDFISH_BMC_SCHEME="redfish+http"
    ;;
  https://*)
    REDFISH_AUTHORITY="${REDFISH_BASE_URL#https://}"
    REDFISH_AUTHORITY="${REDFISH_AUTHORITY%%/*}"
    REDFISH_HTTP_SCHEME="https"
    REDFISH_BMC_SCHEME="redfish"
    ;;
  *)
    die "REDFISH_BASE_URL must begin with http:// or https://"
    ;;
esac

CURL_ARGS=(-fsSL)
if [[ -n "${REDFISH_USERNAME}" || -n "${REDFISH_PASSWORD}" ]]; then
  CURL_ARGS+=(-u "${REDFISH_USERNAME}:${REDFISH_PASSWORD}")
fi

fetch_json() {
  local url="$1"
  curl "${CURL_ARGS[@]}" "${url}"
}

sanitize_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

build_physical_name() {
  local rack="$1"
  local rack_offset="$2"
  local profile="$3"
  local fallback_name="$4"

  local sanitized_rack
  local sanitized_profile
  local slot
  sanitized_rack="$(sanitize_name "${rack}")"
  sanitized_profile="$(sanitize_name "${profile}")"

  if [[ -n "${rack_offset}" && "${rack_offset}" != "null" && "${rack_offset}" =~ ^[0-9]+$ ]]; then
    slot=$(printf 'u%02d' "${rack_offset}")
    printf '%s\n' "${sanitized_rack}-${slot}-${sanitized_profile}"
    return 0
  fi

  printf '%s\n' "$(sanitize_name "${fallback_name}")"
}

lookup_customer_for_rack() {
  local rack="$1"

  if [[ ! -f "${RACK_ASSIGNMENT_FILE}" ]]; then
    printf '%s\n' "${DEFAULT_CUSTOMER}"
    return 0
  fi

  awk -F',' -v rack="${rack}" -v default_customer="${DEFAULT_CUSTOMER}" '
    BEGIN { customer = default_customer }
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      if (tolower($1) == "rack" && tolower($2) == "customer") {
        next
      }
      if ($1 == rack) {
        customer = $2
      }
    }
    END { print customer }
  ' "${RACK_ASSIGNMENT_FILE}"
}

infer_profile() {
  local cpu="$1"
  local memory_gib="$2"

  if [[ -z "${cpu}" || -z "${memory_gib}" || "${cpu}" == "null" || "${memory_gib}" == "null" ]]; then
    printf '%s\n' "${DEFAULT_PROFILE}"
    return 0
  fi

  if (( cpu <= 2 )) && (( memory_gib <= 4 )); then
    echo "small"
  elif (( cpu <= 3 )) && (( memory_gib <= 6 )); then
    echo "medium"
  else
    echo "large"
  fi
}

infer_firmware() {
  local boot_mode="${1:-}"

  case "${boot_mode^^}" in
    UEFI)
      echo "uefi"
      ;;
    LEGACY)
      echo "bios"
      ;;
    *)
      printf '%s\n' "${DEFAULT_FIRMWARE}"
      ;;
  esac
}

is_true() {
  case "${1,,}" in
    true|yes|1|on) return 0 ;;
    *) return 1 ;;
  esac
}

find_boot_mac() {
  local system_json="$1"
  local system_uri="$2"
  local nic_collection_uri=""
  local nic_uri=""
  local mac=""

  nic_collection_uri="$(printf '%s' "${system_json}" | jq -r '.EthernetInterfaces."@odata.id" // empty')"
  if [[ -z "${nic_collection_uri}" ]]; then
    nic_collection_uri="${system_uri%/}/EthernetInterfaces"
  fi

  if ! nic_uri="$(fetch_json "${REDFISH_HTTP_SCHEME}://${REDFISH_AUTHORITY}${nic_collection_uri}" 2>/dev/null | jq -r '.Members[0]."@odata.id" // empty' 2>/dev/null)"; then
    printf '\n'
    return 0
  fi

  [[ -n "${nic_uri}" ]] || {
    printf '\n'
    return 0
  }

  if ! mac="$(fetch_json "${REDFISH_HTTP_SCHEME}://${REDFISH_AUTHORITY}${nic_uri}" 2>/dev/null | jq -r '.PermanentMACAddress // .MACAddress // empty' 2>/dev/null)"; then
    printf '\n'
    return 0
  fi

  printf '%s\n' "${mac}"
}

log "Querying ${REDFISH_BASE_URL%/}/Systems ..."
systems_json="$(fetch_json "${REDFISH_BASE_URL%/}/Systems")"

cat > "${INVENTORY_FILE}" <<'EOF'
# vmetal-sushy-demo hardware inventory
# Auto-generated by discover-redfish-inventory.sh — do not edit manually.
# Format: NAME UUID MAC PROFILE FIRMWARE RACK CUSTOMER BMC_ADDRESS
EOF

system_count=0
written_count=0

while IFS= read -r system_uri; do
  [[ -n "${system_uri}" ]] || continue
  system_count=$((system_count + 1))

  system_url="${REDFISH_HTTP_SCHEME}://${REDFISH_AUTHORITY}${system_uri}"
  system_json="$(fetch_json "${system_url}")"

  uuid="$(printf '%s' "${system_json}" | jq -r '.UUID // .Id // empty')"
  raw_name="$(printf '%s' "${system_json}" | jq -r '.Name // .HostName // .Id // empty')"
  cpu="$(printf '%s' "${system_json}" | jq -r '.ProcessorSummary.Count // empty')"
  memory_gib="$(printf '%s' "${system_json}" | jq -r '.MemorySummary.TotalSystemMemoryGiB // empty')"
  boot_mode="$(printf '%s' "${system_json}" | jq -r '.Boot.BootSourceOverrideMode // empty')"
  profile="$(infer_profile "${cpu}" "${memory_gib}")"
  firmware="$(infer_firmware "${boot_mode}")"
  mac="$(find_boot_mac "${system_json}" "${system_uri}")"

  chassis_uri="$(printf '%s' "${system_json}" | jq -r '.Links.Chassis[0]."@odata.id" // empty')"
  rack=""
  rack_offset=""
  if [[ -n "${chassis_uri}" ]]; then
    if ! chassis_json="$(fetch_json "${REDFISH_HTTP_SCHEME}://${REDFISH_AUTHORITY}${chassis_uri}" 2>/dev/null)"; then
      warn "Failed to fetch chassis for ${raw_name:-${uuid}} at ${chassis_uri}"
      chassis_json=""
    fi
  else
    chassis_json=""
  fi
  if [[ -n "${chassis_json}" ]]; then
    rack="$(printf '%s' "${chassis_json}" | jq -r '.Location.Placement.Rack // empty')"
    rack_offset="$(printf '%s' "${chassis_json}" | jq -r '.Location.Placement.RackOffset // empty')"
  fi
  if [[ -z "${rack}" ]]; then
    if is_true "${ALLOW_TOPOLOGY_FALLBACK}"; then
      rack="unknown-rack"
    else
      warn "Skipping ${raw_name:-${uuid}} because no usable rack topology was discoverable from Redfish"
      continue
    fi
  fi
  name="$(build_physical_name "${rack}" "${rack_offset}" "${profile}" "${raw_name:-${uuid}}")"

  customer="$(lookup_customer_for_rack "${rack}")"
  bmc_address="${REDFISH_BMC_SCHEME}://${REDFISH_AUTHORITY}${system_uri}"

  if [[ -z "${uuid}" ]]; then
    warn "Skipping ${system_uri} because no UUID/Id was present"
    continue
  fi

  if [[ -z "${name}" ]]; then
    name="$(sanitize_name "${uuid}")"
  fi

  if [[ -z "${mac}" ]]; then
    warn "Skipping ${name} because no MAC address was discoverable from Redfish"
    continue
  fi

  printf '%s %s %s %s %s %s %s %s\n' \
    "${name}" "${uuid}" "${mac}" "${profile}" "${firmware}" "${rack}" "${customer}" "${bmc_address}" \
    >> "${INVENTORY_FILE}"
  written_count=$((written_count + 1))
done < <(printf '%s' "${systems_json}" | jq -r '.Members[]?."@odata.id"')

(( system_count > 0 )) || die "No Systems members were returned by ${REDFISH_BASE_URL%/}/Systems"
(( written_count > 0 )) || die "Systems were discovered, but none produced a usable inventory entry"

log "Wrote inventory to ${INVENTORY_FILE}"
log "Next step: BMC_SHARED_SECRET_NAME=redfish-shared-creds bash hack/generate-bmh.sh | kubectl apply -f -"
