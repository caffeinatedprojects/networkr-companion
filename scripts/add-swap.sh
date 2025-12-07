#!/usr/bin/env bash
set -euo pipefail

# Simple swap provisioning script
# Usage:
#   sudo bash add-swap.sh            # default 4G
#   sudo bash add-swap.sh 8G         # custom size

SWAP_SIZE="${1:-4G}"
SWAP_FILE="/swapfile"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

require_root

log "Checking for existing swap..."
if swapon --show | grep -q '^'; then
  log "Swap is already active. No changes made."
  exit 0
fi

if [[ -f "${SWAP_FILE}" ]]; then
  log "Swap file ${SWAP_FILE} already exists but is not active."
  log "Enabling existing swap file..."
  chmod 600 "${SWAP_FILE}"
  mkswap "${SWAP_FILE}"
  swapon "${SWAP_FILE}"
else
  log "Creating swap file ${SWAP_FILE} (${SWAP_SIZE})..."
  fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}" || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$(( ${SWAP_SIZE%G} * 1024 ))
  chmod 600 "${SWAP_FILE}"
  mkswap "${SWAP_FILE}"
  swapon "${SWAP_FILE}"
fi

if ! grep -q "${SWAP_FILE}" /etc/fstab; then
  log "Adding swap entry to /etc/fstab..."
  echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
fi

log "Swap provisioning complete."
swapon --show