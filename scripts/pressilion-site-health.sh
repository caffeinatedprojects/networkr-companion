#!/bin/bash
set -e

SITEUSER="$1"

if [ -z "$SITEUSER" ]; then
    echo "Usage: $0 <siteuser>"
    exit 1
fi

SITEDIR="/home/$SITEUSER"
ENVFILE="$SITEDIR/.env"
COMPOSE="$SITEDIR/docker-compose.yml"

WP_CONTAINER="${SITEUSER}-wp"
DB_CONTAINER="${SITEUSER}-db"
CLI_CONTAINER="${SITEUSER}-cli"

echo "========================================"
echo "   SITE HEALTH CHECK: $SITEUSER"
echo "========================================"

# ---------------------------------------------------------
# BASIC FILE CHECKS
# ---------------------------------------------------------
[[ -d "$SITEDIR" ]] && echo "[✔] Home folder exists" || { echo "[✘] Home folder missing"; exit 1; }
[[ -f "$ENVFILE" ]] && echo "[✔] .env file exists" || echo "[✘] .env missing"
[[ -f "$COMPOSE" ]] && echo "[✔] docker-compose.yml exists" || echo "[✘] docker-compose.yml missing"

# ---------------------------------------------------------
# CONTAINER CHECKS
# ---------------------------------------------------------
docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$" \
  && echo "[✔] DB container running" \
  || echo "[✘] DB container NOT running"

docker ps --format '{{.Names}}' | grep -q "^${WP_CONTAINER}$" \
  && echo "[✔] WP container running" \
  || echo "[✘] WP container NOT running"

docker ps --format '{{.Names}}' | grep -q "^${CLI_CONTAINER}$" \
  && echo "[✔] CLI container running" \
  || echo "[✘] CLI container NOT running"

# ---------------------------------------------------------
# MYSQL CHECK
# ---------------------------------------------------------
if docker exec "$DB_CONTAINER" mysqladmin ping -uroot --password=$(grep MYSQL_ROOT_PASSWORD $ENVFILE | cut -d '=' -f2) >/dev/null 2>&1; then
    echo "[✔] MySQL alive & accepting credentials"
else
    echo "[✘] MySQL NOT responding"
fi

# ---------------------------------------------------------
# APACHE CHECKS (Apache listens on port 80)
# ---------------------------------------------------------
if docker exec "$WP_CONTAINER" pgrep apache2 >/dev/null 2>&1; then
    echo "[✔] Apache running"
else
    echo "[✘] Apache NOT running"
fi

# PORT 80 LISTEN SOCKET TEST
if docker exec "$WP_CONTAINER" bash -c "nc -z localhost 80" >/dev/null 2>&1; then
    echo "[✔] Apache listening on port 80"
else
    echo "[✘] Apache NOT listening on port 80 (may be false alarm)"
fi

# VERIFY APACHE SERVES CONTENT
if docker exec "$WP_CONTAINER" curl -fs http://localhost >/dev/null 2>&1; then
    echo "[✔] Apache serving HTTP normally"
else
    echo "[✘] Apache NOT serving HTTP correctly"
fi

# ---------------------------------------------------------
# WORDPRESS INSTALL STATUS
# ---------------------------------------------------------
if docker exec "$WP_CONTAINER" bash -c "[ -f /var/www/html/wp-config.php ]"; then
    echo "[✔] WordPress installed"
else
    echo "[✘] WordPress NOT installed"
fi

# ---------------------------------------------------------
# DNS CHECK
# ---------------------------------------------------------
DOMAIN=$(grep PRIMARY_DOMAIN "$ENVFILE" | cut -d '=' -f2)

SERVER_IPv4=$(curl -4 -s ifconfig.co)
DOMAIN_IP=$(dig +short A $DOMAIN)

if [[ "$DOMAIN_IP" == "$SERVER_IPv4" ]]; then
    echo "[✔] DNS A record matches server IPv4 ($SERVER_IPv4)"
else
    echo "[✘] DNS mismatch! Domain → $DOMAIN_IP, Server → $SERVER_IPv4"
fi

# ---------------------------------------------------------
# PROXY ROUTING TEST (Check that nginx-proxy can talk to container)
# ---------------------------------------------------------
PROXY_CONTAINER="proxy-web-auto"

if docker exec "$PROXY_CONTAINER" curl -fs "http://${WP_CONTAINER}:80" >/dev/null 2>&1; then
    echo "[✔] Proxy can reach WP container"
else
    echo "[✘] Proxy cannot reach WP container"
fi

# ---------------------------------------------------------
# SSL CHECK
# ---------------------------------------------------------
CERT_PATH="/etc/nginx/certs/${DOMAIN}.crt"

if docker exec "$PROXY_CONTAINER" bash -c "[ -f $CERT_PATH ]"; then
    echo "[✔] SSL certificate exists"
else
    echo "[✘] SSL certificate missing"
fi

echo "========================================"
echo " Health check complete."
echo "========================================"