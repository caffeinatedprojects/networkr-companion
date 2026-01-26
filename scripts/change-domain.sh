#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

SITE_ROOT=""
SITE_USER=""
OLD_HOST=""
NEW_HOST=""
WEBSITE_ID=""
LETSENCRYPT_EMAIL=""

usage() {
    cat <<EOF
Usage:
  change-domain.sh --site-root "/home/user-site-123" --site-user "user-site-123" --old "old.example.com" --new "example.com" --website-id "123" [--letsencrypt-email "me@example.com"]

Notes:
  - Expects docker compose project in SITE_ROOT
  - Expects wp-cli container name available in .env or compose
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site-root) SITE_ROOT="${2:-}"; shift 2 ;;
        --site-user) SITE_USER="${2:-}"; shift 2 ;;
        --old) OLD_HOST="${2:-}"; shift 2 ;;
        --new) NEW_HOST="${2:-}"; shift 2 ;;
        --website-id) WEBSITE_ID="${2:-}"; shift 2 ;;
        --letsencrypt-email) LETSENCRYPT_EMAIL="${2:-}"; shift 2 ;;
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

PRIMARY_URL="https://${NEW_HOST}"

log "Change domain start | website_id=${WEBSITE_ID} | site_user=${SITE_USER} | site_root=${SITE_ROOT}"
log "Old host: ${OLD_HOST}"
log "New host: ${NEW_HOST}"

if [[ ! -d "${SITE_ROOT}" ]]; then
    log "ERROR: site root not found: ${SITE_ROOT}"
    exit 1
fi

if [[ ! -f "${SITE_ROOT}/docker-compose.yml" && ! -f "${SITE_ROOT}/compose.yml" ]]; then
    log "ERROR: docker compose file not found in ${SITE_ROOT}"
    exit 1
fi

cd "${SITE_ROOT}"

if [[ ! -f "${SITE_ROOT}/.env" ]]; then
    log "ERROR: missing .env at ${SITE_ROOT}/.env"
    exit 1
fi

set +u
source "${SITE_ROOT}/.env"
set -u

CONTAINER_CLI_NAME="${CONTAINER_CLI_NAME:-}"
CONTAINER_DB_NAME="${CONTAINER_DB_NAME:-}"

if [[ -z "${CONTAINER_CLI_NAME}" ]]; then
    log "ERROR: CONTAINER_CLI_NAME not set in .env"
    exit 1
fi

log "Bringing containers up..."
docker compose up -d --build

wait_for_db() {
    local tries=30
    local i=1

    if [[ -z "${CONTAINER_DB_NAME}" ]]; then
        log "DB container name not set (CONTAINER_DB_NAME). Skipping explicit db check, will rely on wp-cli retries."
        return 0
    fi

    while [[ $i -le $tries ]]; do

        if docker exec "${CONTAINER_DB_NAME}" sh -c 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
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
    docker exec "${CONTAINER_CLI_NAME}" wp "$@"
}

log "Waiting for DB..."
wait_for_db

log "Updating WP options..."
wp option update home "${PRIMARY_URL}"
wp option update siteurl "${PRIMARY_URL}"

log "Running WP search-replace passes (no permalinks changes)..."

OLD_WWW="https://www.${OLD_HOST}"
NEW_WWW="https://www.${NEW_HOST}"

OLD_HTTPS="https://${OLD_HOST}"
NEW_HTTPS="https://${NEW_HOST}"

wp search-replace "${OLD_WWW}" "${NEW_WWW}" --all-tables --precise --recurse-objects --skip-columns=guid
wp search-replace "${OLD_HTTPS}" "${NEW_HTTPS}" --all-tables --precise --recurse-objects --skip-columns=guid
wp search-replace "${OLD_HOST}" "${NEW_HOST}" --all-tables --precise --recurse-objects --skip-columns=guid

log "Restarting containers (to ensure env + app settle)..."
docker compose down
docker compose up -d --build

log "CHANGE_DOMAIN_COMPLETE | website_id=${WEBSITE_ID} | new=${NEW_HOST}"
echo "CHANGE_DOMAIN_COMPLETE"