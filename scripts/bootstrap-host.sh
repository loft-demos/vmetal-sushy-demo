#!/usr/bin/env bash
# bootstrap-host.sh — idempotent Ubuntu 24.04 host setup for vmetal-sushy-demo
#
# Installs required packages, enables libvirtd, and adds the current user
# to the libvirt and kvm groups.
#
# Run as a regular user with sudo access:
#   bash scripts/bootstrap-host.sh
#
# Safe to re-run — apt and group-add operations are idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source .env if present (not strictly needed here but keeps the pattern consistent)
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

log() { echo "[bootstrap] $*"; }
warn() { echo "[bootstrap] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Verify we are on Ubuntu 24.04
# ---------------------------------------------------------------------------
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script targets Ubuntu 24.04; detected OS: ${ID:-unknown}"
  fi
  if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    warn "Detected Ubuntu ${VERSION_ID:-unknown}; script is tested on 24.04 only"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Install packages
# ---------------------------------------------------------------------------
log "Updating apt package index..."
sudo apt-get update -q

log "Installing required packages..."
sudo apt-get install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  bridge-utils \
  virtinst \
  libvirt-dev \
  cpu-checker \
  ovmf \
  python3 \
  python3-pip \
  python3-venv \
  curl \
  git \
  jq

# ---------------------------------------------------------------------------
# 3. Enable and start libvirtd
# ---------------------------------------------------------------------------
log "Enabling and starting libvirtd..."
sudo systemctl enable --now libvirtd

# Confirm the service came up
if ! sudo systemctl is-active --quiet libvirtd; then
  echo "[bootstrap] ERROR: libvirtd failed to start. Check: sudo systemctl status libvirtd" >&2
  exit 1
fi
log "libvirtd is active."

# ---------------------------------------------------------------------------
# 4. Add user to libvirt and kvm groups
# ---------------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-${USER}}"

for grp in libvirt kvm; do
  if id -nG "${TARGET_USER}" | grep -qw "${grp}"; then
    log "User '${TARGET_USER}' is already in group '${grp}' — skipping"
  else
    log "Adding '${TARGET_USER}' to group '${grp}'..."
    sudo usermod -aG "${grp}" "${TARGET_USER}"
  fi
done

# ---------------------------------------------------------------------------
# 5. Check KVM availability
# ---------------------------------------------------------------------------
log "Checking KVM availability..."

if [[ ! -e /dev/kvm ]]; then
  warn "/dev/kvm does not exist. Make sure CPU virtualization (AMD-V / Intel VT-x) is enabled in BIOS/UEFI."
else
  log "/dev/kvm found."
fi

if command -v kvm-ok &>/dev/null; then
  sudo kvm-ok || warn "kvm-ok reported an issue — check BIOS virtualization settings."
fi

# ---------------------------------------------------------------------------
# 6. Install Helm (required for cert-manager and any manual chart operations)
# ---------------------------------------------------------------------------
if command -v helm &>/dev/null; then
  log "Helm already installed: $(helm version --short)"
else
  log "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ---------------------------------------------------------------------------
# 7. OVMF symlinks — Ubuntu 24.04 ships only _4M variants; libvirt and
#    sushy-tools expect the plain names.
# ---------------------------------------------------------------------------
for pair in "OVMF_VARS_4M.fd:OVMF_VARS.fd" "OVMF_CODE_4M.fd:OVMF_CODE.fd" \
            "OVMF_CODE_4M.secboot.fd:OVMF_CODE.secboot.fd" "OVMF_VARS_4M.ms.fd:OVMF_VARS.ms.fd"; do
  src="/usr/share/OVMF/${pair%%:*}"
  dst="/usr/share/OVMF/${pair##*:}"
  if [[ -e "${dst}" ]]; then
    log "OVMF symlink already exists: ${dst} — skipping"
  else
    log "Creating OVMF symlink: ${dst} -> ${src}"
    sudo ln -s "${src}" "${dst}"
  fi
done

# ---------------------------------------------------------------------------
# 8. Install CNI plugins (required by Multus for Metal3 DHCP proxy)
# ---------------------------------------------------------------------------
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.4.0}"
CNI_BIN_DIR="/opt/cni/bin"

if [[ -f "${CNI_BIN_DIR}/static" ]]; then
  log "CNI plugins already installed at ${CNI_BIN_DIR} — skipping"
else
  log "Installing CNI plugins ${CNI_PLUGINS_VERSION}..."
  sudo mkdir -p "${CNI_BIN_DIR}"
  curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" \
    | sudo tar xz -C "${CNI_BIN_DIR}"
  log "CNI plugins installed (includes 'static' plugin needed by Multus)."
fi

# ---------------------------------------------------------------------------
# 7. Print libvirt summary
# ---------------------------------------------------------------------------
log "--- libvirt summary ---"
sudo virsh net-list --all
sudo virsh list --all

# ---------------------------------------------------------------------------
# 7. Remind user about group re-login
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo " Bootstrap complete."
echo ""
echo " IMPORTANT: Log out and log back in (or run 'newgrp libvirt') so"
echo " the new libvirt/kvm group membership takes effect before running"
echo " create-vms.sh or start-sushy-tools.sh."
echo "====================================================================="
