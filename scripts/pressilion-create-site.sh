#!/usr/bin/env bash
set -euo pipefail

PRESSILION_USER="networkr"
NETWORKR_ROOT="/home/${PRESSILION_USER}/networkr-companion"
TEMPLATE_ROOT="${NETWORKR_ROOT}/template"
GROUP_ADMIN="pressadmin"
DELETE_SCRIPT="${NETWORKR_ROOT}/scripts/pressilion-delete-site.sh"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
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

Notes:
  - DB image/version are taken from template/.env.template (e.g. mariadb:latest)
  - WordPress image/version are taken from template/.env.template (e.g. wordpress:latest)
EOF
}

################################################################################
# XKCD-STYLE PASSWORD GENERATOR (for WP admin temp password only)
################################################################################

generate_xkcd_password() {
  # Short curated list of readable words – good enough for human-usable strong pass
  local words=(
    Anchor Battle Candle Dragon Ember Forest Galaxy Hammer Ivory Journey
    Kingdom Lantern Meadow Nexus Orbit Prism Quartz Rocket Summit Thunder
    Umbra Velvet Willow Xenon Yonder Zenith Harbor Pixel Matrix Compass
    Spirit Silver Stone Shadow River Breeze Cosmic Mystic Noble Titan
    Ranger Cipher Phantom Velvet Wolf Solar Lunar Neon Emberstorm
  )
  local count=${#words[@]}

  local w1=${words[$((RANDOM % count))]}
  local w2=${words[$((RANDOM % count))]}
  local w3=${words[$((RANDOM % count))]}
  local w4=${words[$((RANDOM % count))]}
  local num=$((RANDOM % 10))

  echo "${w1}-${w2}-${w3}-${w4}-${num}"
}

################################################################################
# ROLLBACK / DELETE SITE HELPER
################################################################################

rollback_site() {
  local site_user="$1"

  log "⚠️  Failure detected, attempting rollback for site user '${site_user}'..."

  if [[ -f "${DELETE_SCRIPT}" ]]; then
    log "Running delete script: ${DELETE_SCRIPT} ${site_user}"
    # Use bash explicitly; do NOT require +x on the delete script
    if bash "${DELETE_SCRIPT}" "${site_user}"; then
      log "✅ Rollback completed for ${site_user}."
    else
      log "❌ Rollback script reported an error while deleting ${site_user}."
    fi
  else
    log "⚠️ Delete script not found at ${DELETE_SCRIPT}, rollback skipped."
  fi
}

################################################################################
# WAIT FOR DB TO BE READY (MySQL/MariaDB)
################################################################################

wait_for_db() {
  local db_container="$1"
  local root_password="$2"

  log "Waiting for MariaDB/MySQL to accept SQL queries…"

  local max_attempts=180
  local attempt=1

  while (( attempt <= max_attempts )); do

    # Method 1 — mysql client
    if docker exec "${db_container}" mysql -uroot -p"${root_password}" \
        -e "SELECT 1;" >/dev/null 2>&1; then
      log "✅ DB ready (mysql client, attempt ${attempt}/${max_attempts})"
      return 0
    fi

    # Method 2 — mariadb client
    if docker exec "${db_container}" mariadb -uroot -p"${root_password}" \
        -e "SELECT 1;" >/dev/null 2>&1; then
      log "✅ DB ready (mariadb client, attempt ${attempt}/${max_attempts})"
      return 0
    fi

    # Method 3 — direct socket query (bypass network + auth bugs)
    if docker exec "${db_container}" bash -c \
        "echo 'SELECT 1;' | mariadb -uroot -p\"${root_password}\"" \
        >/dev/null 2>&1; then
      log "✅ DB ready (socket test, attempt ${attempt}/${max_attempts})"
      return 0
    fi

    log "Database not ready… (${attempt}/${max_attempts})"
    sleep 2
    (( attempt++ ))
  done

  log "❌ Database did not become ready in time."
  return 1
}

################################################################################
# AUTO-INSTALL WORDPRESS VIA WP-CLI
################################################################################

auto_install_wordpress() {
  local cli_container="$1"
  local site_url="$2"
  local title="$3"
  local admin_user="$4"
  local admin_pass="$5"
  local admin_email="$6"

  log "Checking if WordPress is already installed in ${cli_container}..."

  # If WP is already installed, don't touch it
  if docker exec "${cli_container}" wp core is-installed --allow-root >/dev/null 2>&1; then
    log "WordPress already installed. Skipping auto-install."
    return 0
  fi

  log "Running WP-CLI core install..."
  if docker exec "${cli_container}" wp core install \
      --url="${site_url}" \
      --title="${title}" \
      --admin_user="${admin_user}" \
      --admin_password="${admin_pass}" \
      --admin_email="${admin_email}" \
      --skip-email \
      --allow-root >/dev/null 2>&1; then
    log "✅ WordPress auto-install completed successfully."
    return 0
  else
    log "❌ WordPress auto-install failed."
    return 1
  fi
}

################################################################################
# CAPTURE VERSIONS FOR SUMMARY
################################################################################

get_version_info() {
  local db_container="$1"
  local cli_container="$2"

  DB_VERSION_INFO=$(docker exec "${db_container}" mysql --version 2>/dev/null || echo "unknown")
  WP_CORE_VERSION=$(docker exec "${cli_container}" wp core version --allow-root 2>/dev/null || echo "unknown")
  PHP_VERSION_INFO=$(docker exec "${cli_container}" php -r 'echo phpversion();' 2>/dev/null || echo "unknown")

  # Export for use in summary
  export DB_VERSION_INFO WP_CORE_VERSION PHP_VERSION_INFO
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
  # Ensure home exists even if user already present
  mkdir -p "${SITE_HOME}"
fi

# Group setup
if ! getent group "${GROUP_ADMIN}" >/dev/null; then
  groupadd "${GROUP_ADMIN}"
fi

usermod -g "${SITE_USER}" "${SITE_USER}" || true
chown "${SITE_USER}:${GROUP_ADMIN}" "${SITE_HOME}"
chmod 750 "${SITE_HOME}"

log "Creating data directories in ${DATA_DIR}..."
mkdir -p "${DATA_DIR}/backup" "${DATA_DIR}/temp" "${DATA_DIR}/db" "${DATA_DIR}/site"
chown -R "${SITE_USER}:${GROUP_ADMIN}" "${DATA_DIR}"
chmod -R 770 "${DATA_DIR}"

# Copy template structure
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

MYSQL_DATABASE="wp_${WEBSITE_ID}"
MYSQL_USER="wp_${WEBSITE_ID}_u"
MYSQL_PASSWORD="$(openssl rand -hex 16)"
MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"

DB_LOCAL_PORT=$((33060 + WEBSITE_ID))

WP_TITLE="${PRIMARY_DOMAIN}"
WP_ADMIN_USER="admin"
# XKCD-style admin temp password
WP_ADMIN_TEMP_PASS="$(generate_xkcd_password)"
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
  log "❌ docker compose up failed for ${SITE_USER}."
  rollback_site "${SITE_USER}"
  exit 1
fi

################################################################################
# WAIT FOR DB, THEN AUTO-INSTALL WORDPRESS
################################################################################

DB_CONTAINER="${CONTAINER_DB_NAME}"
CLI_CONTAINER="${CONTAINER_CLI_NAME}"
SITE_URL="https://${PRIMARY_DOMAIN}"

if ! wait_for_db "${DB_CONTAINER}" "${MYSQL_ROOT_PASSWORD}"; then
  # DB never came up – rollback the entire site
  rollback_site "${SITE_USER}"
  exit 1
fi

# Try auto-install of WordPress; if it fails, rollback as well
if ! auto_install_wordpress "${CLI_CONTAINER}" "${SITE_URL}" "${WP_TITLE}" \
     "${WP_ADMIN_USER}" "${WP_ADMIN_TEMP_PASS}" "${WP_ADMIN_MAIL}"; then
  rollback_site "${SITE_USER}"
  exit 1
fi

################################################################################
# COLLECT VERSION INFO
################################################################################

get_version_info "${DB_CONTAINER}" "${CLI_CONTAINER}"

# Determine server IP for summary (best-effort)
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER-IP")"

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
  Username:         ${SITE_USER}
  Home Directory:   ${SITE_HOME}

Primary Domain:
  Domain:           ${PRIMARY_DOMAIN}
  Public URL:       ${SITE_URL}
  Let's Encrypt:    ${LETSENCRYPT_EMAIL}

Database:
  Image:            mariadb:latest (from .env.template)
  Reported:         ${DB_VERSION_INFO}
  Name:             ${MYSQL_DATABASE}
  User:             ${MYSQL_USER}
  Password:         ${MYSQL_PASSWORD}
  Root Password:    ${MYSQL_ROOT_PASSWORD}
  Local Port:       ${DB_LOCAL_PORT}

WordPress:
  Image:            wordpress:latest (Apache)
  WP Core Version:  ${WP_CORE_VERSION}
  PHP Version:      ${PHP_VERSION_INFO}
  Title:            ${WP_TITLE}
  Admin User:       ${WP_ADMIN_USER}
  Admin Email:      ${WP_ADMIN_MAIL}
  Temp Password:    ${WP_ADMIN_TEMP_PASS}

SSH DB Tunnel:
  ssh -L ${DB_LOCAL_PORT}:127.0.0.1:${DB_LOCAL_PORT} ${SITE_USER}@${SERVER_IP}

=====================================================
EOF