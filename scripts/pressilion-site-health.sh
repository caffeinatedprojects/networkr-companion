#!/usr/bin/env bash
set -euo pipefail

SITE_USER="$1"
SITE_HOME="/home/${SITE_USER}"
ENV_FILE="${SITE_HOME}/.env"
COMPOSE_FILE="${SITE_HOME}/docker-compose.yml"

echo "========================================"
echo "   SITE HEALTH CHECK: ${SITE_USER}"
echo "========================================"

# ----------------------------------------
# Basic checks
# ----------------------------------------

[[ -d "$SITE_HOME" ]] && echo "[✔] Home folder exists" || echo "[✘] Home folder missing"
[[ -f "$ENV_FILE" ]] && echo "[✔] .env file exists" || echo "[✘] .env missing"
[[ -f "$COMPOSE_FILE" ]] && echo "[✔] docker-compose.yml exists" || echo "[✘] docker-compose.yml missing"

# Extract container names
CONTAINER_WP=$(grep CONTAINER_SITE_NAME "$ENV_FILE" | cut -d '=' -f2)
CONTAINER_DB=$(grep CONTAINER_DB_NAME "$ENV_FILE" | cut -d '=' -f2)

# ----------------------------------------
# Container checks
# ----------------------------------------

docker ps --format '{{.Names}}' | grep -q "$CONTAINER_DB" \
  && echo "[✔] DB container running" || echo "[✘] DB container NOT running"

docker ps --format '{{.Names}}' | grep -q "$CONTAINER_WP" \
  && echo "[✔] WP container running" || echo "[✘] WP container NOT running"

docker ps --format '{{.Names}}' | grep -q "${SITE_USER}-cli" \
  && echo "[✔] CLI container running" || echo "[✘] CLI container NOT running"

# ----------------------------------------
# MySQL check
# ----------------------------------------
DB_NAME=$(grep MYSQL_DATABASE "$ENV_FILE" | cut -d '=' -f2)
DB_USER=$(grep MYSQL_USER "$ENV_FILE" | cut -d '=' -f2)
DB_PASS=$(grep MYSQL_PASSWORD "$ENV_FILE" | cut -d '=' -f2)

if docker exec "$CONTAINER_DB" mysql -u"$DB_USER" -p"$DB_PASS" -e "SHOW DATABASES;" >/dev/null 2>&1; then
  echo "[✔] MySQL alive & accepting credentials"
else
  echo "[✘] MySQL unreachable"
fi

# ----------------------------------------
# Apache check (port 80 inside container)
# ----------------------------------------
if docker exec "$CONTAINER_WP" curl -s -o /dev/null -w "%{http_code}" http://localhost | grep -q "200"; then
  echo "[✔] Apache responding"
else
  echo "[✘] Apache NOT responding"
fi

# ----------------------------------------
# Check if WordPress installed
# ----------------------------------------
if docker exec "$CONTAINER_WP" wp core is-installed --allow-root >/dev/null 2>&1; then
  echo "[✔] WordPress installed"
else
  echo "[✘] WordPress NOT installed"
fi

# ----------------------------------------
# DNS Check
# ----------------------------------------
DOMAIN=$(grep PRIMARY_DOMAIN "$ENV_FILE" | cut -d '=' -f2)

DNS_IP=$(dig +short A "$DOMAIN" | head -n1)
SERVER_IP=$(curl -s https://api.ipify.org)

if [[ "$DNS_IP" == "$SERVER_IP" ]]; then
  echo "[✔] DNS A record matches server IPv4 ($SERVER_IP)"
else
  echo "[✘] DNS mismatch — domain → $DNS_IP, server → $SERVER_IP"
fi

# ----------------------------------------
# Nginx upstream check
# ----------------------------------------
proxy_container="proxy-web-auto"

if docker exec "$proxy_container" curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN" | grep -q "200"; then
  echo "[✔] Proxy can reach WP container"
else
  echo "[✘] Proxy cannot reach WP container"
fi

# ----------------------------------------
# SSL Check
# ----------------------------------------
if docker exec proxy-web-auto test -f "/etc/nginx/certs/${DOMAIN}.crt"; then
  echo "[✔] SSL certificate exists"
else
  echo "[✘] SSL certificate missing"
fi

echo "========================================"
echo " Health check complete."
echo "========================================"