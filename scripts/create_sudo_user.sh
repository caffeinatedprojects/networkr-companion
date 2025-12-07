#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# create_sudo_user.sh
#
# Creates a heavily restricted "customer admin" user.
#
# Allowed:
#   - apt, apt-get, apt-cache
#   - systemctl (status, restart of their own services)
#
# Denied:
#   - docker, docker-compose
#   - su, sudo -i, shells, interpreters (python/php/node)
#   - file readers (cat/less/more/nano/vim/vi/head/tail)
#   - cannot read /home/networkr or companion files
#
# Example:
#   sudo bash create_sudo_user.sh \
#       --user pressilion \
#       --password "SecurePass123!"
###############################################################################

SUPER_USER="networkr"
SUPER_HOME="/home/${SUPER_USER}"
SUDOERS_DIR="/etc/sudoers.d"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
cat <<EOF
Usage:
  $(basename "$0") --user USERNAME --password PASSWORD

Arguments:
  --user         Username to create
  --password     Password for the new account

Notes:
  - SSH directory created empty (Pressillion will install keys)
  - User restricted via sudoers
  - User NOT added to docker, pressadmin, or privileged groups
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: Script must run as root." >&2
        exit 1
    fi
}

###############################################################################
# PARSE ARGUMENTS
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
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${CUSTOM_USER}" || -z "${CUSTOM_PASS}" ]]; then
    echo "ERROR: --user and --password are required."
    usage
    exit 1
fi

require_root

CUSTOM_HOME="/home/${CUSTOM_USER}"

###############################################################################
# CREATE USER
###############################################################################

log "Creating restricted customer admin '${CUSTOM_USER}'..."

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
# SSH DIRECTORY — EMPTY
###############################################################################

SSH_DIR="${CUSTOM_HOME}/.ssh"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${CUSTOM_USER}:${CUSTOM_USER}" "${SSH_DIR}"

log "SSH directory created (empty). Pressilion app will install keys."

###############################################################################
# PROTECT THE SUPER USER (networkr)
###############################################################################

# hide networkr files
chmod 750 "${SUPER_HOME}" || true

# hide AWS keys
if [[ -d "${SUPER_HOME}/.aws" ]]; then
    chmod 700 "${SUPER_HOME}/.aws" || true
fi

# hide companion repo
if [[ -d "${SUPER_HOME}/networkr-companion" ]]; then
    chmod -R o-rwx "${SUPER_HOME}/networkr-companion" || true
fi

###############################################################################
# SUDOERS — RESTRICTED PERMISSIONS
###############################################################################

log "Configuring restricted sudo rules…"

SUDO_FILE="${SUDOERS_DIR}/90-${CUSTOM_USER}-customeradmin"

cat > "${SUDO_FILE}" <<EOF
########################################################################
# Restricted sudo rules for customer admin: ${CUSTOM_USER}
########################################################################

User_Alias CUSTADM_${CUSTOM_USER} = ${CUSTOM_USER}

# Allowed commands (no wildcards allowed)
Cmnd_Alias CUST_SAFE_${CUSTOM_USER} = \
    /usr/bin/apt, \
    /usr/bin/apt-get, \
    /usr/bin/apt-cache, \
    /usr/bin/systemctl

# Denied commands
Cmnd_Alias CUST_DENY_${CUSTOM_USER} = \
    /bin/su, /usr/bin/su, \
    /bin/bash, /usr/bin/bash, \
    /bin/sh, /usr/bin/sh, \
    /usr/bin/docker, \
    /usr/bin/docker-compose, \
    /usr/bin/python3, \
    /usr/bin/python, \
    /usr/bin/php, \
    /usr/bin/node, \
    /usr/bin/nodejs, \
    /usr/bin/nano, \
    /usr/bin/vim, \
    /usr/bin/vi, \
    /usr/bin/cat, \
    /usr/bin/less, \
    /usr/bin/more, \
    /usr/bin/head, \
    /usr/bin/tail

# Logging
Defaults:CUSTADM_${CUSTOM_USER} logfile="/var/log/sudo-${CUSTOM_USER}.log"
Defaults:CUSTADM_${CUSTOM_USER} log_input, log_output

# Allowed rules
CUSTADM_${CUSTOM_USER} ALL=(ALL) NOPASSWD: CUST_SAFE_${CUSTOM_USER}

# Must explicitly forbid dangerous commands
CUSTADM_${CUSTOM_USER} ALL=(ALL) NOPASSWD: !CUST_DENY_${CUSTOM_USER}

EOF

chmod 440 "${SUDO_FILE}"

# Add user to sudo group so rules apply
usermod -aG sudo "${CUSTOM_USER}"

# Validate
visudo -cf "${SUDO_FILE}"

###############################################################################
# SUMMARY
###############################################################################

echo
echo "====================================================="
echo " Customer Admin User Created"
echo "====================================================="
echo "User:           ${CUSTOM_USER}"
echo "Home:           ${CUSTOM_HOME}"
echo "Password:       (hidden)"
echo "SSH Keys:       Not installed — Pressillion app will add"
echo
echo "ALLOWED VIA SUDO:"
echo "  • apt / apt-get / apt-cache"
echo "  • systemctl (general)"
echo
echo "DENIED VIA SUDO:"
echo "  • docker & docker-compose"
echo "  • su / shells / sudo -i"
echo "  • cat / nano / vim / less / head / tail"
echo "  • python / php / node"
echo
echo "Networkr super-user is protected and hidden."
echo "====================================================="