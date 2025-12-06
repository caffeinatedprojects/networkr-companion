#!/usr/bin/env bash
set -euo pipefail

# ================================================================
#  Pressilion Create Site Script
#  Creates a Linux user + isolated WordPress Docker stack
# ================================================================

PRESSILION_USER="networkr"
NETWORKR_ROOT="/home/${PRESSILION_USER}/networkr-companion"
TEMPLATE_ROOT="${NETWORKR_ROOT}/template"   # <-- FIXED lowercase path
GROUP_ADMIN="pressadmin"

# ---------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------
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

Required:
  --user                Linux username for the site (e.g. user-site-123)
  --website-id          Numeric ID from Pressilion
  --domain              Primary domain (example.com)
  --letsencrypt-email   Email used with Let's Encrypt

Optional:
  --wp-admin-email      WP admin email (default = LE email)

Creates:
  - Linux user + /home/<user>/data
  - Docker WordPress stack
  - .env + docker-compose.yml
  - Ready-to-serve HTTPS WP site
EOF
}

# ---------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------
SITE_USER=""
WEBSITE_ID=""
PRIMARY_DOMAIN=""
LETSENCRYPT_EMAIL=""
WP_ADMIN_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      SITE_USER="$2"; shift 2 ;;
    --website-id)
      WEBSITE_ID="$2"; shift 2 ;;
    --domain)
      PRIMARY_DOMAIN="$2"; shift 2 ;;
    --letsencrypt-email)
      LETSENCRYPT_EMAIL="$2"; shift 2 ;;
    --wp-admin-email)
      WP_ADMIN_EMAIL="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "${SITE_USER}" || -z "${WEBSITE_ID}" || -z "${PRIMARY_DOMAIN}" || -z "${LETSENCRYPT_EMAIL}" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

if [[ -z "${WP_ADMIN_EMAIL}" ]]; then
  WP_ADMIN_EMAIL="${LETSENCRYPT_EMAIL}"
fi

# ---------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------
require_root

SITE_HOME="/home/${SITE_USER}"
DATA_DIR="${SITE_HOME}/data"

log "Creating Linux user '${SITE_USER}'..."

if ! id -u "${SITE_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${SITE_USER}"
  passwd -l "${SITE_USER}" >/dev/null 2>&1 || true
else
  log "User already exists."
fi

# Ensure pressadmin group exists
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

# ---------------------------------------------------------------
# Sync template data
# ---------------------------------------------------------------
if [[ -d "${TEMPLATE_ROOT}/data" ]]; then
  log "Syncing template data structure..."
  rsync -a "${TEMPLATE_ROOT}/data/" "${DATA_DIR}/"
  chown -R "${SITE_USER}:${GROUP_ADMIN}" "${DATA_DIR}" || true
fi

# ---------------------------------------------------------------
# conf.d/php.ini setup (safe)
# ---------------------------------------------------------------
log "Setting up conf.d/php.ini..."

mkdir -p "${SITE_HOME}/conf.d"
chown "${SITE_USER}:${GROUP_ADMIN}" "${SITE_HOME}/conf.d"
chmod 770 "${SITE_HOME}/conf.d"

if [[ -f "${TEMPLATE_ROOT}/conf.d/php.ini" ]]; then
  cp -f "${TEMPLATE_ROOT}/conf.d/php.ini" "${SITE_HOME}/conf.d/php.ini"
  chown "${SITE_USER}:${GROUP_ADMIN}" "${SITE_HOME}/conf.d/php.ini"
else
  log "⚠️  WARNING: Template php.ini missing at ${TEMPLATE_ROOT}/conf.d/php.ini"
fi

# ---------------------------------------------------------------
# Generate .env from template
# ---------------------------------------------------------------
ENV_TEMPLATE="${TEMPLATE_ROOT}/.env.template"
ENV_TARGET="${SITE_HOME}/.env"

if [[ ! -f "${ENV_TEMPLATE}" ]]; then
  echo "ERROR: Env template missing at ${ENV_TEMPLATE}" >&2
  exit 1
fi

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
WP_ADMIN_TEMP_PASS="$(openssl rand -base64 18)"
WP_PERMA_STRUCTURE='/%year%/%monthnum%/%postname%/'

export WEBSITE_ID COMPOSE_PROJECT_NAME PRIMARY_DOMAIN DOMAINS \
  LETSENCRYPT_EMAIL CONTAINER_DB_NAME CONTAINER_SITE_NAME \
  CONTAINER_CLI_NAME MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD \
  MYSQL_ROOT_PASSWORD DB_LOCAL_PORT WP_TITLE WP_ADMIN_USER \
  WP_ADMIN_TEMP_PASS WP_ADMIN_MAIL WP_PERMA_STRUCTURE

envsubst < "${ENV_TEMPLATE}" > "${ENV_TARGET}"

chown "${PRESSILION_USER}:${GROUP_ADMIN}" "${ENV_TARGET}"
chmod 640 "${ENV_TARGET}"

# ---------------------------------------------------------------
# Docker Compose file
# ---------------------------------------------------------------
COMPOSE_TEMPLATE="${TEMPLATE_ROOT}/docker-compose.yml"   # <-- FIXED filename
COMPOSE_TARGET="${SITE_HOME}/docker-compose.yml"

if [[ ! -f "${COMPOSE_TEMPLATE}" ]]; then
  echo "ERROR: docker-compose template missing at ${COMPOSE_TEMPLATE}" >&2
  exit 1
fi

log "Copying docker-compose.yml..."
cp -f "${COMPOSE_TEMPLATE}" "${COMPOSE_TARGET}"
chown "${PRESSILION_USER}:${GROUP_ADMIN}" "${COMPOSE_TARGET}"
chmod 640 "${COMPOSE_TARGET}"

# ---------------------------------------------------------------
# Start Docker stack
# ---------------------------------------------------------------
log "Bringing up the Docker stack..."
cd "${SITE_HOME}"
docker compose up -d --build

# ---------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------
cat <<EOF

=====================================================
Site Created Successfully
=====================================================

Linux user:        ${SITE_USER}
Home Directory:    ${SITE_HOME}
Primary Domain:    ${PRIMARY_DOMAIN}
Let's Encrypt:     ${LETSENCRYPT_EMAIL}

Database:
  Name:            ${MYSQL_DATABASE}
  User:            ${MYSQL_USER}
  Password:        ${MYSQL_PASSWORD}
  Root Password:   ${MYSQL_ROOT_PASSWORD}
  Local Port:      ${DB_LOCAL_PORT}

WordPress:
  Title:           ${WP_TITLE}
  Admin User:      admin
  Admin Email:     ${WP_ADMIN_EMAIL}
  Temp Password:   ${WP_ADMIN_TEMP_PASS}

SSH DB Tunnel:
  ssh -L ${DB_LOCAL_PORT}:127.0.0.1:${DB_LOCAL_PORT} ${SITE_USER}@SERVER-IP

=====================================================
EOF