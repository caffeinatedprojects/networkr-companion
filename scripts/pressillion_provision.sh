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
SERVER_UID=""
BASE_HOST=""

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
    --server-uid)
      SERVER_UID="${2:-}"
      shift 2
      ;;
    --base-host)
      BASE_HOST="${2:-}"
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

if [[ -z "${SERVER_UID}" ]]; then
  fail "Missing --server-uid"
fi

if [[ -z "${BASE_HOST}" ]]; then
  fail "Missing --base-host"
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

mkdir -p "/home/networkr/networkr-companion"

if [[ ! -f "${ENV_FILE}" ]]; then
  touch "${ENV_FILE}"
fi

if command -v sudo >/dev/null 2>&1; then
  sudo chown networkr:networkr "${ENV_FILE}" 2>/dev/null || true
fi

if [[ ! -w "${ENV_FILE}" ]]; then
  if command -v sudo >/dev/null 2>&1; then
    sudo chmod 600 "${ENV_FILE}" 2>/dev/null || true
    sudo chown networkr:networkr "${ENV_FILE}" 2>/dev/null || true
  fi
fi

if [[ ! -w "${ENV_FILE}" ]]; then
  fail "Env file not writable: ${ENV_FILE}"
fi

set_kv() {
  local k="$1"
  local v="$2"

  if grep -qE "^${k}=" "${ENV_FILE}"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "${ENV_FILE}"
  else
    echo "${k}=${v}" >> "${ENV_FILE}"
  fi
}

log "Updating Pressillion runtime keys in ${ENV_FILE}"

set_kv "PRESSILLION_API_SECRET" "${API_SECRET}"
set_kv "PRESSILLION_SERVER_UID" "${SERVER_UID}"
set_kv "PRESSILLION_BASE_HOST" "${BASE_HOST}"

if grep -qE '^PRESSILLION_API_SECRET=' "${ENV_FILE}" && grep -qE '^PRESSILLION_SERVER_UID=' "${ENV_FILE}" && grep -qE '^PRESSILLION_BASE_HOST=' "${ENV_FILE}"; then
  log "Env updated OK"
else
  fail "Env update failed (one or more keys missing after write)"
fi

# ------------------------------------------------------------------------------
# Backups schedule (per-server daily, jittered). First run after 6 hours (PERSISTENT).
# ------------------------------------------------------------------------------
log "Setting up per-server daily backups timer"

BACKUP_ALL_SCRIPT="/home/networkr/networkr-companion/scripts/pressillion_backup_all.sh"

if [[ ! -f "${BACKUP_ALL_SCRIPT}" ]]; then
  fail "Missing backup script: ${BACKUP_ALL_SCRIPT}"
fi

sudo tee /etc/systemd/system/pressillion-backups.service >/dev/null <<'EOF'
[Unit]
Description=Pressillion backups (all eligible sites on this server)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
Group=root
EnvironmentFile=-/home/networkr/networkr-companion/.env

ExecStart=/bin/bash -lc '
  set -euo pipefail

  export BASE_HOST="${PRESSILLION_BASE_HOST:-app.pressillion.co.uk}"
  export SERVER_UID="${PRESSILLION_SERVER_UID:-}"
  export API_SECRET="${PRESSILLION_API_SECRET:-}"

  if [ -z "${SERVER_UID}" ] || [ -z "${API_SECRET}" ]; then
    echo "[pressillion-backups] Missing PRESSILLION_SERVER_UID or PRESSILLION_API_SECRET (skipping)."
    exit 0
  fi

  /home/networkr/networkr-companion/scripts/pressillion_backup_all.sh
'
EOF

sudo tee /etc/systemd/system/pressillion-backups.timer >/dev/null <<'EOF'
[Unit]
Description=Pressillion backups timer (daily, per-server jitter)

[Timer]
OnCalendar=daily
Persistent=true

# 2h jitter window per server, per day.
RandomizedDelaySec=7200

Unit=pressillion-backups.service

[Install]
WantedBy=timers.target
EOF

# ---- First run timer (persistent) ----
# Runs once, 6 hours after BOOT. If the server is off when it should have fired,
# it will run on next boot (because Persistent=true). It then disables itself.
sudo tee /etc/systemd/system/pressillion-backups-first-run.service >/dev/null <<'EOF'
[Unit]
Description=Pressillion backups first-run (one-shot kickoff)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
Group=root

ExecStart=/bin/bash -lc '
  set -euo pipefail

  echo "[pressillion-backups-first-run] starting pressillion-backups.service..."
  systemctl start pressillion-backups.service

  echo "[pressillion-backups-first-run] disabling first-run timer (one-shot complete)..."
  systemctl disable --now pressillion-backups-first-run.timer >/dev/null 2>&1 || true
'
EOF

sudo tee /etc/systemd/system/pressillion-backups-first-run.timer >/dev/null <<'EOF'
[Unit]
Description=Pressillion backups first-run timer (6h after boot, persistent)

[Timer]
OnBootSec=6h
Persistent=true

Unit=pressillion-backups-first-run.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload

sudo systemctl enable --now pressillion-backups.timer
sudo systemctl enable --now pressillion-backups-first-run.timer

log "Backups timers installed OK"
log "  Daily:      pressillion-backups.timer (with jitter)"
log "  First-run:  pressillion-backups-first-run.timer (6h after boot, persistent, self-disabling)"

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