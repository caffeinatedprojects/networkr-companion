#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  Pressilion – Create Site Script (Apache WordPress Edition)
#  Creates a per-site Linux user + directory layout, copies templates,
#  generates .env + docker-compose.yml, brings up containers, waits for DB
#  and Apache, auto-installs WordPress.
# ============================================================================

PRESSILION_USER="networkr"
NETWORKR_ROOT="/home/${PRESSILION_USER}/networkr-companion"
TEMPLATE_ROOT="${NETWORKR_ROOT}/template"
GROUP_ADMIN="pressadmin"

log() {
    echo "[${EPOCHREALTIME}] $*"
}

cleanup_partial() {
    log "⚠️  Error encountered — cleaning up partial site for ${SITEUSER}…"

    docker rm -f "${SITEUSER}-wp" "${SITEUSER}-db" "${SITEUSER}-cli" >/dev/null 2>&1 || true
    docker network rm "${SITEUSER}_wordpress-vpc" >/dev/null 2>&1 || true

    userdel -r "${SITEUSER}" >/dev/null 2>&1 || true
}

trap cleanup_partial ERR


# ============================================================================
#  ARGUMENT PARSING
# ============================================================================
SITEUSER=""
WEBSITE_ID=""
PRIMARY_DOMAIN=""
LETSENCRYPT_EMAIL=""
WP_ADMIN_EMAIL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) SITEUSER="$2"; shift 2 ;;
        --website-id) WEBSITE_ID="$2"; shift 2 ;;
        --domain) PRIMARY_DOMAIN="$2"; shift 2 ;;
        --letsencrypt-email) LETSENCRYPT_EMAIL="$2"; shift 2 ;;
        --wp-admin-email) WP_ADMIN_EMAIL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: pressilion-create-site --user X --website-id N --domain example.com --letsencrypt-email EMAIL [--wp-admin-email EMAIL]"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SITEUSER" || -z "$WEBSITE_ID" || -z "$PRIMARY_DOMAIN" || -z "$LETSENCRYPT_EMAIL" ]]; then
    echo "Missing required arguments."
    exit 1
fi

if [[ -z "$WP_ADMIN_EMAIL" ]]; then
    WP_ADMIN_EMAIL="$LETSENCRYPT_EMAIL"
fi


# ============================================================================
#  USER + DIRECTORIES
# ============================================================================
log "Creating Linux user '${SITEUSER}'…"

if ! id -u "${SITEUSER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${SITEUSER}"
    passwd -l "${SITEUSER}" || true
else
    log "User already exists — continuing"
fi

SITE_HOME="/home/${SITEUSER}"
DATA_DIR="${SITE_HOME}/data"

mkdir -p "${DATA_DIR}/"{backup,temp,db,site}
chmod -R 770 "${DATA_DIR}"

# Copy template data structure
log "Copying template directory layout…"
rsync -a "${TEMPLATE_ROOT}/data/" "${DATA_DIR}/"

# Copy conf.d
mkdir -p "${SITE_HOME}/conf.d"
cp -f "${TEMPLATE_ROOT}/conf.d/php.ini" "${SITE_HOME}/conf.d/php.ini"

chown -R "${SITEUSER}:${GROUP_ADMIN}" "${SITE_HOME}"
chmod -R 750 "${SITE_HOME}"


# ============================================================================
#  ENV GENERATION
# ============================================================================
ENV_TEMPLATE="${TEMPLATE_ROOT}/.env.template"
ENV_TARGET="${SITE_HOME}/.env"

log "Generating .env…"

export WEBSITE_ID COMPOSE_PROJECT_NAME="${SITEUSER}" PRIMARY_DOMAIN DOMAINS="${PRIMARY_DOMAIN}" \
       LETSENCRYPT_EMAIL

MYSQL_DATABASE="wp_${WEBSITE_ID}"
MYSQL_USER="wp_${WEBSITE_ID}_u"
MYSQL_PASSWORD="$(openssl rand -hex 16)"
MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"
DB_LOCAL_PORT=$((33060 + WEBSITE_ID))

WP_ADMIN_TEMP_PASS="$(openssl rand -base64 18)"

export MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD DB_LOCAL_PORT \
       WP_ADMIN_TEMP_PASS WP_ADMIN_EMAIL WP_ADMIN_USER="admin" WP_TITLE="${PRIMARY_DOMAIN}" \
       WORDPRESS_TABLE_PREFIX="wp_"

envsubst < "${ENV_TEMPLATE}" > "${ENV_TARGET}"
chmod 640 "${ENV_TARGET}"


# ============================================================================
#  DOCKER-COMPOSE
# ============================================================================
COMPOSE_TEMPLATE="${TEMPLATE_ROOT}/docker-compose.yml"
COMPOSE_TARGET="${SITE_HOME}/docker-compose.yml"

log "Copying docker-compose.yml…"
cp -f "${COMPOSE_TEMPLATE}" "${COMPOSE_TARGET}"
chmod 640 "${COMPOSE_TARGET}"


# ============================================================================
#  START DOCKER STACK
# ============================================================================
cd "${SITE_HOME}"

log "Starting Docker stack…"
docker compose up -d --build


# ============================================================================
#  WAIT FOR MYSQL
# ============================================================================
log "Waiting for MySQL to become ready…"

MAX_WAIT=60
for i in $(seq 1 $MAX_WAIT); do
    if docker exec "${SITEUSER}-db" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" >/dev/null 2>&1; then
        log "✔ MySQL is ready"
        break
    fi
    log "… MySQL not ready yet ($i/$MAX_WAIT)"
    sleep 2
done


# ============================================================================
#  WAIT FOR APACHE TO SERVE
# ============================================================================
log "Waiting for Apache inside container…"

for i in $(seq 1 60); do
    if docker exec "${SITEUSER}-wp" sh -c "curl -fs http://localhost" >/dev/null 2>&1; then
        log "✔ Apache is serving requests"
        break
    fi
    log "… Apache not ready yet ($i/60)"
    sleep 2
done


# ============================================================================
#  WORDPRESS INSTALL
# ============================================================================
log "Running wp core install…"

docker exec "${SITEUSER}-cli" wp core install \
    --url="https://${PRIMARY_DOMAIN}" \
    --title="${PRIMARY_DOMAIN}" \
    --admin_user="admin" \
    --admin_password="${WP_ADMIN_TEMP_PASS}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --skip-email

log "✔ WordPress installed"


# ============================================================================
#  SUMMARY
# ============================================================================
cat <<EOF

=====================================================
 Site Created Successfully
=====================================================

Linux User:        ${SITEUSER}
Home Directory:    ${SITE_HOME}

Domain:            https://${PRIMARY_DOMAIN}
Let's Encrypt:     ${LETSENCRYPT_EMAIL}

Database:
  Name:            ${MYSQL_DATABASE}
  User:            ${MYSQL_USER}
  Password:        ${MYSQL_PASSWORD}
  Root Password:   ${MYSQL_ROOT_PASSWORD}
  Local Port:      ${DB_LOCAL_PORT}

WordPress:
  Admin User:      admin
  Admin Email:     ${WP_ADMIN_EMAIL}
  Temp Password:   ${WP_ADMIN_TEMP_PASS}

=====================================================

EOF