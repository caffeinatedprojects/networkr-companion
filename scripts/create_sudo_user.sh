#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# create_sudo_user.sh
#
# JSON-only output for use by Pressilion / SSHTools.
#
# Success:
#   {"status":"success","message":"Restricted customer admin created","user":"USERNAME"}
#
# Error:
#   {"status":"error","message":"Some error message","user":"USERNAME"}
#
###############################################################################

SUPER_USER="networkr"
SUPER_HOME="/home/${SUPER_USER}"
SUDOERS_DIR="/etc/sudoers.d"

###############################################################################
# Logging (stderr only) and JSON helpers
###############################################################################

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

json_success() {
  local msg="$1"
  local user="${CUSTOM_USER:-""}"
  printf '{"status":"success","message":"%s","user":"%s"}\n' "$msg" "$user"
}

json_error() {
  local msg="$1"
  local user="${CUSTOM_USER:-""}"
  printf '{"status":"error","message":"%s","user":"%s"}\n' "$msg" "$user"
}

usage() {
  cat >&2 <<EOF
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
    json_error "must_be_run_as_root"
    exit 1
  fi
}

###############################################################################
# Global error trap -> always emit JSON on unexpected failure
###############################################################################

trap 'json_error "unexpected_error"; exit 1' ERR

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
      exit 1
      ;;
    *)
      json_error "unknown_argument_$1"
      exit 1
      ;;
  esac
done

if [[ -z "${CUSTOM_USER}" || -z "${CUSTOM_PASS}" ]]; then
  json_error "missing_required_arguments"
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

# Lock down home perms (owner + group only, no world access)
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
# Restricted sudo rules (no aliases, no sudo group)
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

# Do NOT add to sudo group (would inherit %sudo rules)
# usermod -aG sudo "${CUSTOM_USER}"  # <- intentionally omitted

# Validate sudoers syntax
if ! visudo -cf "${SUDO_FILE}" >/dev/null 2>&1; then
  rm -f "${SUDO_FILE}"
  json_error "sudoers_validation_failed"
  exit 1
fi

log "Sudo rules validated successfully."

###############################################################################
# Success JSON and clean exit
###############################################################################

# Disable ERR trap for the final success path to avoid double error JSON.
trap - ERR

json_success "Restricted customer admin created"
exit 0