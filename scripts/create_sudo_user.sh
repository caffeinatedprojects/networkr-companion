#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# create_sudo_user.sh
#
# Creates a *heavily restricted* "customer admin" user:
#   - Has a password (from --password)
#   - SSH directory exists but no keys installed (Pressilion will manage keys)
#   - CAN run: apt, apt-get, apt-cache, limited systemctl commands
#   - CANNOT: read /home/networkr, use docker, get a root shell, read files as root
#
#      sudo bash /home/networkr/networkr-companion/scripts/create_sudo_user.sh \
#        --user pressilion \
#        --password "MySecureTempPass123!"
###############################################################################

SUPER_USER="networkr"
SUPER_HOME="/home/${SUPER_USER}"

SUDOERS_DIR="/etc/sudoers.d"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --user USERNAME --password PLAIN_PASSWORD

Args:
  --user         Required. Username to create.
  --password     Required. Password for the new account.

Notes:
  - SSH directory is created empty (Pressilion app will install keys later)
  - User is restricted with a custom sudoers profile
  - User is NOT added to docker or pressadmin groups
EOF
}

require_root() {
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
      CUSTOM_USER="$2"
      shift 2
      ;;
    --password)
      CUSTOM_PASS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
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

log "Creating restricted admin user '${CUSTOM_USER}'..."

if ! id -u "${CUSTOM_USER}" >/dev/null 2>&1; then
  useradd -m -d "${CUSTOM_HOME}" -s /bin/bash "${CUSTOM_USER}"
else
  log "User already exists. Ensuring home exists."
  mkdir -p "${CUSTOM_HOME}"
fi

# Set password
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

log "SSH directory created empty — Pressilion app will install keys later."

###############################################################################
# Ensure /home/networkr stays locked
###############################################################################

if [[ -d "${SUPER_HOME}" ]]; then
  chown "${SUPER_USER}:pressadmin" "${SUPER_HOME}" || true
  chmod 750 "${SUPER_HOME}" || true
fi

if [[ -d "${SUPER_HOME}/.aws" ]]; then
  chmod 700 "${SUPER_HOME}/.aws" || true
fi

if [[ -d "${SUPER_HOME}/networkr-companion" ]]; then
  chmod -R o-rwx "${SUPER_HOME}/networkr-companion" || true
fi

###############################################################################
# Sudo restrictions
###############################################################################

log "Creating restricted sudo profile..."

SUDO_FILE="${SUDOERS_DIR}/90-${CUSTOM_USER}-customeradmin"

cat > "${SUDO_FILE}" <<EOF
########################################################################
# Restricted sudo rules for customer admin: ${CUSTOM_USER}
########################################################################

User_Alias CUSTADM_${CUSTOM_USER} = ${CUSTOM_USER}

# SAFE commands allowed:
Cmnd_Alias CUST_SAFE_${CUSTOM_USER} = \\
    /usr/bin/apt, \\
    /usr/bin/apt-get, \\
    /usr/bin/apt-cache, \\
    /usr/bin/systemctl status *, \\
    /usr/bin/systemctl restart ssh, \\
    /usr/bin/systemctl restart cron

# DENIED command groups (explicit):
Cmnd_Alias CUST_DENY_SHELLS_${CUSTOM_USER} = \\
    /bin/su, /usr/bin/su, \\
    /bin/bash, /usr/bin/bash, \\
    /bin/sh, /usr/bin/sh

Cmnd_Alias CUST_DENY_INTERPRETERS_${CUSTOM_USER} = \\
    /usr/bin/python*, /usr/bin/perl*, /usr/bin/php*, /usr/bin/ruby*, /usr/bin/node*, /usr/bin/nodejs*

Cmnd_Alias CUST_DENY_READERS_${CUSTOM_USER} = \\
    /bin/cat, /usr/bin/cat, \\
    /usr/bin/less, /usr/bin/more, /usr/bin/head, /usr/bin/tail

Cmnd_Alias CUST_DENY_EDITORS_${CUSTOM_USER} = \\
    /usr/bin/nano, /usr/bin/vi, /usr/bin/vim

Cmnd_Alias CUST_DENY_DOCKER_${CUSTOM_USER} = \\
    /usr/bin/docker, /usr/bin/docker-compose

Defaults:CUSTADM_${CUSTOM_USER} logfile="/var/log/sudo-${CUSTOM_USER}.log"
Defaults:CUSTADM_${CUSTOM_USER} log_input, log_output

# Allowed
CUSTADM_${CUSTOM_USER} ALL=(ALL) NOPASSWD: CUST_SAFE_${CUSTOM_USER}

# Explicit denies
CUSTADM_${CUSTOM_USER} ALL=(ALL) NOPASSWD: \\
    !CUST_DENY_SHELLS_${CUSTOM_USER}, \\
    !CUST_DENY_INTERPRETERS_${CUSTOM_USER}, \\
    !CUST_DENY_READERS_${CUSTOM_USER}, \\
    !CUST_DENY_EDITORS_${CUSTOM_USER}, \\
    !CUST_DENY_DOCKER_${CUSTOM_USER}
EOF

chmod 440 "${SUDO_FILE}"

# Add to sudo group (required for restricted rules to apply)
usermod -aG sudo "${CUSTOM_USER}"

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
echo "Allowed sudo:"
echo "  - apt, apt-get, apt-cache"
echo "  - systemctl status *"
echo "  - restart ssh/cron only"
echo
echo "Denied:"
echo "  - root shells, su, sudo -i"
echo "  - docker / docker-compose"
echo "  - editors & file readers as root"
echo "  - interpreters as root"
echo "====================================================="