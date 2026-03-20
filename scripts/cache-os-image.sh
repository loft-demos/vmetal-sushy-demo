#!/usr/bin/env bash
# cache-os-image.sh — download Ubuntu OS image to local cache and (re)start image server
#
# The IPA ramdisk running inside provisioning VMs has no DNS or internet access —
# it is isolated on the provisioning bridge (172.22.0.0/24). OS images must be
# served from the host at PROVISION_IP so Ironic can reach them.
#
# This script:
#   1. Creates the image cache directory
#   2. Downloads the Ubuntu 24.04 minimal cloud image (idempotent — skips if present)
#   3. Starts or restarts the image-server systemd service (see install-image-server.sh)
#
# Usage:
#   bash scripts/cache-os-image.sh
#
# After running, update manifests/platform/os-image.yaml to point at the local URL:
#   http://${PROVISION_IP}:${IMAGE_SERVER_PORT}/ubuntu-24.04-minimal-cloudimg-amd64.img
#
# Then re-apply the OSImage and, if a BareMetalHost is stuck in provisioning error,
# delete and re-create it so Metal3 retries with the new URL.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

PROVISION_IP="${PROVISION_IP:-172.22.0.1}"
IMAGE_SERVER_PORT="${IMAGE_SERVER_PORT:-9000}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/srv/os-images}"

UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
UBUNTU_IMAGE_FILE="ubuntu-24.04-minimal-cloudimg-amd64.img"
UBUNTU_CHECKSUM="5c246768d1e99cebddedd31fb79a9bdc592e8bd04c90ecd252cbeb5ef9ea66ff"

log()  { echo "[cache-os-image] $*"; }
die()  { echo "[cache-os-image] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Create image cache directory
# ---------------------------------------------------------------------------
if [[ ! -d "${IMAGE_CACHE_DIR}" ]]; then
  log "Creating image cache directory: ${IMAGE_CACHE_DIR}"
  sudo mkdir -p "${IMAGE_CACHE_DIR}"
fi
sudo chown "$(id -u):$(id -g)" "${IMAGE_CACHE_DIR}"

# ---------------------------------------------------------------------------
# 2. Download image (skip if already present and checksum matches)
# ---------------------------------------------------------------------------
DEST="${IMAGE_CACHE_DIR}/${UBUNTU_IMAGE_FILE}"

if [[ -f "${DEST}" ]]; then
  log "Image already cached at ${DEST}, verifying checksum..."
  actual="$(sha256sum "${DEST}" | awk '{print $1}')"
  if [[ "${actual}" == "${UBUNTU_CHECKSUM}" ]]; then
    log "Checksum OK — skipping download."
  else
    log "Checksum mismatch (got ${actual}), re-downloading..."
    rm -f "${DEST}"
  fi
fi

if [[ ! -f "${DEST}" ]]; then
  log "Downloading Ubuntu 24.04 minimal cloud image (~500 MB)..."
  curl -fL --progress-bar "${UBUNTU_IMAGE_URL}" -o "${DEST}.tmp"
  actual="$(sha256sum "${DEST}.tmp" | awk '{print $1}')"
  if [[ "${actual}" != "${UBUNTU_CHECKSUM}" ]]; then
    rm -f "${DEST}.tmp"
    die "Downloaded image checksum mismatch: expected ${UBUNTU_CHECKSUM}, got ${actual}"
  fi
  mv "${DEST}.tmp" "${DEST}"
  log "Download complete and checksum verified."
fi

# ---------------------------------------------------------------------------
# 3. Start or restart the image server
# ---------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/os-image-server.service"

if [[ ! -f "${SERVICE_FILE}" ]]; then
  log "Image server service not installed — installing now..."
  bash "${REPO_ROOT}/scripts/install-image-server.sh"
fi

log "Enabling and starting os-image-server..."
sudo systemctl daemon-reload
sudo systemctl enable --now os-image-server
sudo systemctl restart os-image-server

# Give it a moment to come up
sleep 1

if ! sudo systemctl is-active --quiet os-image-server; then
  echo "" >&2
  sudo systemctl status os-image-server --no-pager >&2
  die "os-image-server failed to start. See output above."
fi
log "os-image-server is running."

# ---------------------------------------------------------------------------
# 4. Verify the image is reachable
# ---------------------------------------------------------------------------
LOCAL_URL="http://${PROVISION_IP}:${IMAGE_SERVER_PORT}/${UBUNTU_IMAGE_FILE}"
log "Verifying image URL: ${LOCAL_URL}"
if curl -fsSI "${LOCAL_URL}" > /dev/null 2>&1; then
  log "Image is reachable at ${LOCAL_URL}"
else
  die "Image not reachable at ${LOCAL_URL} — check os-image-server logs: journalctl -u os-image-server"
fi

# ---------------------------------------------------------------------------
# 5. Print next steps
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo " OS image cached and served locally."
echo ""
echo " Local URL: ${LOCAL_URL}"
echo " Checksum:  ${UBUNTU_CHECKSUM} (sha256)"
echo ""
echo " Update manifests/platform/os-image.yaml:"
echo "   metal3.vcluster.com/image-url: \"${LOCAL_URL}\""
echo ""
echo " Then re-apply the OSImage:"
echo "   kubectl apply -f manifests/platform/os-image.yaml"
echo ""
echo " If a BareMetalHost is stuck in provisioning error, move it back to"
echo " available so the NodeClaim re-triggers provisioning:"
echo "   kubectl annotate bmh <name> -n metal3-system \\"
echo "     metal3.io/reprovisioning.start='' --overwrite"
echo " Or delete the NodeClaim and let vCluster Platform recreate it."
echo "====================================================================="
