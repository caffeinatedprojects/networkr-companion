#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

SITE_ROOT=""
SITE_USER=""
OLD_HOST=""
NEW_HOST=""
WEBSITE_ID=""

usage() {
    cat <<EOF
Usage:
  change-domain.sh --site-root "/home/user-site-123" --site-user "user-site-123" --old "old.example.com" --new "example.com" --website-id "123"

Workflow:
  - Update .env (PRIMARY_DOMAIN, PRIMARY_URL, URL_WITHOUT_HTTP, DOMAINS)
  - Restart docker (down/up)
  - Wait for DB (mariadb-admin ping, since mysql client may not exist in image)
  - wp-cli option updates + search-replace (all-tables, precise, recurse-objects)
  - Restart proxy (/home/networkr/docker-proxy)
  - Restart docker again
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site-root) SITE_ROOT="${2:-}"; shift 2 ;;
        --site-user) SITE_USER="${2:-}"; shift 2 ;;
        --old) OLD_HOST="${2:-}"; shift 2 ;;
        --new) NEW_HOST="${2:-}"; shift 2 ;;
        --website-id) WEBSITE_ID="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown arg: $1"; exit 2 ;;
    esac
done

if [[ -z "${SITE_ROOT}" || -z "${SITE_USER}" || -z "${OLD_HOST}" || -z "${NEW_HOST}" || -z "${WEBSITE_ID}" ]]; then

    usage
    exit 1

fi

SITE_ROOT="$(echo "${SITE_ROOT}" | sed 's:/*$::')"
OLD_HOST="$(echo "${OLD_HOST}" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##' | sed -E 's#/.*$##')"
NEW_HOST="$(echo "${NEW_HOST}" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##' | sed -E 's#/.*$##')"

ENV_FILE="${SITE_ROOT}/.env"
PRIMARY_URL="https://${NEW_HOST}"
DOMAINS="${NEW_HOST},www.${NEW_HOST}"

log "Change domain start | website_id=${WEBSITE_ID} | site_user=${SITE_USER} | site_root=${SITE_ROOT}"
log "Old host: ${OLD_HOST}"
log "New host: ${NEW_HOST}"

if [[ ! -d "${SITE_ROOT}" ]]; then
    log "ERROR: site root not found: ${SITE_ROOT}"
    exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
    log "ERROR: missing .env at ${ENV_FILE}"
    exit 1
fi

cd "${SITE_ROOT}"

set_env_key() {
    local key="$1"
    local value="$2"

    if grep -qE "^${key}=" "${ENV_FILE}"; then
        perl -pi -e "s#^${key}=.*#${key}=${value}#g" "${ENV_FILE}"
    else
        echo "${key}=${value}" >> "${ENV_FILE}"
    fi
}

restart_site_docker() {
    log "Restarting site docker stack..."
    docker compose down || true
    docker compose up -d --build
}

proxy_restart() {
    local proxy_root="/home/networkr/docker-proxy"
    local proxy_compose="${proxy_root}/docker-compose.yml"

    log "Restarting proxy..."

    if [[ -f "${proxy_compose}" ]]; then

        cd "${proxy_root}"
        docker compose down || true
        docker compose up -d
        cd "${SITE_ROOT}"
        log "Proxy restarted via compose."
        return 0

    fi

    log "ERROR: proxy compose not found at ${proxy_compose}"
    return 1
}

wait_for_db() {
    local tries=90
    local i=1

    if [[ -z "${CONTAINER_DB_NAME:-}" ]]; then
        log "ERROR: CONTAINER_DB_NAME not set in .env"
        return 1
    fi

    while [[ $i -le $tries ]]; do

        if docker exec "${CONTAINER_DB_NAME}" sh -lc 'mariadb-admin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
            log "DB is responding."
            return 0
        fi

        log "Waiting for DB... (${i}/${tries})"
        sleep 2
        i=$((i + 1))

    done

    log "ERROR: DB did not become ready in time"
    return 1
}

wp() {
    if [[ -z "${CONTAINER_CLI_NAME:-}" ]]; then
        log "ERROR: CONTAINER_CLI_NAME not set in .env"
        exit 1
    fi

    docker exec "${CONTAINER_CLI_NAME}" wp --allow-root --path="/var/www/html" "$@"
}

log "Step 1/5: Updating ${ENV_FILE} domain keys..."

set_env_key "PRIMARY_DOMAIN" "${NEW_HOST}"
set_env_key "PRIMARY_URL" "${PRIMARY_URL}"
set_env_key "URL_WITHOUT_HTTP" "${NEW_HOST}"
set_env_key "DOMAINS" "${DOMAINS}"

log ".env updated:"
log "  PRIMARY_DOMAIN=${NEW_HOST}"
log "  PRIMARY_URL=${PRIMARY_URL}"
log "  URL_WITHOUT_HTTP=${NEW_HOST}"
log "  DOMAINS=${DOMAINS}"

log "Loading updated .env into script environment..."
set +u
source "${ENV_FILE}"
set -u

log "Sanity: containers from env:"
log "  CONTAINER_DB_NAME=${CONTAINER_DB_NAME:-}"
log "  CONTAINER_CLI_NAME=${CONTAINER_CLI_NAME:-}"

log "Step 2/5: Restarting Docker so containers pick up env..."
restart_site_docker

log "Step 3/5: Waiting for DB..."
wait_for_db

log "Step 3/5: Updating WP options..."
wp option update home "${PRIMARY_URL}"
wp option update siteurl "${PRIMARY_URL}"

log "Step 3/5: Running search/replace (no permalinks changes)..."
wp search-replace "https://www.${OLD_HOST}" "https://www.${NEW_HOST}" --all-tables --precise --recurse-objects --skip-columns=guid
wp search-replace "http://www.${OLD_HOST}" "http://www.${NEW_HOST}" --all-tables --precise --recurse-objects --skip-columns=guid
wp search-replace "https://${OLD_HOST}" "https://${NEW_HOST}" --all-tables --precise --recurse-objects --skip-columns=guid
wp search-replace "http://${OLD_HOST}" "http://${NEW_HOST}" --all-tables --precise --recurse-objects --skip-columns=guid
wp search-replace "${OLD_HOST}" "${NEW_HOST}" --all-tables --precise --recurse-objects --skip-columns=guid

log "Step 4/5: Restarting proxy..."
proxy_restart

log "Step 5/5: Final Docker restart..."
restart_site_docker

log "CHANGE_DOMAIN_COMPLETE | website_id=${WEBSITE_ID} | new=${NEW_HOST}"
echo "CHANGE_DOMAIN_COMPLETE"