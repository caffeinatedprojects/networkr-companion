#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Fix docker-proxy IPv4 mismatch on boot
# ------------------------------------------------------------------

PROXY_DIR="/home/networkr/docker-proxy"
ENV_FILE="${PROXY_DIR}/.env"
LOG_FILE="/var/log/fix-docker-proxy-ip.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ------------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
  log "ERROR: .env file not found at ${ENV_FILE}"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  log "ERROR: docker not installed"
  exit 1
fi

# ------------------------------------------------------------------
# Get current server IPv4
# ------------------------------------------------------------------

CURRENT_IP="$(hostname -I | awk '{print $1}')"

if [[ -z "$CURRENT_IP" ]]; then
  log "ERROR: Unable to determine current server IP"
  exit 1
fi

# ------------------------------------------------------------------
# Read IPv4 from .env
# ------------------------------------------------------------------

ENV_IP="$(grep -E '^IPv4=' "$ENV_FILE" | cut -d= -f2 || true)"

if [[ -z "$ENV_IP" ]]; then
  log "WARNING: IPv4 not set in .env, forcing update"
  ENV_IP="__missing__"
fi

log "Current IP : ${CURRENT_IP}"
log "Env IP     : ${ENV_IP}"

# ------------------------------------------------------------------
# Compare & fix
# ------------------------------------------------------------------

if [[ "$CURRENT_IP" == "$ENV_IP" ]]; then
  log "OK: IPs match — no action needed"
  exit 0
fi

log "IP mismatch detected — updating docker-proxy"

# Update .env safely
sed -i.bak -E "s/^IPv4=.*/IPv4=${CURRENT_IP}/" "$ENV_FILE"

log "Updated .env (backup saved as .env.bak)"

# ------------------------------------------------------------------
# Restart docker-proxy exactly as specified
# ------------------------------------------------------------------

cd "$PROXY_DIR"

log "Stopping docker-proxy containers"
docker compose down --remove-orphans

log "Starting docker-proxy containers"
docker compose up -d

log "docker-proxy restarted successfully"