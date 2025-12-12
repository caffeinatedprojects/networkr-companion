#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Pressilion – Delete Website
###############################################################################

SITE_USER="${1:-}"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

###############################################################################
# Argument validation
###############################################################################

if [[ -z "${SITE_USER}" ]]; then
  log "❌ ERROR: Missing site user"
  log "Usage: pressilion-delete-site <user-site-xxx>"
  exit 1
fi

SITE_HOME="/home/${SITE_USER}"
COMPOSE_FILE="${SITE_HOME}/docker-compose.yml"
NETWORK_NAME="${SITE_USER}_wordpress-vpc"

###############################################################################
# Start marker (for SSH parsing)
###############################################################################

echo "::PRESSILION_DELETE_START::"

log "🗑️  Starting site deletion"
log "Site user: ${SITE_USER}"
log "Home path: ${SITE_HOME}"

###############################################################################
# Stop containers
###############################################################################

if [[ -f "${COMPOSE_FILE}" ]]; then
  log "Stopping Docker containers..."
  docker compose -f "${COMPOSE_FILE}" down --remove-orphans || true
  log "Containers stopped"
else
  log "No docker-compose file found, skipping container shutdown"
fi

###############################################################################
# Remove Linux user + home
###############################################################################

log "Removing Linux user and home directory..."

deluser --remove-home "${SITE_USER}" >/dev/null 2>&1 || true
rm -rf "${SITE_HOME}" || true

log "User '${SITE_USER}' removed (or did not exist)"

###############################################################################
# Remove Docker network
###############################################################################

log "Removing Docker network '${NETWORK_NAME}' (if exists)..."
docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
log "Network cleanup complete"

###############################################################################
# Completion
###############################################################################

log "✅ Site '${SITE_USER}' has been fully removed"

echo "::PRESSILION_DELETE_END::"