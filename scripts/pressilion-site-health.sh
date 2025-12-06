#!/usr/bin/env bash
set -euo pipefail

SITE_USER="$1"

if [[ -z "${SITE_USER}" ]]; then
  echo "Usage: pressilion-site-health <user-site-xxx>"
  exit 1
fi

SITE_HOME="/home/${SITE_USER}"
ENV_FILE="${SITE_HOME}/.env"
COMPOSE_FILE="${SITE_HOME}/docker-compose.yml"

echo "========================================"
echo "   SITE HEALTH CHECK: ${SITE_USER}"
echo "========================================"

ok()   { echo -e "[✔] $1"; }
fail() { echo -e "[✘] $1"; }

# -------------------------------------------------------
# 1. Folder + env + compose existence
# -------------------------------------------------------
[[ -d "${SITE_HOME}" ]] && ok "Home folder exists" || fail "Home folder missing!"
[[ -f "${ENV_FILE}" ]] && ok ".env file exists" || fail ".env missing!"
[[ -f "${COMPOSE_FILE}" ]] && ok "docker-compose.yml exists" || fail "compose missing!"

# Load environment
set -a
source "${ENV_FILE}"
set +a

# -------------------------------------------------------
# 2. Container status
# -------------------------------------------------------
DB_CONT="${CONTAINER_DB_NAME}"
WP_CONT="${CONTAINER_SITE_NAME}"
CLI_CONT="${CONTAINER_CLI_NAME}"

docker ps --format '{{.Names}}' | grep -q "^${DB_CONT}$" && ok "DB container running" || fail "DB container NOT running"
docker ps --format '{{.Names}}' | grep -q "^${WP_CONT}$" && ok "WP container running" || fail "WP container NOT running"
docker ps --format '{{.Names}}' | grep -q "^${CLI_CONT}$" && ok "CLI container running" || fail "CLI container NOT running"

# -------------------------------------------------------
# 3. Verify WP container responds on port 9000
# -------------------------------------------------------
echo "GET /" | docker exec -i "${WP_CONT}" bash -c "timeout 2 nc -v localhost 9000" >/dev/null 2>&1 \
  && ok "PHP-FPM responding on port 9000" \
  || fail "PHP-FPM NOT responding (this causes 502 errors!)"

# -------------------------------------------------------
# 4. MySQL alive check
# -------------------------------------------------------
docker exec "${DB_CONT}" mysqladmin ping -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" >/dev/null 2>&1 \
  && ok "MySQL alive & accepting credentials" \
  || fail "MySQL not accepting credentials!"

# -------------------------------------------------------
# 5. WordPress installed check
# -------------------------------------------------------
docker exec "${CLI_CONT}" wp core is-installed --allow-root >/dev/null 2>&1 \
  && ok "WordPress core installed" \
  || fail "WordPress NOT installed yet"

# -------------------------------------------------------
# 6. Proxy routing check
# -------------------------------------------------------
UPSTREAM_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${WP_CONT}")

docker exec proxy-web-auto nginx -T | grep -q "${PRIMARY_DOMAIN}" \
  && ok "Domain present in Nginx config" \
  || fail "Domain NOT present in nginx conf!"

echo -n | nc -v "${UPSTREAM_IP}" 9000 >/dev/null 2>&1 \
  && ok "Proxy can reach upstream container" \
  || fail "Proxy cannot reach WP container!"

# -------------------------------------------------------
# 7. DNS resolution check
# -------------------------------------------------------
SERVER_IP=$(curl -s https://icanhazip.com || echo "unknown")

DOMAIN_IP=$(dig +short "${PRIMARY_DOMAIN}" | tail -n1)

if [[ "${SERVER_IP}" == "${DOMAIN_IP}" ]]; then
  ok "Domain resolves to correct server: ${SERVER_IP}"
else
  fail "DNS mismatch! Domain → ${DOMAIN_IP}, Server → ${SERVER_IP}"
fi

# -------------------------------------------------------
# 8. SSL certificate exists
# -------------------------------------------------------
docker exec proxy-web-auto ls /etc/nginx/certs | grep -q "${PRIMARY_DOMAIN}" \
  && ok "SSL certificate exists" \
  || fail "SSL certificate missing!"

echo "========================================"
echo " Health check complete."
echo "========================================"