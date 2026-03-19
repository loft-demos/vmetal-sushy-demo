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
# 6. Print libvirt summary
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
