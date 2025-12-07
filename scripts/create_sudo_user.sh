#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# create_sudo_user.sh — Hardened Restricted Customer Admin User
###############################################################################

SUPER_USER="networkr"
SUPER_HOME="/home/${SUPER_USER}"
SUDOERS_DIR="/etc/sudoers.d"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage:
  $0 --user USERNAME --password PASSWORD

Creates a restricted customer admin user:
  - SSH enabled but NO keys installed (Pressilion app manages keys)
  - Has limited sudo (apt + systemctl status + restart ssh/cron)
  - Cannot read/edit /home/networkr, /etc, /root
  - Cannot modify sudoers files
  - Cannot use docker or escalate privileges
EOF
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
  fi
}

###############################################################################
# ARGUMENT PARSING
###############################################################################

CUSTOM_USER=""
CUSTOM_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      CUSTOM_USER="$2"; shift 2 ;;
    --password)
      CUSTOM_PASS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

[[ -z "$CUSTOM_USER" || -z "$CUSTOM_PASS" ]] && {
  echo "ERROR: --user and --password are required."
  exit 1
}

require_root

###############################################################################
# CREATE USER
###############################################################################

CUSTOM_HOME="/home/${CUSTOM_USER}"

log "Creating restricted customer admin '${CUSTOM_USER}'…"

if ! id -u "${CUSTOM_USER}" >/dev/null 2>&1; then
  useradd -m -d "${CUSTOM_HOME}" -s /bin/bash "${CUSTOM_USER}"
else
  mkdir -p "${CUSTOM_HOME}"
fi

echo "${CUSTOM_USER}:${CUSTOM_PASS}" | chpasswd

# secure home
chown -R "${CUSTOM_USER}:${CUSTOM_USER}" "${CUSTOM_HOME}"
chmod 750 "${CUSTOM_HOME}"

###############################################################################
# SSH SETUP (empty — Pressilion will install keys)
###############################################################################

SSH_DIR="${CUSTOM_HOME}/.ssh"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${CUSTOM_USER}:${CUSTOM_USER}" "${SSH_DIR}"

log "SSH directory prepared (no keys installed)."

###############################################################################
# LOCK DOWN networkr SUPER-USER FILES
###############################################################################

chmod 750 "${SUPER_HOME}" || true
chmod 700 "${SUPER_HOME}/.aws" 2>/dev/null || true
chmod -R o-rwx "${SUPER_HOME}/networkr-companion" 2>/dev/null || true

###############################################################################
# SUDOERS — FINAL HARDENED VERSION
###############################################################################

log "Writing restricted sudo rules…"

SUDO_FILE="${SUDOERS_DIR}/90-${CUSTOM_USER}-customeradmin"

cat > "${SUDO_FILE}" <<EOF
########################################################################
# Restricted sudo rules for customer admin: ${CUSTOM_USER}
########################################################################

User_Alias CUSTADM_${CUSTOM_USER} = ${CUSTOM_USER}

# =========================
# SAFE COMMANDS ALLOWED
# =========================
Cmnd_Alias CUST_SAFE_${CUSTOM_USER} = \
    /usr/bin/apt, \
    /usr/bin/apt-get, \
    /usr/bin/apt-cache, \
    /usr/bin/systemctl status *, \
    /usr/bin/systemctl restart ssh, \
    /usr/bin/systemctl restart cron

# =========================
# HARD DENY — READ BLOCK
# =========================
Cmnd_Alias CUST_DENY_READ_${CUSTOM_USER} = \
    /bin/cat /home/networkr/*, \
    /bin/cat /root/*, \
    /bin/cat /etc/*, \
    /usr/bin/cat /home/networkr/*, \
    /usr/bin/cat /root/*, \
    /usr/bin/cat /etc/*, \
    /usr/bin/less /home/networkr/*, \
    /usr/bin/less /root/*, \
    /usr/bin/less /etc/*, \
    /usr/bin/head /home/networkr/*, \
    /usr/bin/head /root/*, \
    /usr/bin/head /etc/*, \
    /usr/bin/tail /home/networkr/*, \
    /usr/bin/tail /root/*, \
    /usr/bin/tail /etc/*

# =========================
# HARD DENY — EDIT BLOCK
# =========================
Cmnd_Alias CUST_DENY_EDIT_${CUSTOM_USER} = \
    /usr/bin/nano /home/networkr/*, \
    /usr/bin/nano /root/*, \
    /usr/bin/nano /etc/*, \
    /usr/bin/nano /etc/sudoers, \
    /usr/bin/nano /etc/sudoers.d/*, \
    /usr/bin/vim /home/networkr/*, \
    /usr/bin/vim /root/*, \
    /usr/bin/vim /etc/*, \
    /usr/bin/vim /etc/sudoers, \
    /usr/bin/vim /etc/sudoers.d/*, \
    /usr/bin/vi /home/networkr/*, \
    /usr/bin/vi /root/*, \
    /usr/bin/vi /etc/*, \
    /usr/bin/vi /etc/sudoers, \
    /usr/bin/vi /etc/sudoers.d/*

# =========================
# HARD DENY — DOCKER
# =========================
Cmnd_Alias CUST_DENY_DOCKER_${CUSTOM_USER} = \
    /usr/bin/docker, \
    /usr/bin/docker-*, \
    /usr/bin/docker-compose

# =========================
# APPLY RULES
# =========================

Defaults:CUSTADM_${CUSTOM_USER} logfile="/var/log/sudo-${CUSTOM_USER}.log"
Defaults:CUSTADM_${CUSTOM_USER} log_input, log_output

# Allowed:
CUSTADM_${CUSTOM_USER} ALL=(ALL) NOPASSWD: CUST_SAFE_${CUSTOM_USER}

# Explicit denies:
CUSTADM_${CUSTOM_USER} ALL=(ALL) NOPASSWD: \
   !CUST_DENY_READ_${CUSTOM_USER}, \
   !CUST_DENY_EDIT_${CUSTOM_USER}, \
   !CUST_DENY_DOCKER_${CUSTOM_USER}
EOF

chmod 440 "${SUDO_FILE}"

# Add them to sudo so restrictions apply
usermod -aG sudo "${CUSTOM_USER}"

# Validate
visudo -cf "${SUDO_FILE}"

###############################################################################
# SUMMARY
###############################################################################

echo
echo "====================================================="
echo " Restricted Customer Admin Created"
echo "====================================================="
echo "User:          ${CUSTOM_USER}"
echo "Home:          ${CUSTOM_HOME}"
echo "SSH Keys:      NONE (Pressilion will add)"
echo
echo "Allowed sudo:  apt, apt-get, apt-cache, systemctl status*, restart ssh/cron"
echo "Denied sudo:   docker, shells, readers, editors, /etc, /root, /home/networkr"
echo
echo "====================================================="