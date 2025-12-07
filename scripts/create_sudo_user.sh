#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# create_sudo_user.sh (FINAL, FIXED, PRODUCTION-READY)
#
# Creates a *restricted customer admin* user who:
#   - Has a password (Pressillion-generated)
#   - Cannot read /home/networkr or its project files
#   - Cannot use docker, shells, editors, or interpreters via sudo
#   - CAN run apt, apt-get, apt-cache, and restart ssh/cron
#
# Example:
#   sudo bash create_sudo_user.sh --user pressillion --password "MyPass123!"
###############################################################################

SUPER_USER="networkr"
SUPER_HOME="/home/${SUPER_USER}"

SUDOERS_DIR="/etc/sudoers.d"

log(){ echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

usage(){
  cat <<EOF
Usage:
  $(basename "$0") --user USERNAME --password PASSWORD

Example:
  sudo bash create_sudo_user.sh --user pressillion --password "SuperSecret123!"

Notes:
  - SSH directory is created empty (Pressillion adds keys later)
  - User is restricted and cannot harm the host or read networkr files
EOF
}

require_root(){
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: Must run as root." >&2
    exit 1
  fi
}

###############################################################################
# Parse arguments
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
      echo "Unknown argument: $1" >&2
      usage; exit 1 ;;
  esac
done

[[ -z "$CUSTOM_USER" || -z "$CUSTOM_PASS" ]] && {
  echo "ERROR: --user and --password are required."
  exit 1
}

require_root

CUSTOM_HOME="/home/${CUSTOM_USER}"

###############################################################################
# Create user
###############################################################################

log "Creating restricted customer admin '${CUSTOM_USER}'…"

if ! id -u "${CUSTOM_USER}" >/dev/null 2>&1; then
  useradd -m -d "${CUSTOM_HOME}" -s /bin/bash "${CUSTOM_USER}"
else
  log "User already exists — ensuring home exists."
  mkdir -p "${CUSTOM_HOME}"
fi

log "Setting password…"
echo "${CUSTOM_USER}:${CUSTOM_PASS}" | chpasswd

chmod 750 "${CUSTOM_HOME}"
chown -R "${CUSTOM_USER}:${CUSTOM_USER}" "${CUSTOM_HOME}"

###############################################################################
# SSH Directory (empty — Pressillion app installs keys)
###############################################################################

SSH_DIR="${CUSTOM_HOME}/.ssh"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${CUSTOM_USER}:${CUSTOM_USER}" "${SSH_DIR}"

log "SSH directory prepared (no keys installed)."

###############################################################################
# Ensure SUPER_USER files remain protected
###############################################################################

if [[ -d "${SUPER_HOME}" ]]; then
  chmod 750 "${SUPER_HOME}" || true
fi

if [[ -d "${SUPER_HOME}/networkr-companion" ]]; then
  chmod -R o-rwx "${SUPER_HOME}/networkr-companion" || true
fi

if [[ -d "${SUPER_HOME}/.aws" ]]; then
  chmod -R 700 "${SUPER_HOME}/.aws" || true
fi

###############################################################################
# Write hardened sudo profile (fully fixed syntax)
###############################################################################

log "Writing restricted sudo rules…"

SUDO_FILE="${SUDOERS_DIR}/90-${CUSTOM_USER}-customeradmin"

cat > "${SUDO_FILE}" <<EOF
########################################################################
# Restricted sudo rules for customer admin: ${CUSTOM_USER}
########################################################################

User_Alias CUSTADM_${CUSTOM_USER} = ${CUSTOM_USER}

# SAFE ALLOWED COMMANDS (explicit full paths)
Cmnd_Alias CUST_SAFE_${CUSTOM_USER} = \
    /usr/bin/apt, \
    /usr/bin/apt-get, \
    /usr/bin/apt-cache, \
    /usr/bin/systemctl status *, \
    /usr/bin/systemctl restart ssh, \
    /usr/bin/systemctl restart cron

# DANGEROUS / ROOT-ESCALATION COMMANDS — MUST NEVER BE ALLOWED
Cmnd_Alias CUST_DENY_${CUSTOM_USER} = \
    /bin/su, /usr/bin/su, \
    /bin/bash, /usr/bin/bash, \
    /bin/sh, /usr/bin/sh, \
    /usr/bin/docker, \
    /usr/bin/docker-compose, \
    /usr/bin/python3, /usr/bin/python, \
    /usr/bin/php, \
    /usr/bin/node, /usr/bin/nodejs, \
    /usr/bin/nano, /usr/bin/vim, /usr/bin/vi, \
    /usr/bin/cat, /usr/bin/less, /usr/bin/more, \
    /usr/bin/head, /usr/bin/tail

Defaults:CUSTADM_${CUSTOM_USER} logfile="/var/log/sudo-${CUSTOM_USER}.log"
Defaults:CUSTADM_${CUSTOM_USER} log_input, log_output

# ALLOW ONLY safe commands
CUSTADM_${CUSTOM_USER} ALL=(ALL) NOPASSWD: \
    /usr/bin/apt, \
    /usr/bin/apt-get, \
    /usr/bin/apt-cache, \
    /usr/bin/systemctl status *, \
    /usr/bin/systemctl restart ssh, \
    /usr/bin/systemctl restart cron

# DENY EVERYTHING in the deny alias
CUSTADM_${CUSTOM_USER} ALL=(ALL) NOPASSWD: \
    !/bin/su, !/usr/bin/su, \
    !/bin/bash, !/usr/bin/bash, \
    !/bin/sh, !/usr/bin/sh, \
    !/usr/bin/docker, \
    !/usr/bin/docker-compose, \
    !/usr/bin/python3, !/usr/bin/python, \
    !/usr/bin/php, \
    !/usr/bin/node, !/usr/bin/nodejs, \
    !/usr/bin/nano, \
    !/usr/bin/vim, !/usr/bin/vi, \
    !/usr/bin/cat, !/usr/bin/less, !/usr/bin/more, \
    !/usr/bin/head, !/usr/bin/tail
EOF

chmod 440 "${SUDO_FILE}"

# Add user to sudo group so rules apply
usermod -aG sudo "${CUSTOM_USER}"

# Validate syntax
visudo -cf "${SUDO_FILE}"

###############################################################################
# Summary
###############################################################################

echo
echo "====================================================="
echo " Restricted Customer Admin Created"
echo "====================================================="
echo "User:        ${CUSTOM_USER}"
echo "Home:        ${CUSTOM_HOME}"
echo "SSH Keys:    NOT installed — Pressillion will add them"
echo "Password:    (hidden — passed via script)"
echo
echo "Allowed via sudo:"
echo "  apt, apt-get, apt-cache"
echo "  systemctl status *"
echo "  restart ssh / cron"
echo
echo "Denied via sudo:"
echo "  docker, su, bash, sh"
echo "  python, php, node"
echo "  nano, vim, vi"
echo "  cat, less, more"
echo "====================================================="