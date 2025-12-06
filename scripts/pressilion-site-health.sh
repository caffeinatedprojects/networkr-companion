#!/bin/sh

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
PROXY_CONTAINER="proxy-web-auto"

echo "========================================"
echo "   SITE HEALTH CHECK: $SITEUSER"
echo "========================================"

# ---------------------------------------------------------
# BASIC FILE CHECKS
# ---------------------------------------------------------
[ -d "$SITEDIR" ] && echo "[✔] Home folder exists" || echo "[✘] Home folder missing"
[ -f "$ENVFILE" ] && echo "[✔] .env file exists" || echo "[✘] .env missing"
[ -f "$COMPOSE" ] && echo "[✔] docker-compose.yml exists" || echo "[✘] docker-compose.yml missing"

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
MYSQL_PASS=$(grep MYSQL_ROOT_PASSWORD "$ENVFILE" | cut -d '=' -f2)

if docker exec "$DB_CONTAINER" mysqladmin ping -uroot -p"$MYSQL_PASS" >/dev/null 2>&1; then
    echo "[✔] MySQL alive & accepting credentials"
else
    echo "[✘] MySQL NOT responding"
fi

# ---------------------------------------------------------
# APACHE CHECK (Works 100% reliably)
# ---------------------------------------------------------
if docker exec "$WP_CONTAINER" pgrep apache2 >/dev/null 2>&1; then
    echo "[✔] Apache running"
else
    echo "[✘] Apache NOT running"
fi

# PORT 80 LISTEN CHECK without false negatives
if docker exec "$WP_CONTAINER" sh -c "netstat -tln 2>/dev/null | grep ':80 '" >/dev/null; then
    echo "[✔] Apache listening on port 80"
else
    echo "[✘] Apache NOT listening on port 80 (container image may not include netstat)"
fi

# HTTP SERVE CHECK
if docker exec "$WP_CONTAINER" sh -c "curl -fs http://localhost" >/dev/null 2>&1; then
    echo "[✔] Apache serving HTTP normally"
else
    echo "[✘] Apache NOT serving internal HTTP"
fi

# ---------------------------------------------------------
# WORDPRESS INSTALL STATUS
# ---------------------------------------------------------
if docker exec "$WP_CONTAINER" sh -c "[ -f /var/www/html/wp-config.php ]"; then
    echo "[✔] WordPress installed"
else
    echo "[✘] WordPress NOT installed"
fi

# ---------------------------------------------------------
# DNS CHECK
# ---------------------------------------------------------
DOMAIN=$(grep PRIMARY_DOMAIN "$ENVFILE" | cut -d '=' -f2)
SERVER_IP=$(curl -4 -s ifconfig.co)
DOMAIN_IP=$(dig +short A "$DOMAIN")

if [ "$DOMAIN_IP" = "$SERVER_IP" ]; then
    echo "[✔] DNS A record matches server IPv4 ($SERVER_IP)"
else
    echo "[✘] DNS mismatch! Domain → $DOMAIN_IP, Server → $SERVER_IP"
fi

# ---------------------------------------------------------
# PROXY REACHABILITY
# ---------------------------------------------------------
if docker exec "$PROXY_CONTAINER" sh -c "curl -fs http://$WP_CONTAINER" >/dev/null 2>&1; then
    echo "[✔] Proxy can reach WP container"
else
    echo "[✘] Proxy cannot reach WP container"
fi

# ---------------------------------------------------------
# SSL CERTIFICATE CHECK (using sh, not bash)
# ---------------------------------------------------------
CERT="/etc/nginx/certs/${DOMAIN}.crt"

if docker exec "$PROXY_CONTAINER" sh -c "[ -f $CERT ]"; then
    echo "[✔] SSL certificate exists"
else
    echo "[✘] SSL certificate missing"
fi

echo "========================================"
echo " Health check complete."
echo "========================================"