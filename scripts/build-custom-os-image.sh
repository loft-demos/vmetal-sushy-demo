#!/usr/bin/env bash
# build-custom-os-image.sh — clone a cached base image, add packages, and publish it
#
# This helper uses virt-customize to bake packages or one-off provisioning commands
# into a copy of a cached cloud image. The result is written into IMAGE_CACHE_DIR and
# then registered through cache-os-image.sh so it gets a local URL plus an OSImage
# manifest under manifests/platform/os-images/.
#
# Prerequisite:
#   sudo apt-get install -y libguestfs-tools
#
# Example:
#   bash scripts/build-custom-os-image.sh \
#     --name ubuntu-noble-observability \
#     --display-name "Ubuntu 24.04 LTS (Observability Tools)" \
#     --packages qemu-guest-agent,curl,jq,nfs-common

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/srv/os-images}"
BASE_PRESET="ubuntu-minimal"
BASE_FILE=""
IMAGE_NAME="ubuntu-noble-custom"
DISPLAY_NAME="Ubuntu 24.04 LTS (Custom)"
OUTPUT_FILE=""
PACKAGES=""
FORCE="false"
RUN_COMMANDS=()
COPY_INS=()

log()  { echo "[build-custom-os-image] $*"; }
die()  { echo "[build-custom-os-image] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  bash scripts/build-custom-os-image.sh [options]

Options:
  --base-preset <preset>      Base cached image preset: ubuntu-minimal or ubuntu-server
  --base-file <path>          Base image file to clone instead of a preset
  --name <name>               OSImage metadata.name for the generated image
  --display-name <label>      OSImage spec.displayName
  --output-file <filename>    Output filename in IMAGE_CACHE_DIR
  --packages <pkg1,pkg2>      Comma-separated apt packages to install
  --run-command <command>     Additional virt-customize command; may be repeated
  --copy-in <src:destdir>     Copy files into image; may be repeated
  --force                     Overwrite an existing output image
  --help                      Show this help

Examples:
  bash scripts/build-custom-os-image.sh \
    --name ubuntu-noble-dev \
    --packages qemu-guest-agent,curl,jq

  bash scripts/build-custom-os-image.sh \
    --base-preset ubuntu-server \
    --name ubuntu-noble-ci \
    --packages docker.io,git,make \
    --run-command 'systemctl enable qemu-guest-agent'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-preset)
      BASE_PRESET="${2:-}"
      shift 2
      ;;
    --base-file)
      BASE_FILE="${2:-}"
      shift 2
      ;;
    --name)
      IMAGE_NAME="${2:-}"
      shift 2
      ;;
    --display-name)
      DISPLAY_NAME="${2:-}"
      shift 2
      ;;
    --output-file)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    --packages)
      PACKAGES="${2:-}"
      shift 2
      ;;
    --run-command)
      RUN_COMMANDS+=("${2:-}")
      shift 2
      ;;
    --copy-in)
      COPY_INS+=("${2:-}")
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument '$1'. Use --help for usage."
      ;;
  esac
done

if ! command -v virt-customize >/dev/null 2>&1; then
  die "virt-customize not found. Install it with: sudo apt-get install -y libguestfs-tools"
fi

if [[ -z "${BASE_FILE}" ]]; then
  case "${BASE_PRESET}" in
    ubuntu-minimal|minimal)
      BASE_FILE="${IMAGE_CACHE_DIR}/ubuntu-24.04-minimal-cloudimg-amd64.img"
      ;;
    ubuntu-server|server)
      BASE_FILE="${IMAGE_CACHE_DIR}/noble-server-cloudimg-amd64.img"
      ;;
    *)
      die "Unknown base preset '${BASE_PRESET}'. Use ubuntu-minimal or ubuntu-server."
      ;;
  esac
fi

[[ -f "${BASE_FILE}" ]] || die "Base image not found: ${BASE_FILE}. Cache it first with scripts/cache-os-image.sh."

if [[ -z "${OUTPUT_FILE}" ]]; then
  OUTPUT_FILE="${IMAGE_NAME}.img"
fi

OUTPUT_PATH="${IMAGE_CACHE_DIR}/${OUTPUT_FILE}"
if [[ -f "${OUTPUT_PATH}" && "${FORCE}" != "true" ]]; then
  die "Output image already exists: ${OUTPUT_PATH}. Use --force to overwrite it."
fi

mkdir -p "${IMAGE_CACHE_DIR}"

log "Cloning base image: ${BASE_FILE} -> ${OUTPUT_PATH}"
rm -f "${OUTPUT_PATH}"
cp --reflink=auto "${BASE_FILE}" "${OUTPUT_PATH}"

args=(-a "${OUTPUT_PATH}")

if [[ -n "${PACKAGES}" ]]; then
  args+=(--install "${PACKAGES}")
fi

for copy_in in "${COPY_INS[@]}"; do
  args+=(--copy-in "${copy_in}")
done

for run_cmd in "${RUN_COMMANDS[@]}"; do
  args+=(--run-command "${run_cmd}")
done

log "Customizing image with virt-customize..."
sudo virt-customize "${args[@]}"

log "Publishing customized image and generating OSImage manifest..."
bash "${REPO_ROOT}/scripts/cache-os-image.sh" custom \
  --name "${IMAGE_NAME}" \
  --display-name "${DISPLAY_NAME}" \
  --source "${OUTPUT_PATH}" \
  --filename "${OUTPUT_FILE}"
