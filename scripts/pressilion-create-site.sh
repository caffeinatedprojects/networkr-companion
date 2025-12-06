#!/usr/bin/env bash
set -euo pipefail

###################################
# CONFIG
###################################

PRESSILION_USER="networkr"
NETWORKR_ROOT="/home/${PRESSILION_USER}/networkr-companion"
TEMPLATE_ROOT="${NETWORKR_ROOT}/Template"
GROUP_ADMIN="pressadmin"

###################################
# HELPERS
###################################

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
  fi
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

###################################
# ARG PARSING
###################################

SITE_USER=""
WEBSITE_ID=""
PRIMARY_DOMAIN=""
LETSENCRYPT_EMAIL=""
WP_ADMIN_EMAIL=""
JSON_MODE=0

usage() {
  cat <<EOF
Usage:
  pressilion-create-site --user USERNAME --website-id ID --domain DOMAIN \\
                         --letsencrypt-email EMAIL [--wp-admin-email EMAIL] [--json]

Required:
  --user                Linux username (e.g. user-site-123)
  --website-id          Numeric website ID
  --domain              Primary domain (example.com)
  --letsencrypt-email   Email for Let's Encrypt

Optional:
  --wp-admin-email      WP admin email (defaults to LE email)
  --json                Output JSON summary instead of pretty text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) SITE_USER="$2"; shift 2;;
    --website-id) WEBSITE_ID="$2"; shift 2;;
    --domain) PRIMARY_DOMAIN="$2"; shift 2;;
    --letsencrypt-email) LETSENCRYPT_EMAIL="$2"; shift 2;;
    --wp-admin-email) WP_ADMIN_EMAIL="$2"; shift 2;;
    --json) JSON_MODE=1; shift 1;;
    -h|--help) usage; exit 0;;
    *)
      echo "Unknown argument: $1"; usage; exit 1;;
  esac
done

[[ -z "$SITE_USER" || -z "$WEBSITE_ID" || -z "$PRIMARY_DOMAIN" || -z "$LETSENCRYPT_EMAIL" ]] &&
  fail "Missing required arguments."

[[ -z "$WP_ADMIN_EMAIL" ]] && WP_ADMIN_EMAIL="$LETSENCRYPT_EMAIL"

###################################
# PRE-VALIDATION
###################################

require_root

# Domain sanity check
if ! [[ "$PRIMARY_DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
  fail "Invalid domain format: ${PRIMARY_DOMAIN}"
fi

# Website ID numeric
if ! [[ "$WEBSITE_ID" =~ ^[0-9]+$ ]]; then
  fail "website-id must be numeric."
fi

SITE_HOME="/home/${SITE_USER}"
DATA_DIR="${SITE_HOME}/data"

if [[ -d "$SITE_HOME" ]]; then
  fail "Site home ${SITE_HOME} already exists. Aborting."
fi

log "✔ Domain validated: ${PRIMARY_DOMAIN}"
log "✔ Website ID: ${WEBSITE_ID}"

###################################
# ERROR ROLLBACK
###################################

CREATED_USER=0

on_error() {
  log "⚠️  Error occurred, cleaning up partial site for ${SITE_USER}..."
  if [[ "${CREATED_USER}" -eq 1 ]]; then
    log "  - Deleting user ${SITE_USER} and home ${SITE_HOME}"
    userdel -r "${SITE_USER}" 2>/dev/null || true
    rm -rf "${SITE_HOME}" || true
  fi
  exit 1
}
trap on_error ERR

###################################
# CREATE USER + FOLDERS
###################################

log "Creating Linux user '${SITE_USER}'..."

useradd -m -s /bin/bash "${SITE_USER}"
CREATED_USER=1
passwd -l "${SITE_USER}" || true

# Ensure pressadmin exists
getent group "${GROUP_ADMIN}" >/dev/null || groupadd "${GROUP_ADMIN}"

# Primary group = itself, also add to pressadmin
usermod -g "${SITE_USER}" "${SITE_USER}"
usermod -aG "${GROUP_ADMIN}" "${SITE_USER}"

chown "${SITE_USER}:${GROUP_ADMIN}" "${SITE_HOME}"
chmod 750 "${SITE_HOME}"

log "Creating data directories under ${DATA_DIR}..."
mkdir -p "${DATA_DIR}"/{backup,temp,db,site}
chown -R "${SITE_USER}:${GROUP_ADMIN}" "${DATA_DIR}"
chmod -R 770 "${DATA_DIR}"

###################################
# TEMPLATE SYNC
###################################

log "Copying template structure..."
if [[ -d "${TEMPLATE_ROOT}/data" ]]; then
  rsync -a "${TEMPLATE_ROOT}/data/" "${DATA_DIR}/" || true
fi

if [[ -d "${TEMPLATE_ROOT}/conf.d" ]]; then
  rsync -a "${TEMPLATE_ROOT}/conf.d" "${SITE_HOME}/" || true
fi

chown -R "${SITE_USER}:${GROUP_ADMIN}" "${SITE_HOME}/conf.d"
chmod -R 770 "${SITE_HOME}/conf.d"

###################################
# ENV + COMPOSE GENERATION
###################################

log "Generating configuration files..."

ENV_TEMPLATE="${TEMPLATE_ROOT}/.env.template"
COMPOSE_TEMPLATE="${TEMPLATE_ROOT}/docker-compose.template.yml"

[[ -f "$ENV_TEMPLATE" ]] || fail "Env template not found at ${ENV_TEMPLATE}"
[[ -f "$COMPOSE_TEMPLATE" ]] || fail "docker-compose template not found at ${COMPOSE_TEMPLATE}"

ENV_TARGET="${SITE_HOME}/.env"
COMPOSE_TARGET="${SITE_HOME}/docker-compose.yml"

COMPOSE_PROJECT_NAME="${SITE_USER}"

CONTAINER_DB_NAME="${SITE_USER}-db"
CONTAINER_SITE_NAME="${SITE_USER}-wp"
CONTAINER_CLI_NAME="${SITE_USER}-cli"

MYSQL_DATABASE="wp_${WEBSITE_ID}"
MYSQL_USER="wp_${WEBSITE_ID}_u"
MYSQL_PASSWORD="$(openssl rand -hex 16)"
MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"

DB_LOCAL_PORT=$((33060 + WEBSITE_ID))

WP_TITLE="${PRIMARY_DOMAIN}"
WP_ADMIN_USER="admin"
WP_ADMIN_TEMP_PASS="$(openssl rand -base64 18)"
WP_PERMA_STRUCTURE='/%year%/%monthnum%/%postname%/'
WP_ADMIN_MAIL="${WP_ADMIN_EMAIL}"

export WEBSITE_ID COMPOSE_PROJECT_NAME PRIMARY_DOMAIN DOMAINS="${PRIMARY_DOMAIN}" \
       LETSENCRYPT_EMAIL CONTAINER_DB_NAME CONTAINER_SITE_NAME CONTAINER_CLI_NAME \
       MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD DB_LOCAL_PORT \
       WP_TITLE WP_ADMIN_USER WP_ADMIN_TEMP_PASS WP_ADMIN_MAIL WP_PERMA_STRUCTURE

envsubst < "$ENV_TEMPLATE" > "$ENV_TARGET"
cp "$COMPOSE_TEMPLATE" "$COMPOSE_TARGET"

# Secure configs: readable by pressilion + pressadmin
chown "${PRESSILION_USER}:${GROUP_ADMIN}" "$ENV_TARGET" "$COMPOSE_TARGET"
chmod 640 "$ENV_TARGET" "$COMPOSE_TARGET"

###################################
# DOCKER STACK
###################################

log "Ensuring proxy network exists..."
docker network inspect proxy >/dev/null 2>&1 ||
  fail "Proxy network 'proxy' not found. Is nginx-proxy-automation running?"

log "Starting Docker stack for ${SITE_USER}..."
cd "$SITE_HOME"
docker compose up -d --build

# At this point, containers should be created
log "Checking containers exist..."
docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_DB_NAME}$" ||
  fail "DB container ${CONTAINER_DB_NAME} not found after compose up."
docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_SITE_NAME}$" ||
  fail "WP container ${CONTAINER_SITE_NAME} not found after compose up."
docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_CLI_NAME}$" ||
  fail "CLI container ${CONTAINER_CLI_NAME} not found after compose up."

###################################
# WAIT FOR DB + WP
###################################

log "Waiting for database to become ready..."
for i in {1..40}; do
  if docker exec "${CONTAINER_DB_NAME}" mysqladmin ping -h"127.0.0.1" -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent >/dev/null 2>&1; then
    log "DB is ready."
    break
  fi
  log "  - DB not ready yet, retrying (${i}/40)..."
  sleep 3
done

# Basic HTTP check (optional, best-effort)
log "Waiting for WP container HTTP to respond..."
for i in {1..40}; do
  HTTP_CODE=$(docker exec "${CONTAINER_SITE_NAME}" sh -c "curl -s -o /dev/null -w '%{http_code}' http://localhost || echo 000") || true
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
    log "WP HTTP responded with ${HTTP_CODE}."
    break
  fi
  log "  - WP not ready yet, code=${HTTP_CODE}, retrying (${i}/40)..."
  sleep 3
done

###################################
# WP-CLI INSTALL
###################################

log "Running WP-CLI core install..."

docker exec "${CONTAINER_CLI_NAME}" wp core install \
  --path="/var/www/html" \
  --url="${PRIMARY_DOMAIN}" \
  --title="${WP_TITLE}" \
  --admin_user="${WP_ADMIN_USER}" \
  --admin_password="${WP_ADMIN_TEMP_PASS}" \
  --admin_email="${WP_ADMIN_EMAIL}" \
  --skip-email

log "Setting permalink structure..."
docker exec "${CONTAINER_CLI_NAME}" wp rewrite structure "${WP_PERMA_STRUCTURE}" --hard || true
docker exec "${CONTAINER_CLI_NAME}" wp rewrite flush --hard || true

###################################
# SUCCESS – disable rollback trap
###################################

trap - ERR
CREATED_USER=0

###################################
# OUTPUT
###################################

if [[ "${JSON_MODE}" -eq 1 ]]; then
  # JSON output for Pressilion API
  cat <<JSON
{
  "status": "success",
  "site_user": "${SITE_USER}",
  "site_home": "${SITE_HOME}",
  "data_dir": "${DATA_DIR}",
  "domain": "${PRIMARY_DOMAIN}",
  "lets_encrypt_email": "${LETSENCRYPT_EMAIL}",
  "db": {
    "container": "${CONTAINER_DB_NAME}",
    "name": "${MYSQL_DATABASE}",
    "user": "${MYSQL_USER}",
    "password": "${MYSQL_PASSWORD}",
    "root_password": "${MYSQL_ROOT_PASSWORD}",
    "local_port": ${DB_LOCAL_PORT}
  },
  "wp": {
    "container": "${CONTAINER_SITE_NAME}",
    "cli_container": "${CONTAINER_CLI_NAME}",
    "title": "${WP_TITLE}",
    "admin_user": "${WP_ADMIN_USER}",
    "admin_email": "${WP_ADMIN_EMAIL}",
    "admin_temp_password": "${WP_ADMIN_TEMP_PASS}"
  }
}
JSON

else
  # Human readable summary
  cat <<EOF

=====================================================
Site created successfully
=====================================================

Linux user:          ${SITE_USER}
Home:                ${SITE_HOME}
Data dir:            ${DATA_DIR}

Domain:              ${PRIMARY_DOMAIN}
Let's Encrypt email: ${LETSENCRYPT_EMAIL}

DB Container:        ${CONTAINER_DB_NAME}
DB Name:             ${MYSQL_DATABASE}
DB User:             ${MYSQL_USER}
DB Password:         ${MYSQL_PASSWORD}
DB Root Password:    ${MYSQL_ROOT_PASSWORD}
DB Local Port:       ${DB_LOCAL_PORT}

WP Container:        ${CONTAINER_SITE_NAME}
WP CLI Container:    ${CONTAINER_CLI_NAME}
WP Title:            ${WP_TITLE}
WP Admin User:       ${WP_ADMIN_USER}
WP Admin Email:      ${WP_ADMIN_EMAIL}
WP Temp Password:    ${WP_ADMIN_TEMP_PASS}

To access DB via SSH tunnel:

  ssh -L ${DB_LOCAL_PORT}:127.0.0.1:3306 ${SITE_USER}@<server-ip>

Then connect your DB client to:

  Host: 127.0.0.1
  Port: ${DB_LOCAL_PORT}
  User: ${MYSQL_USER}
  Pass: ${MYSQL_PASSWORD}
  DB:   ${MYSQL_DATABASE}

=====================================================
EOF
fi