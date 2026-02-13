#!/bin/bash
set -euo pipefail

log() {
  echo "[pressillion_provision] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

CREATE_SUDO=0
SUDO_USER=""
SUDO_PASS=""
API_SECRET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-sudo-user)
      CREATE_SUDO="${2:-}"
      shift 2
      ;;
    --sudo-user)
      SUDO_USER="${2:-}"
      shift 2
      ;;
    --sudo-pass)
      SUDO_PASS="${2:-}"
      shift 2
      ;;
    --api-secret)
      API_SECRET="${2:-}"
      shift 2
      ;;
    *)
      log "WARN: ignoring unknown arg: $1"
      shift
      ;;
  esac
done

log "START create_sudo=${CREATE_SUDO}"

if [[ -z "${API_SECRET}" ]]; then
  fail "Missing --api-secret"
fi

if [[ "${CREATE_SUDO}" == "1" ]]; then
  if [[ -z "${SUDO_USER}" ]]; then
    fail "Missing --sudo-user (required when --create-sudo-user 1)"
  fi

  if [[ -z "${SUDO_PASS}" ]]; then
    fail "Missing --sudo-pass (required when --create-sudo-user 1)"
  fi
fi

# ------------------------------------------------------------------------------
# Docker image pulls (use sudo if needed)
# ------------------------------------------------------------------------------
log "Docker pulls starting"

if command -v docker >/dev/null 2>&1; then
  if docker ps >/dev/null 2>&1; then
    DOCKER="docker"
  else
    DOCKER="sudo docker"
  fi
else
  fail "docker not found on PATH"
fi

$DOCKER pull wordpress:latest
$DOCKER pull wordpress:cli
$DOCKER pull mariadb:latest

log "Docker pulls done"

# ------------------------------------------------------------------------------
# Write / update env file (ensure owned by networkr)
# ------------------------------------------------------------------------------
ENV_FILE="/home/networkr/networkr-companion/.env"

log "Ensuring env file exists: ${ENV_FILE}"

# Ensure directory exists
mkdir -p "/home/networkr/networkr-companion"

# Create file if missing
if [[ ! -f "${ENV_FILE}" ]]; then
  touch "${ENV_FILE}"
fi

# Ensure ownership (if script was ever run with sudo in past)
# This is safe even if it already is correct.
if command -v sudo >/dev/null 2>&1; then
  sudo chown networkr:networkr "${ENV_FILE}" 2>/dev/null || true
fi

# Ensure writable
if [[ ! -w "${ENV_FILE}" ]]; then
  # attempt to fix perms (if needed)
  if command -v sudo >/dev/null 2>&1; then
    sudo chmod 600 "${ENV_FILE}" 2>/dev/null || true
    sudo chown networkr:networkr "${ENV_FILE}" 2>/dev/null || true
  fi
fi

if [[ ! -w "${ENV_FILE}" ]]; then
  fail "Env file not writable: ${ENV_FILE}"
fi

log "Updating PRESSILLION_API_SECRET in ${ENV_FILE}"

# Replace if exists, else append (no duplicates)
if grep -qE '^PRESSILLION_API_SECRET=' "${ENV_FILE}"; then
  # Use sed in-place compatible with GNU sed (Linux)
  sed -i "s|^PRESSILLION_API_SECRET=.*|PRESSILLION_API_SECRET=${API_SECRET}|" "${ENV_FILE}"
else
  echo "PRESSILLION_API_SECRET=${API_SECRET}" >> "${ENV_FILE}"
fi

# Confirm write happened (don’t print secret)
if grep -qE '^PRESSILLION_API_SECRET=' "${ENV_FILE}"; then
  log "Env updated OK"
else
  fail "Env update failed (key not found after write)"
fi

# ------------------------------------------------------------------------------
# Optional: create sudo user (private servers)
# ------------------------------------------------------------------------------
if [[ "${CREATE_SUDO}" == "1" ]]; then
  log "Creating sudo user: ${SUDO_USER}"

  if [[ ! -f "/home/networkr/networkr-companion/scripts/create_sudo_user.sh" ]]; then
    fail "Missing script: /home/networkr/networkr-companion/scripts/create_sudo_user.sh"
  fi

  sudo bash /home/networkr/networkr-companion/scripts/create_sudo_user.sh \
    --user "${SUDO_USER}" \
    --password "${SUDO_PASS}"

  log "Sudo user created OK"
else
  log "Skipping sudo user creation"
fi

log "SUCCESS"
echo '{"status":"success"}'