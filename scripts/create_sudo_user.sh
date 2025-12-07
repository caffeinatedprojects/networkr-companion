#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# create_sudo_user.sh (FINAL CLEAN VERSION)
#
# Creates a *restricted customer admin* user:
#   - Has a password (from --password)
#   - SSH directory exists but no keys installed (Pressilion will add keys)
#   - CAN run: apt, apt-get, apt-cache, systemctl status, restart ssh/cron
#   - CANNOT: use docker, get a root shell, run interpreters or editors as root,
#             or trivially read files as root (cat/less/more/head/tail)
#
# Example:
#   sudo bash /home/networkr/networkr-companion/scripts/create_sudo_user.sh \
#     --user pressillion \
#     --password "MySecureTempPass123!"
###############################################################################

SUPER_USER="networkr"
SUPER_HOME="/home/${SUPER_USER}"

SUDOERS_DIR="/etc/sudoers.d"

log(){ echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

usage(){
  cat <<EOF
Usage:
  $(basename "$0") --user USERNAME --password PASSWORD

Args:
  --user       Required. Username to create.
  --password   Required. Password for the new account.

Notes:
  - SSH directory is created empty (Pressilion app will install keys later)
  - User is restricted with a per-user sudoers profile
  - User is NOT added to docker or pressadmin groups
EOF
}

require_root(){
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root." >&2
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

if [[ -z "${CUSTOM_USER}" || -z "${CUSTOM_PASS}" ]]; then
  echo "ERROR: --user and --password are required." >&2
  usage
  exit 1
fi

require_root

CUSTOM_HOME="/home/${CUSTOM_USER}"

###############################################################################
# Create the user
###############################################################################

log "Creating restricted customer admin '${CUSTOM_USER}'…"

if ! id -u "${CUSTOM_USER}" >/dev/null 2>&1; then
  useradd -m -d "${CUSTOM_HOME}" -s /bin/bash "${CUSTOM_USER}"
else
  log "User already exists. Ensuring home exists."
  mkdir -p "${CUSTOM_HOME}"
fi

log "Setting password…"
echo "${CUSTOM_USER}:${CUSTOM_PASS}" | chpasswd

# Lock down home perms
chown -R "${CUSTOM_USER}:${CUSTOM_USER}" "${CUSTOM_HOME}"
chmod 750 "${CUSTOM_HOME}"

###############################################################################
# SSH directory (empty — Pressilion app will install keys later)
###############################################################################

SSH_DIR="${CUSTOM_HOME}/.ssh"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${CUSTOM_USER}:${CUSTOM_USER}" "${SSH_DIR}"

log "SSH directory prepared (no keys installed)."

###############################################################################
# Ensure /home/networkr stays locked
###############################################################################

if [[ -d "${SUPER_HOME}" ]]; then
  chmod 750 "${SUPER_HOME}" || true
fi

if [[ -d "${SUPER_HOME}/.aws" ]]; then
  chmod -R 700 "${SUPER_HOME}/.aws" || true
fi

if [[ -d "${SUPER_HOME}/networkr-companion" ]]; then
  chmod -R o-rwx "${SUPER_HOME}/networkr-companion" || true
fi

###############################################################################
# Sudo restrictions (NO aliases — purely per-user rules)
###############################################################################

log "Configuring restricted sudo rules…"

SUDO_FILE="${SUDOERS_DIR}/90-${CUSTOM_USER}-customeradmin"

cat > "${SUDO_FILE}" <<EOF
########################################################################
# Restricted sudo rules for customer admin: ${CUSTOM_USER}
########################################################################

# Log all sudo use for this user
Defaults:${CUSTOM_USER} logfile="/var/log/sudo-${CUSTOM_USER}.log"
Defaults:${CUSTOM_USER} log_input, log_output

# Allow ONLY these commands without password:
#   - apt / apt-get / apt-cache
#   - systemctl status *
#   - systemctl restart ssh
#   - systemctl restart cron
# Explicitly deny dangerous ones via "!".
${CUSTOM_USER} ALL=(ALL) NOPASSWD: \
    /usr/bin/apt, \
    /usr/bin/apt-get, \
    /usr/bin/apt-cache, \
    /usr/bin/systemctl status *, \
    /usr/bin/systemctl restart ssh, \
    /usr/bin/systemctl restart cron, \
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

# Validate just this file's syntax
visudo -cf "${SUDO_FILE}"

###############################################################################
# Summary
###############################################################################

echo
echo "====================================================="
echo " Restricted Customer Admin Created"
echo "====================================================="
echo "User:      ${CUSTOM_USER}"
echo "Home:      ${CUSTOM_HOME}"
echo "Password:  (hidden — passed via script)"
echo
echo "SSH Keys:  NOT installed — Pressilion app will add keys"
echo
echo "Allowed via sudo:"
echo "  - apt, apt-get, apt-cache"
echo "  - systemctl status *"
echo "  - systemctl restart ssh"
echo "  - systemctl restart cron"
echo
echo "Denied via sudo:"
echo "  - docker / docker-compose"
echo "  - su, bash, sh"
echo "  - python, php, node/nodejs"
echo "  - cat, less, more, head, tail"
echo "  - nano, vim, vi"
echo "====================================================="