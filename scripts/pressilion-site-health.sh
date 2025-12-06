#!/usr/bin/env bash
set -euo pipefail

SITE="$1"
if [[ -z "$SITE" ]]; then
  echo "Usage: pressilion-site-health.sh <site-user>"
  exit 1
fi

SITE_HOME="/home/${SITE}"
ENV_FILE="${SITE_HOME}/.env"
COMPOSE_YML="${SITE_HOME}/docker-compose.yml"

echo "========================================"
echo "   SITE HEALTH CHECK: ${SITE}"
echo "========================================"

# Helpers
ok()   { echo -e "[✔] $*"; }
fail() { echo -e "[✘] $*"; }

# ----------------------------
# BASIC FILE & FOLDER CHECKS
# ----------------------------

[[ -d "${SITE_HOME}" ]] && ok "Home folder exists" || fail "Home folder missing"
[[ -f "${ENV_FILE}" ]] && ok ".env file exists" || fail ".env file missing"
[[ -f "${COMPOSE_YML}" ]] && ok "docker-compose.yml exists" || fail "docker-compose.yml missing"

# Load env
# shellcheck disable=SC1090
source "${ENV_FILE}"

# ----------------------------
# DOCKER CONTAINER STATUS
# ----------------------------

DB_STATUS=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_DB_NAME}" 2>/dev/null || echo "false")
WP_STATUS=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_SITE_NAME}" 2>/dev/null || echo "false")
CLI_STATUS=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_CLI_NAME}" 2>/dev/null || echo "false")

[[ "${DB_STATUS}" == "true" ]] && ok "DB container running" || fail "DB container NOT running"
[[ "${WP_STATUS}" == "true" ]] && ok "WP container running" || fail "WP container NOT running"
[[ "${CLI_STATUS}" == "true" ]] && ok "CLI container running" || fail "CLI container NOT running"

# ----------------------------
# PHP-FPM TEST (internal)
# ----------------------------
if docker exec "${CONTAINER_SITE_NAME}" bash -c 'echo -e "GET /health.php HTTP/1.1\r\n\r\n" >/dev/tcp/127.0.0.1/9000' 2>/dev/null; then
  ok "PHP-FPM responding"
else
  fail "PHP-FPM NOT responding"
fi

# ----------------------------
# MYSQL TEST
# ----------------------------
if docker exec "${CONTAINER_DB_NAME}" \
   mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" -e "SELECT 1;" >/dev/null 2>&1; then
  ok "MySQL alive & accepting credentials"
else
  fail "MySQL connection failed"
fi

# ----------------------------
# WORDPRESS INSTALLED?
# ----------------------------
if docker exec "${CONTAINER_SITE_NAME}" test -f /var/www/html/wp-config.php; then
  ok "WordPress installed"
else
  fail "WordPress NOT installed yet"
fi

# ----------------------------
# NGINX-PROXY DETECTION
# ----------------------------
# Extract server IP (IPv4 only)
SERVER_IPv4=$(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1)

# Query DNS A record
DNS_IPv4=$(dig +short A "${PRIMARY_DOMAIN}" | head -n1)

if [[ -n "${DNS_IPv4}" ]]; then
  [[ "${DNS_IPv4}" == "${SERVER_IPv4}" ]] \
    && ok "DNS A record matches server IPv4 (${DNS_IPv4})" \
    || fail "DNS mismatch: Domain → ${DNS_IPv4}, Server → ${SERVER_IPv4}"
else
  fail "No A record found for domain"
fi

# Check domain present in nginx config
if docker exec proxy-web-auto grep -q "${PRIMARY_DOMAIN}" /etc/nginx/conf.d/default.conf; then
  ok "Domain present in Nginx config"
else
  fail "Domain missing from Nginx config"
fi

# Check proxy → WP reachability
if docker exec proxy-web-auto curl -s "http://${CONTAINER_SITE_NAME}:9000" >/dev/null 2>&1 ; then
  ok "Proxy can reach WP container"
else
  fail "Proxy cannot reach WP container"
fi

# Check SSL cert presence
if docker exec proxy-web-auto test -f "/etc/nginx/certs/${PRIMARY_DOMAIN}.crt"; then
  ok "SSL certificate exists"
else
  fail "SSL certificate missing"
fi

echo "========================================"
echo " Health check complete."
echo "========================================"