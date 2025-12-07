#!/usr/bin/env bash
set -euo pipefail

PRESSILION_USER="networkr"
NETWORKR_ROOT="/home/${PRESSILION_USER}/networkr-companion"
TEMPLATE_ROOT="${NETWORKR_ROOT}/template"
GROUP_ADMIN="pressadmin"
DELETE_SCRIPT="${NETWORKR_ROOT}/scripts/pressilion-delete-site.sh"

log() {
  # use epoch + human-readable
  echo "[$(date +'%s.%6N')] $*" | awk '{print strftime("[%Y-%m-%d %H:%M:%S]", $1) " " substr($0, index($0,$2))}'
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

usage() {
  cat <<EOF
Usage:
  pressilion-create-site --user USERNAME --website-id ID --domain DOMAIN \\
                         --letsencrypt-email EMAIL [--wp-admin-email EMAIL]

Creates a WordPress site using the Apache-based WordPress image.
EOF
}

# Simple XKCD-style password generator: word-word-word-word-N
xkcd_password() {
  local words=(Substance Inside Pound Provide Rocket Forest Marble Signal Anchor Velvet)
  local w1 w2 w3 w4 num
  w1="${words[$RANDOM % ${#words[@]}]}"
  w2="${words[$RANDOM % ${#words[@]}]}"
  w3="${words[$RANDOM % ${#words[@]}]}"
  w4="${words[$RANDOM % ${#words[@]}]}"
  num=$((RANDOM % 10))
  echo "${w1}-${w2}-${w3}-${w4}-${num}"
}

rollback_and_exit() {
  local site_user="$1"
  local domain="$2"
  local reason="$3"

  log "❌ Failure: ${reason}"
  if [[ -x "${DELETE_SCRIPT}" ]]; then
    log "Rolling back by calling delete script for user '${site_user}'..."
    "${DELETE_SCRIPT}" --user "${site_user}" --domain "${domain}" || true
  else
    log "⚠️ Delete script not found at ${DELETE_SCRIPT}, rollback skipped."
  fi
  exit 1
}

detect_server_ip() {
  # Prefer non-loopback IPv4
  hostname -I 2>/dev/null | awk '{for (i=1;i<=NF;i++){if ($i ~ /^[0-9]+\./){print $i; exit}}}' || echo "UNKNOWN"
}

wait_for_mysql() {
  local container="$1"
  local db_name="$2"
  local db_user="$3"
  local db_pass="$4"
  local max_attempts=90
  local attempt=1

  log "Waiting for MySQL/MariaDB to become ready (max ${max_attempts} attempts)..."

  while (( attempt <= max_attempts )); do
    if docker exec "${container}" mysql -u"${db_user}" -p"${db_pass}" -e "SELECT 1" "${db_name}" >/dev/null 2>&1; then
      log "MySQL/MariaDB is ready after ${attempt} attempts."
      return 0
    fi
    log "MySQL ping failed… (${attempt}/${max_attempts})"
    sleep 2
    (( attempt++ ))
  done

  return 1
}

auto_install_wordpress() {
  local cli_container="$1"
  local url="$2"
  local title="$3"
  local admin_user="$4"
  local admin_pass="$5"
  local admin_email="$6"
  local locale="$7"

  log "Running WordPress auto-install via WP-CLI..."

  # If already installed, skip
  if docker exec "${cli_container}" wp core is-installed --allow-root --path=/var/www/html >/dev/null 2>&1; then
    log "WordPress already installed — skipping auto-install."
    return 0
  fi

  if ! docker exec "${cli_container}" wp core install \
      --url="${url}" \
      --title="${title}" \
      --admin_user="${admin_user}" \
      --admin_password="${admin_pass}" \
      --admin_email="${admin_email}" \
      --skip-email \
      --locale="${locale}" \
      --allow-root \
      --path=/var/www/html >/dev/null 2>&1; then
    return 1
  fi

  log "WordPress core installed successfully."
  return 0
}

################################################################################
# ARGUMENT PARSING
################################################################################

SITE_USER=""
WEBSITE_ID=""
PRIMARY_DOMAIN=""
LETSENCRYPT_EMAIL=""
WP_ADMIN_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) SITE_USER="$2"; shift 2 ;;
    --website-id) WEBSITE_ID="$2"; shift 2 ;;
    --domain) PRIMARY_DOMAIN="$2"; shift 2 ;;
    --letsencrypt-email) LETSENCRYPT_EMAIL="$2"; shift 2 ;;
    --wp-admin-email) WP_ADMIN_EMAIL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$SITE_USER" || -z "$WEBSITE_ID" || -z "$PRIMARY_DOMAIN" || -z "$LETSENCRYPT_EMAIL" ]] && {
  echo "Missing required arguments."
  usage
  exit 1
}

[[ -z "$WP_ADMIN_EMAIL" ]] && WP_ADMIN_EMAIL="$LETSENCRYPT_EMAIL"

################################################################################
# MAIN
################################################################################

require_root

SITE_HOME="/home/${SITE_USER}"
SITE_ROOT="${SITE_HOME}"
DATA_DIR="${SITE_ROOT}/data"

log "Creating Linux user '${SITE_USER}'..."
if ! id -u "${SITE_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${SITE_USER}"
  passwd -l "${SITE_USER}" || true
else
  usermod -s /bin/bash "${SITE_USER}" || true
fi

# Group setup
if ! getent group "${GROUP_ADMIN}" >/dev/null; then
  groupadd "${GROUP_ADMIN}"
fi

usermod -g "${SITE_USER}" "${SITE_USER}"
chown "${SITE_USER}:${GROUP_ADMIN}" "${SITE_HOME}"
chmod 750 "${SITE_HOME}"

log "Creating data directories in ${DATA_DIR}..."
mkdir -p "${DATA_DIR}/backup" "${DATA_DIR}/temp" "${DATA_DIR}/db" "${DATA_DIR}/site"
chown -R "${SITE_USER}:${GROUP_ADMIN}" "${DATA_DIR}"
chmod -R 770 "${DATA_DIR}"

log "Syncing template data structure..."
rsync -a "${TEMPLATE_ROOT}/data/" "${DATA_DIR}/"
chown -R "${SITE_USER}:${GROUP_ADMIN}" "${DATA_DIR}"

log "Setting up conf.d/php.ini..."
mkdir -p "${SITE_ROOT}/conf.d"
cp -f "${TEMPLATE_ROOT}/conf.d/php.ini" "${SITE_ROOT}/conf.d/php.ini"
chown -R "${SITE_USER}:${GROUP_ADMIN}" "${SITE_ROOT}/conf.d"
chmod -R 770 "${SITE_ROOT}/conf.d"

################################################################################
# Generate .env
################################################################################

ENV_TEMPLATE="${TEMPLATE_ROOT}/.env.template"
ENV_TARGET="${SITE_ROOT}/.env"

log "Generating .env..."

COMPOSE_PROJECT_NAME="${SITE_USER}"
DOMAINS="${PRIMARY_DOMAIN}"
CONTAINER_DB_NAME="${COMPOSE_PROJECT_NAME}-db"
CONTAINER_SITE_NAME="${COMPOSE_PROJECT_NAME}-wp"
CONTAINER_CLI_NAME="${COMPOSE_PROJECT_NAME}-cli"

# XKCD-style passwords
MYSQL_DATABASE="wp_${WEBSITE_ID}"
MYSQL_USER="wp_${WEBSITE_ID}_u"
MYSQL_PASSWORD="$(xkcd_password)"
MYSQL_ROOT_PASSWORD="$(xkcd_password)"

# Avoid octal interpretation of WEBSITE_ID with leading zeros
DB_LOCAL_PORT=$((33060 + 10#$WEBSITE_ID))

WP_TITLE="${PRIMARY_DOMAIN}"
WP_ADMIN_USER="admin"
WP_ADMIN_TEMP_PASS="$(xkcd_password)"
WP_ADMIN_MAIL="${WP_ADMIN_EMAIL}"
WP_PERMA_STRUCTURE='/%year%/%monthnum%/%postname%/'

export WEBSITE_ID COMPOSE_PROJECT_NAME PRIMARY_DOMAIN DOMAINS \
       LETSENCRYPT_EMAIL CONTAINER_DB_NAME CONTAINER_SITE_NAME \
       CONTAINER_CLI_NAME MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD \
       MYSQL_ROOT_PASSWORD DB_LOCAL_PORT WP_TITLE WP_ADMIN_USER \
       WP_ADMIN_TEMP_PASS WP_ADMIN_MAIL WP_PERMA_STRUCTURE

envsubst < "${ENV_TEMPLATE}" > "${ENV_TARGET}"

chown "${PRESSILION_USER}:${GROUP_ADMIN}" "${ENV_TARGET}"
chmod 640 "${ENV_TARGET}"

################################################################################
# docker-compose.yml
################################################################################

COMPOSE_TEMPLATE="${TEMPLATE_ROOT}/docker-compose.yml"
COMPOSE_TARGET="${SITE_ROOT}/docker-compose.yml"

log "Copying docker-compose.yml..."
cp -f "${COMPOSE_TEMPLATE}" "${COMPOSE_TARGET}"
chown "${PRESSILION_USER}:${GROUP_ADMIN}" "${COMPOSE_TARGET}"
chmod 640 "${COMPOSE_TARGET}"

################################################################################
# START STACK
################################################################################

log "Bringing up the Docker stack..."
cd "${SITE_ROOT}"

if ! docker compose up -d --build; then
  rollback_and_exit "${SITE_USER}" "${PRIMARY_DOMAIN}" "docker compose up failed."
fi

################################################################################
# WAIT FOR DB & AUTO-INSTALL WORDPRESS
################################################################################

if ! wait_for_mysql "${CONTAINER_DB_NAME}" "${MYSQL_DATABASE}" "${MYSQL_USER}" "${MYSQL_PASSWORD}"; then
  rollback_and_exit "${SITE_USER}" "${PRIMARY_DOMAIN}" "MySQL/MariaDB did not become ready in time."
fi

WP_URL="https://${PRIMARY_DOMAIN}"
if ! auto_install_wordpress "${CONTAINER_CLI_NAME}" "${WP_URL}" "${WP_TITLE}" \
    "${WP_ADMIN_USER}" "${WP_ADMIN_TEMP_PASS}" "${WP_ADMIN_MAIL}" "en_GB"; then
  rollback_and_exit "${SITE_USER}" "${PRIMARY_DOMAIN}" "WordPress auto-install failed."
fi

################################################################################
# VERSION DISCOVERY
################################################################################

DB_VERSION_STR="$(docker exec "${CONTAINER_DB_NAME}" mysql --version 2>/dev/null || echo "unknown")"
WP_VERSION_STR="$(docker exec "${CONTAINER_CLI_NAME}" wp core version --allow-root --path=/var/www/html 2>/dev/null || echo "unknown")"
SERVER_IP="$(detect_server_ip)"

################################################################################
# SUMMARY
################################################################################

cat <<EOF

=====================================================
Site Created Successfully
=====================================================

Server:
  IP Address:       ${SERVER_IP}

Linux user:
  User:             ${SITE_USER}
  Home Directory:   ${SITE_HOME}

Primary Domain:
  Domain:           ${PRIMARY_DOMAIN}
  URL:              https://${PRIMARY_DOMAIN}
  Let's Encrypt:    ${LETSENCRYPT_EMAIL}

Database:
  Engine Version:   ${DB_VERSION_STR}
  Name:             ${MYSQL_DATABASE}
  User:             ${MYSQL_USER}
  Password:         ${MYSQL_PASSWORD}
  Root Password:    ${MYSQL_ROOT_PASSWORD}
  Local Port:       ${DB_LOCAL_PORT}

WordPress:
  Core Version:     ${WP_VERSION_STR}
  Title:            ${WP_TITLE}
  Admin User:       ${WP_ADMIN_USER}
  Admin Email:      ${WP_ADMIN_MAIL}
  Temp Password:    ${WP_ADMIN_TEMP_PASS}

SSH DB Tunnel:
  ssh -L ${DB_LOCAL_PORT}:127.0.0.1:${DB_LOCAL_PORT} ${SITE_USER}@${SERVER_IP}

=====================================================
EOF