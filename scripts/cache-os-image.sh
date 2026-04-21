#!/usr/bin/env bash
# cache-os-image.sh — cache one OS image locally and generate a matching OSImage manifest
#
# The IPA ramdisk running inside provisioning VMs has no DNS or internet access —
# it is isolated on the provisioning bridge (172.22.0.0/24). OS images must be
# served from the host at PROVISION_IP so Ironic can reach them.
#
# By default this caches the Ubuntu 24.04 minimal image used by this demo. It can
# also cache additional presets or import a local custom qcow2/raw image and emit
# a matching OSImage manifest under manifests/platform/os-images/.
#
# Usage:
#   bash scripts/cache-os-image.sh
#   bash scripts/cache-os-image.sh ubuntu-server
#   bash scripts/cache-os-image.sh \
#     --name ubuntu-noble-dev \
#     --display-name "Ubuntu 24.04 LTS (Custom Dev)" \
#     --source /path/to/custom-image.img \
#     --filename ubuntu-24.04-dev.img
#
# After running, apply the generated manifest:
#   kubectl apply -f manifests/platform/os-images/<name>.yaml
#
# Then point the relevant NodeProvider node types at that OSImage name:
#   vcluster.com/os-image: <name>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
IMAGE_SERVER_PORT="${IMAGE_SERVER_PORT:-9000}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/srv/os-images}"
MANIFEST_DIR="${REPO_ROOT}/manifests/platform/os-images"

PRESET="${1:-ubuntu-minimal}"
if [[ "${PRESET}" == -* ]]; then
  PRESET="ubuntu-minimal"
else
  shift || true
fi

IMAGE_NAME=""
DISPLAY_NAME=""
IMAGE_URL=""
SOURCE_PATH=""
IMAGE_FILE=""
EXPECTED_CHECKSUM=""
MANIFEST_PATH=""

log()  { echo "[cache-os-image] $*"; }
die()  { echo "[cache-os-image] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  bash scripts/cache-os-image.sh [preset] [options]

Presets:
  ubuntu-minimal   Ubuntu 24.04 minimal cloud image (default)
  ubuntu-server    Ubuntu 24.04 full server cloud image
  custom           No preset values; requires --url or --source

Options:
  --name <name>               OSImage metadata.name
  --display-name <label>      OSImage spec.displayName
  --url <url>                 Download image from URL
  --source <path>             Import an existing local image file
  --filename <filename>       Filename to serve from IMAGE_CACHE_DIR
  --checksum <sha256>         Expected sha256 for download/import verification
  --manifest <path>           Output path for generated OSImage manifest
  --help                      Show this help

Examples:
  bash scripts/cache-os-image.sh
  bash scripts/cache-os-image.sh ubuntu-server
  bash scripts/cache-os-image.sh \
    --name ubuntu-noble-dev \
    --display-name "Ubuntu 24.04 LTS (Dev Tools)" \
    --source /tmp/ubuntu-noble-dev.img \
    --filename ubuntu-noble-dev.img
EOF
}

apply_preset() {
  case "${PRESET}" in
    ubuntu-minimal|minimal)
      IMAGE_NAME="${IMAGE_NAME:-ubuntu-noble}"
      DISPLAY_NAME="${DISPLAY_NAME:-Ubuntu 24.04 LTS (Minimal)}"
      IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img}"
      IMAGE_FILE="${IMAGE_FILE:-ubuntu-24.04-minimal-cloudimg-amd64.img}"
      EXPECTED_CHECKSUM="${EXPECTED_CHECKSUM:-5c246768d1e99cebddedd31fb79a9bdc592e8bd04c90ecd252cbeb5ef9ea66ff}"
      ;;
    ubuntu-server|server)
      IMAGE_NAME="${IMAGE_NAME:-ubuntu-noble-server}"
      DISPLAY_NAME="${DISPLAY_NAME:-Ubuntu 24.04 LTS (Server)}"
      IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/20260307/noble-server-cloudimg-amd64.img}"
      IMAGE_FILE="${IMAGE_FILE:-noble-server-cloudimg-amd64.img}"
      ;;
    custom)
      ;;
    *)
      die "Unknown preset '${PRESET}'. Use --help for supported presets."
      ;;
  esac
}

apply_preset

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      IMAGE_NAME="${2:-}"
      shift 2
      ;;
    --display-name)
      DISPLAY_NAME="${2:-}"
      shift 2
      ;;
    --url)
      IMAGE_URL="${2:-}"
      shift 2
      ;;
    --source)
      SOURCE_PATH="${2:-}"
      shift 2
      ;;
    --filename)
      IMAGE_FILE="${2:-}"
      shift 2
      ;;
    --checksum)
      EXPECTED_CHECKSUM="${2:-}"
      shift 2
      ;;
    --manifest)
      MANIFEST_PATH="${2:-}"
      shift 2
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

if [[ -n "${IMAGE_URL}" && -n "${SOURCE_PATH}" ]]; then
  die "Specify only one of --url or --source."
fi

if [[ -z "${IMAGE_URL}" && -z "${SOURCE_PATH}" ]]; then
  die "No image source specified. Use a preset, --url, or --source."
fi

if [[ -z "${IMAGE_FILE}" ]]; then
  if [[ -n "${IMAGE_URL}" ]]; then
    IMAGE_FILE="$(basename "${IMAGE_URL}")"
  else
    IMAGE_FILE="$(basename "${SOURCE_PATH}")"
  fi
fi

if [[ -z "${IMAGE_NAME}" ]]; then
  die "--name is required when using custom image metadata."
fi

if [[ -z "${DISPLAY_NAME}" ]]; then
  DISPLAY_NAME="${IMAGE_NAME}"
fi

if [[ -z "${MANIFEST_PATH}" ]]; then
  MANIFEST_PATH="${MANIFEST_DIR}/${IMAGE_NAME}.yaml"
fi

if [[ ! -d "${IMAGE_CACHE_DIR}" ]]; then
  log "Creating image cache directory: ${IMAGE_CACHE_DIR}"
  sudo mkdir -p "${IMAGE_CACHE_DIR}"
fi
sudo chown "$(id -u):$(id -g)" "${IMAGE_CACHE_DIR}"

DEST="${IMAGE_CACHE_DIR}/${IMAGE_FILE}"

if [[ -n "${SOURCE_PATH}" ]]; then
  [[ -f "${SOURCE_PATH}" ]] || die "Local source image not found: ${SOURCE_PATH}"

  if [[ "$(realpath "${SOURCE_PATH}")" == "$(realpath -m "${DEST}")" ]]; then
    log "Using existing local image already in cache: ${DEST}"
  else
    log "Importing local image into cache: ${SOURCE_PATH} -> ${DEST}"
    cp "${SOURCE_PATH}" "${DEST}.tmp"
    mv "${DEST}.tmp" "${DEST}"
  fi
else
  if [[ -f "${DEST}" ]]; then
    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
      log "Image already cached at ${DEST}, verifying checksum..."
      actual="$(sha256sum "${DEST}" | awk '{print $1}')"
      if [[ "${actual}" == "${EXPECTED_CHECKSUM}" ]]; then
        log "Checksum OK — skipping download."
      else
        log "Checksum mismatch (got ${actual}), re-downloading..."
        rm -f "${DEST}"
      fi
    else
      log "Image already cached at ${DEST} with no expected upstream checksum provided — reusing it."
    fi
  fi

  if [[ ! -f "${DEST}" ]]; then
    log "Downloading image from ${IMAGE_URL}"
    curl -fL --progress-bar "${IMAGE_URL}" -o "${DEST}.tmp"
    mv "${DEST}.tmp" "${DEST}"
  fi
fi

ACTUAL_CHECKSUM="$(sha256sum "${DEST}" | awk '{print $1}')"
if [[ -n "${EXPECTED_CHECKSUM}" && "${ACTUAL_CHECKSUM}" != "${EXPECTED_CHECKSUM}" ]]; then
  die "Image checksum mismatch: expected ${EXPECTED_CHECKSUM}, got ${ACTUAL_CHECKSUM}"
fi

SERVICE_FILE="/etc/systemd/system/os-image-server.service"
if [[ ! -f "${SERVICE_FILE}" ]]; then
  log "Image server service not installed — installing now..."
  bash "${REPO_ROOT}/scripts/install-image-server.sh"
fi

log "Enabling and starting os-image-server..."
sudo systemctl daemon-reload
sudo systemctl enable --now os-image-server
sudo systemctl restart os-image-server

sleep 1

if ! sudo systemctl is-active --quiet os-image-server; then
  echo "" >&2
  sudo systemctl status os-image-server --no-pager >&2
  die "os-image-server failed to start. See output above."
fi
log "os-image-server is running."

LOCAL_URL="http://${PROVISION_IP}:${IMAGE_SERVER_PORT}/${IMAGE_FILE}"
log "Verifying image URL: ${LOCAL_URL}"
if curl -fsSI "${LOCAL_URL}" > /dev/null 2>&1; then
  log "Image is reachable at ${LOCAL_URL}"
else
  die "Image not reachable at ${LOCAL_URL} — check os-image-server logs: journalctl -u os-image-server"
fi

mkdir -p "$(dirname "${MANIFEST_PATH}")"
cat > "${MANIFEST_PATH}" <<EOF
# Generated by scripts/cache-os-image.sh
apiVersion: management.loft.sh/v1
kind: OSImage
metadata:
  name: ${IMAGE_NAME}
spec:
  displayName: "${DISPLAY_NAME}"
  properties:
    metal3.vcluster.com/image-url: "${LOCAL_URL}"
    metal3.vcluster.com/image-checksum: "${ACTUAL_CHECKSUM}"
    metal3.vcluster.com/image-checksum-type: "sha256"
EOF

echo ""
echo "====================================================================="
echo " OS image cached and served locally."
echo ""
echo " Image name : ${IMAGE_NAME}"
echo " Display    : ${DISPLAY_NAME}"
echo " Local URL  : ${LOCAL_URL}"
echo " Checksum   : ${ACTUAL_CHECKSUM} (sha256)"
echo " Manifest   : ${MANIFEST_PATH}"
echo ""
echo " Apply the generated OSImage:"
echo "   kubectl apply -f ${MANIFEST_PATH}"
echo ""
echo " To use it for new machines, point NodeProvider node types at:"
echo "   vcluster.com/os-image: ${IMAGE_NAME}"
echo ""
echo " Existing default manifest remains available at:"
echo "   manifests/platform/os-image.yaml"
echo "====================================================================="
