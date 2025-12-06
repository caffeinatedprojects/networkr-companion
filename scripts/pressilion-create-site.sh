#!/usr/bin/env bash
set -euo pipefail

PRESSILION_USER="networkr"
NETWORKR_ROOT="/home/${PRESSILION_USER}/networkr-companion"
TEMPLATE_ROOT="${NETWORKR_ROOT}/template"
GROUP_ADMIN="pressadmin"

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
EOF
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
WP_ADMIN_TEMP_PASS="$(openssl rand -base64 18)"
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
docker compose up -d --build 

################################################################################
# WAIT FOR MYSQL & WORDPRESS CORE BEFORE RUNNING INSTALL
################################################################################

log "Waiting for MySQL to become ready…"

MAX_ATTEMPTS=90    # 90 attempts × 2s = 3 minutes max wait
ATTEMPT=1

# STEP 1 — mysqladmin ping
while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
    if docker exec "${CONTAINER_DB_NAME}" mysqladmin ping \
         -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --silent >/dev/null 2>&1; then
        log "MySQL responded to ping."
        break
    fi
    log "MySQL ping failed… (${ATTEMPT}/${MAX_ATTEMPTS})"
    sleep 2
    ((ATTEMPT++))
done

if [[ $ATTEMPT -gt $MAX_ATTEMPTS ]]; then
    log "❌ MySQL did not become ready. Skipping auto-install."
else

    # STEP 2 — Ensure DB actually responds to SQL queries
    ATTEMPT=1
    log "Verifying database readiness…"

    while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
        if docker exec "${CONTAINER_DB_NAME}" \
            mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
            -e "SELECT 1;" "${MYSQL_DATABASE}" >/dev/null 2>&1; then
            log "MySQL database '${MYSQL_DATABASE}' is ready."
            break
        fi
        log "Database not ready yet… (${ATTEMPT}/${MAX_ATTEMPTS})"
        sleep 2
        ((ATTEMPT++))
    done

    # STEP 3 — Ensure WordPress files exist before install
    ATTEMPT=1
    log "Waiting for WordPress core files…"

    while [[ $ATTEMPT -le 30 ]]; do
        if docker exec "${CONTAINER_SITE_NAME}" test -f /var/www/html/wp-config.php \
        || docker exec "${CONTAINER_SITE_NAME}" test -f /var/www/html/index.php; then
            log "WordPress files detected."
            break
        fi
        log "WordPress files not present yet… (${ATTEMPT}/30)"
        sleep 2
        ((ATTEMPT++))
    done

    # SAFETY: Apache needs a moment after extracting WP
    sleep 5

    log "Running WordPress installation…"

    docker exec "${CONTAINER_CLI_NAME}" wp core install \
        --url="https://${PRIMARY_DOMAIN}" \
        --title="${WP_TITLE}" \
        --admin_user="${WP_ADMIN_USER}" \
        --admin_password="${WP_ADMIN_TEMP_PASS}" \
        --admin_email="${WP_ADMIN_MAIL}" \
        --skip-email  || log "⚠️ WP installation failed — may need manual retry."

    log "WordPress installation step complete."
fi

################################################################################
# SUMMARY
################################################################################

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