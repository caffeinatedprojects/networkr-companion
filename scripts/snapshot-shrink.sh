#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

log "=== SNAPSHOT SHRINK STARTED ==="

log "Cleaning apt cache..."
apt-get clean
rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*

log "Pruning Docker leftover data (safe prune)..."
docker system prune -f >/dev/null 2>&1 || true
docker volume prune -f >/dev/null 2>&1 || true

log "Removing rotated + large logs..."
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.1" -delete
truncate -s 0 /var/log/syslog || true
truncate -s 0 /var/log/auth.log || true

log "Cleaning temporary directories..."
rm -rf /tmp/* /var/tmp/* || true

log "Zeroing free space (optimizes snapshot compression)..."
dd if=/dev/zero of=/EMPTY bs=1M || true
rm -f /EMPTY

log "=== SNAPSHOT SHRINK COMPLETE ==="
echo "Server is now optimized for a small, clean snapshot."