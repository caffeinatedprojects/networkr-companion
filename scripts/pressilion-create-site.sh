#!/usr/bin/env bash
set -euo pipefail

PRESSILION_USER="networkr"
NETWORKR_ROOT="/home/${PRESSILION_USER}/networkr-companion"
TEMPLATE_ROOT="${NETWORKR_ROOT}/template"
GROUP_ADMIN="pressadmin"
DELETE_SCRIPT="${NETWORKR_ROOT}/scripts/pressilion-delete-site.sh"

WP_ADMIN_USER=""

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
  pressilion-create-site \\
    --user USERNAME \\
    --website-id ID \\
    --domain DOMAIN \\
    --letsencrypt-email EMAIL \\
    [--wp-admin-email EMAIL] \\
    [--wp-admin-user USER]

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
# SIMPLE .env PARSER (for image names/versions)
################################################################################

env_get_var() {
  local file="$1"
  local key="$2"
  if [[ -f "$file" ]]; then
    grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true
  fi
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

    # Method 3 — direct socket query (bypass network + auth quirks)
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
# INSTALL PRESSILLION HEALTH MU-PLUGIN (NO PERMISSION CHANGES)
################################################################################

install_pressillion_health_mu_plugin() {
  local cli_container="$1"
  local template_root="$2"
  local plugin_src="${template_root}/mu-plugins/pressillion-health.php"

  if [[ ! -f "${plugin_src}" ]]; then
    log "⚠️ Pressillion Health MU-plugin not found at ${plugin_src}. Skipping."
    return 0
  fi

  # If the container isn't there yet, don't kill the script.
  if ! docker ps --format '{{.Names}}' | grep -qx "${cli_container}"; then
    log "⚠️ CLI container ${cli_container} not running yet. Skipping MU-plugin install."
    return 0
  fi

  log "Installing Pressillion Health MU-plugin inside container (non-fatal)..."

  local wp_path="/var/www/html"
  local mu_dir="${wp_path}/wp-content/mu-plugins"
  local plugin_dst="${mu_dir}/pressillion-health.php"

  # Everything below must be non-fatal
  docker exec "${cli_container}" bash -lc "mkdir -p '${mu_dir}'" >/dev/null 2>&1 || true
  docker cp "${plugin_src}" "${cli_container}:${plugin_dst}" >/dev/null 2>&1 || true
  docker exec "${cli_container}" bash -lc "chmod 644 '${plugin_dst}'" >/dev/null 2>&1 || true

  # Optional: log only
  if docker exec "${cli_container}" bash -lc "test -f '${plugin_dst}'" >/dev/null 2>&1; then
    log "✅ MU-plugin installed: ${plugin_dst}"
  else
    log "⚠️ MU-plugin copy did not complete (non-fatal)."
  fi

  return 0
}

################################################################################
# CAPTURE VERSIONS FOR SUMMARY
################################################################################

get_version_info() {
  local db_container="$1"
  local cli_container="$2"

  # Try mysql first, then mariadb
  RAW_DB_VERSION=$(
    docker exec "${db_container}" mysql --version 2>/dev/null ||
    docker exec "${db_container}" mariadb --version 2>/dev/null ||
    echo "unknown"
  )

  # ------------------------------------------------------------
  # Extract just "12.1.2-MariaDB" or "8.0.40" cleanly
  # ------------------------------------------------------------
  if [[ "$RAW_DB_VERSION" == "unknown" ]]; then
    DB_VERSION_INFO="unknown"
  else
    # Remove leading noise, keep version-like tokens
    DB_VERSION_INFO=$(echo "$RAW_DB_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-MariaDB)?')
    [[ -z "$DB_VERSION_INFO" ]] && DB_VERSION_INFO="$RAW_DB_VERSION"
  fi

  # WordPress + PHP versions
  WP_CORE_VERSION=$(docker exec "${cli_container}" wp core version --allow-root 2>/dev/null || echo "unknown")
  PHP_VERSION_INFO=$(docker exec "${cli_container}" php -r 'echo phpversion();' 2>/dev/null || echo "unknown")

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
    --user)
      SITE_USER="$2"
      shift 2
      ;;
    --website-id)
      WEBSITE_ID="$2"
      shift 2
      ;;
    --domain)
      PRIMARY_DOMAIN="$2"
      shift 2
      ;;
    --letsencrypt-email)
      LETSENCRYPT_EMAIL="$2"
      shift 2
      ;;
    --wp-admin-email)
      WP_ADMIN_EMAIL="$2"
      shift 2
      ;;
    --wp-admin-user)
      WP_ADMIN_USER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$SITE_USER" || -z "$WEBSITE_ID" || -z "$PRIMARY_DOMAIN" || -z "$LETSENCRYPT_EMAIL" ]]; then
  echo "Missing required arguments."
  usage
  exit 1
fi

if [[ -z "$WP_ADMIN_EMAIL" ]]; then
  WP_ADMIN_EMAIL="$LETSENCRYPT_EMAIL"
fi

if [[ -z "$WP_ADMIN_USER" ]]; then
  WP_ADMIN_USER="admin"
fi

generate_json_summary() {
  cat <<EOF
{
  "server": {
    "ip": "${SERVER_IP}"
  },
  "user": {
    "username": "${SITE_USER}",
    "home_directory": "${SITE_HOME}"
  },
  "domain": {
    "primary_domain": "${PRIMARY_DOMAIN}",
    "public_url": "${SITE_URL}",
    "letsencrypt_email": "${LETSENCRYPT_EMAIL}"
  },
  "database": {
    "image": "mariadb:latest",
    "version": "${DB_VERSION_INFO}",
    "name": "${MYSQL_DATABASE}",
    "user": "${MYSQL_USER}",
    "password": "${MYSQL_PASSWORD}",
    "root_password": "${MYSQL_ROOT_PASSWORD}",
    "local_port": ${DB_LOCAL_PORT}
  },
  "wordpress": {
    "image": "wordpress:latest",
    "core_version": "${WP_CORE_VERSION}",
    "php_version": "${PHP_VERSION_INFO}",
    "title": "${WP_TITLE}",
    "admin_user": "${WP_ADMIN_USER}",
    "admin_email": "${WP_ADMIN_MAIL}",
    "admin_temp_password": "${WP_ADMIN_TEMP_PASS}"
  },
  "ssh": {
    "host": "${SERVER_IP}",
    "port": 22,
    "username": "${SITE_USER}",
    "standard_ssh_command": "ssh ${SITE_USER}@${SERVER_IP}",
    "sftp_command": "sftp ${SITE_USER}@${SERVER_IP}",
    "db_tunnel": {
      "local_port": ${DB_LOCAL_PORT},
      "remote_host": "127.0.0.1",
      "remote_port": ${DB_LOCAL_PORT},
      "command": "ssh -L ${DB_LOCAL_PORT}:127.0.0.1:${DB_LOCAL_PORT} ${SITE_USER}@${SERVER_IP}"
    }
  },
  "containers": {
    "db_container": "${CONTAINER_DB_NAME}",
    "wp_container": "${CONTAINER_SITE_NAME}",
    "cli_container": "${CONTAINER_CLI_NAME}"
  }
}
EOF
}

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
# Use caller-provided admin username (or default 'admin' from earlier)
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

# Read actual image names/versions from the generated .env
DB_IMAGE_NAME="$(env_get_var "${ENV_TARGET}" "DB_IMAGE")"
DB_IMAGE_VERSION="$(env_get_var "${ENV_TARGET}" "DB_VERSION")"
SITE_IMAGE_NAME="$(env_get_var "${ENV_TARGET}" "SITE_IMAGE")"
SITE_IMAGE_VERSION="$(env_get_var "${ENV_TARGET}" "SITE_VERSION")"

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
  rollback_site "${SITE_USER}"
  exit 1
fi

if ! auto_install_wordpress "${CLI_CONTAINER}" "${SITE_URL}" "${WP_TITLE}" \
     "${WP_ADMIN_USER}" "${WP_ADMIN_TEMP_PASS}" "${WP_ADMIN_MAIL}"; then
  rollback_site "${SITE_USER}"
  exit 1
fi

################################################################################
# INSTALL MU-PLUGIN (NO HOST PERMISSION CHANGES)
################################################################################

install_pressillion_health_mu_plugin "${CLI_CONTAINER}" "${TEMPLATE_ROOT}"

################################################################################
# COLLECT VERSION INFO
################################################################################

get_version_info "${DB_CONTAINER}" "${CLI_CONTAINER}"

# Determine server IP for summary (best-effort)
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER-IP")"

################################################################################
# SUMMARY
################################################################################

log "Generating JSON summary..."
generate_json_summary > "${SITE_ROOT}/site-summary.json"
log "JSON summary written to ${SITE_ROOT}/site-summary.json"

# Output JSON to STDOUT for Pressillion
echo "::PRESSILION_JSON_START::"
generate_json_summary
echo "::PRESSILION_JSON_END::"