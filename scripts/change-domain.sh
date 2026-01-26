#!/usr/bin/env bash
set -euo pipefail

########################################
# Args
########################################
SITE_ROOT=""
SITE_USER=""
OLD_DOMAIN=""
NEW_DOMAIN=""
LETSENCRYPT_EMAIL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site-root) SITE_ROOT="${2:-}"; shift 2 ;;
        --site-user) SITE_USER="${2:-}"; shift 2 ;;
        --old) OLD_DOMAIN="${2:-}"; shift 2 ;;
        --new) NEW_DOMAIN="${2:-}"; shift 2 ;;
        --letsencrypt-email) LETSENCRYPT_EMAIL="${2:-}"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 2 ;;
    esac
done

if [[ -z "${SITE_ROOT}" || -z "${SITE_USER}" || -z "${OLD_DOMAIN}" || -z "${NEW_DOMAIN}" ]]; then
    echo "Usage: change-domain.sh --site-root /home/site --site-user site-user --old old.com --new new.com [--letsencrypt-email me@x.com]"
    exit 2
fi

ENV_FILE="${SITE_ROOT%/}/.env"

########################################
# Helpers
########################################
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

norm_host() {
    local v="$1"
    v="$(echo "$v" | tr '[:upper:]' '[:lower:]' | xargs)"
    v="${v#http://}"
    v="${v#https://}"
    v="${v%%/*}"
    echo "$v"
}

env_set() {
    local key="$1"
    local value="$2"

    if [[ ! -f "${ENV_FILE}" ]]; then
        touch "${ENV_FILE}"
    fi

    if grep -qE "^${key}=" "${ENV_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
    else
        echo "${key}=${value}" >> "${ENV_FILE}"
    fi
}

wait_for_wp_db() {
    local tries=30
    local i=1

    while [[ $i -le $tries ]]; do
        if docker exec "${CONTAINER_CLI_NAME}" wp db check --quiet >/dev/null 2>&1; then
            return 0
        fi

        log "DB not ready yet (try ${i}/${tries})"
        sleep 2
        i=$((i + 1))
    done

    return 1
}

########################################
# Main
########################################
OLD_DOMAIN="$(norm_host "${OLD_DOMAIN}")"
NEW_DOMAIN="$(norm_host "${NEW_DOMAIN}")"

if [[ ! -f "${ENV_FILE}" ]]; then
    log "ERROR: missing env file: ${ENV_FILE}"
    exit 4
fi

log "Loading env: ${ENV_FILE}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if [[ -z "${CONTAINER_CLI_NAME:-}" ]]; then
    log "ERROR: CONTAINER_CLI_NAME missing in ${ENV_FILE}"
    exit 5
fi

log "Updating .env domain keys"
env_set "PRIMARY_DOMAIN" "${NEW_DOMAIN}"
env_set "PRIMARY_URL" "https://${NEW_DOMAIN}"
env_set "URL_WITHOUT_HTTP" "${NEW_DOMAIN}"
env_set "DOMAINS" "${NEW_DOMAIN},www.${NEW_DOMAIN}"

if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
    env_set "LETSENCRYPT_EMAIL" "${LETSENCRYPT_EMAIL}"
fi

log ".env updated"

log "Bringing stack up (build if needed)"
cd "${SITE_ROOT}" && docker compose up -d --build

log "Waiting for WordPress DB readiness"
if ! wait_for_wp_db; then
    log "ERROR: DB never became ready"
    exit 10
fi

log "Updating WP options home + siteurl"
docker exec "${CONTAINER_CLI_NAME}" wp option update home "https://${NEW_DOMAIN}"
docker exec "${CONTAINER_CLI_NAME}" wp option update siteurl "https://${NEW_DOMAIN}"

log "Running robust wp search-replace (no permalinks changes)"
docker exec "${CONTAINER_CLI_NAME}" wp search-replace "https://www.${OLD_DOMAIN}" "https://www.${NEW_DOMAIN}" --all-tables --precise --recurse-objects --skip-columns=guid
docker exec "${CONTAINER_CLI_NAME}" wp search-replace "https://${OLD_DOMAIN}" "https://${NEW_DOMAIN}" --all-tables --precise --recurse-objects --skip-columns=guid
docker exec "${CONTAINER_CLI_NAME}" wp search-replace "${OLD_DOMAIN}" "${NEW_DOMAIN}" --all-tables --precise --recurse-objects --skip-columns=guid

log "Restarting stack to ensure env is reloaded"
cd "${SITE_ROOT}" && docker compose down
cd "${SITE_ROOT}" && docker compose up -d --build

log "Attempting central proxy restart (best-effort)"
PROXY_ROOT="/home/networkr/docker-proxy"
PROXY_COMPOSE="${PROXY_ROOT}/docker-compose.yml"

if [[ -f "${PROXY_COMPOSE}" ]]; then
    cd "${PROXY_ROOT}" && docker compose down && docker compose up -d
    log "Proxy restarted via docker compose: ${PROXY_ROOT}"
else
    if docker ps --format '{{.Names}}' | grep -q '^nginx-proxy$'; then docker restart nginx-proxy || true; fi
    if docker ps --format '{{.Names}}' | grep -q '^nginx-proxy-acme$'; then docker restart nginx-proxy-acme || true; fi
    if docker ps --format '{{.Names}}' | grep -q '^nginx-proxy-automation$'; then docker restart nginx-proxy-automation || true; fi
    log "Proxy restart fallback attempted"
fi

echo "CHANGE_DOMAIN_COMPLETE"
echo "changedomain complete"