#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# create_sudo_user.sh
#
# Creates a *restricted* "customer admin" user:
#   - Has a password (from --password)
#   - SSH directory exists but no keys (Pressilion app will add keys later)
#   - CAN use sudo for a small safe set of commands:
#       - apt, apt-get, apt-cache
#       - systemctl status *
#       - systemctl restart ssh/cron
#   - CANNOT:
#       - get a root shell
#       - use docker
#       - edit sudoers
#       - sudo any other command
#
# Example:
#   sudo bash /home/networkr/networkr-companion/scripts/create_sudo_user.sh \
#       --user pressillion \
#       --password "MySecureTempPass123!"
###############################################################################

SUPER_USER="networkr"
SUPER_HOME="/home/${SUPER_USER}"
SUDOERS_DIR="/etc/sudoers.d"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --user USERNAME --password PLAIN_PASSWORD

Args:
  --user         Required. Username to create.
  --password     Required. Password for the new account.

Notes:
  - SSH directory is created empty (Pressilion app will install keys)
  - User gets a very limited sudo rule
  - User is *not* added to docker or pressadmin groups
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

log "Creating restricted customer admin '${CUSTOM_USER}'…"

if ! id -u "${CUSTOM_USER}" >/dev/null 2>&1; then
  useradd -m -d "${CUSTOM_HOME}" -s /bin/bash "${CUSTOM_USER}"
else
  log "User ${CUSTOM_USER} already exists. Ensuring home directory exists."
  mkdir -p "${CUSTOM_HOME}"
fi

# Set password
log "Setting password…"
echo "${CUSTOM_USER}:${CUSTOM_PASS}" | chpasswd

# Lock down home perms (owner only + group, no world access)
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
# Ensure /home/networkr and sensitive areas stay locked
###############################################################################

if [[ -d "${SUPER_HOME}" ]]; then
  # Only root + pressadmin can access; no 'others'
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
# Restricted sudo rules (no aliases, no syntax tricks)
###############################################################################

log "Writing restricted sudo rules…"

SUDO_FILE="${SUDOERS_DIR}/90-${CUSTOM_USER}-customeradmin"

cat > "${SUDO_FILE}" <<EOF
########################################################################
# Restricted sudo rules for customer admin: ${CUSTOM_USER}
#
# This user can ONLY run a small set of commands via sudo:
#   - apt, apt-get, apt-cache
#   - systemctl status *
#   - systemctl restart ssh/cron
#
# They CANNOT:
#   - sudo any other commands
#   - gain a root shell
#   - use docker
#   - edit sudoers
########################################################################

Defaults:${CUSTOM_USER} logfile="/var/log/sudo-${CUSTOM_USER}.log"
Defaults:${CUSTOM_USER} log_input, log_output

# Whitelist: ONLY these commands allowed with sudo for ${CUSTOM_USER}
${CUSTOM_USER} ALL=(ALL) NOPASSWD: \
    /usr/bin/apt, \
    /usr/bin/apt-get, \
    /usr/bin/apt-cache, \
    /usr/bin/systemctl status *, \
    /usr/bin/systemctl restart ssh, \
    /usr/bin/systemctl restart cron
EOF

chmod 440 "${SUDO_FILE}"

# IMPORTANT: Do *not* add user to 'sudo' group, otherwise they'd get %sudo rules.
# We only want the rule above to apply.
# usermod -aG sudo "${CUSTOM_USER}"   # <-- INTENTIONALLY NOT DONE

# Validate sudoers syntax
if visudo -cf "${SUDO_FILE}"; then
  log "Sudo rules validated successfully."
else
  log "ERROR: visudo validation failed for ${SUDO_FILE}. Removing file."
  rm -f "${SUDO_FILE}"
  exit 1
fi

###############################################################################
# Summary
###############################################################################

echo
echo "====================================================="
echo " Restricted Customer Admin Created"
echo "====================================================="
echo "User:      ${CUSTOM_USER}"
echo "Home:      ${CUSTOM_HOME}"
echo "Password:  (hidden — provided via script)"
echo
echo "SSH Keys:  NOT installed — Pressilion app will add keys."
echo
echo "Allowed via sudo:"
echo "  - apt, apt-get, apt-cache"
echo "  - systemctl status *"
echo "  - systemctl restart ssh"
echo "  - systemctl restart cron"
echo
echo "Everything else via sudo => NOT allowed."
echo "Networkr home, root, and DO config protected by filesystem perms."
echo "====================================================="