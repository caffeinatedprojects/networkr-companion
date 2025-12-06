#!/usr/bin/env bash
set -e

SITEUSER="$1"
HOMEDIR="/home/$SITEUSER"
COMPOSE="$HOMEDIR/docker-compose.yml"

echo "========================================"
echo "   SITE HEALTH CHECK: $SITEUSER"
echo "========================================"

# --- Basic file checks ---
[ -d "$HOMEDIR" ] && echo "[✔] Home folder exists" || echo "[✘] Home folder missing"
[ -f "$HOMEDIR/.env" ] && echo "[✔] .env file exists" || echo "[✘] .env missing"
[ -f "$COMPOSE" ] && echo "[✔] docker-compose.yml exists" || echo "[✘] docker-compose.yml missing"

# --- Container checks ---
DB_CONTAINER="${SITEUSER}-db"
WP_CONTAINER="${SITEUSER}-wp"
CLI_CONTAINER="${SITEUSER}-cli"

docker ps --format '{{.Names}}' | grep -q "$DB_CONTAINER" \
  && echo "[✔] DB container running" \
  || echo "[✘] DB container NOT running"

docker ps --format '{{.Names}}' | grep -q "$WP_CONTAINER" \
  && echo "[✔] WP container running" \
  || echo "[✘] WP container NOT running"

docker ps --format '{{.Names}}' | grep -q "$CLI_CONTAINER" \
  && echo "[✔] CLI container running" \
  || echo "[✘] CLI container NOT running"

# --- Apache check ---
if docker exec "$WP_CONTAINER" ps aux | grep -q "[a]pache2"; then
    echo "[✔] Apache running"
else
    echo "[✘] Apache NOT running"
fi

# --- Port 80 check ---
if docker exec "$WP_CONTAINER" ss -tulpn 2>/dev/null | grep -q ":80"; then
    echo "[✔] Apache listening on port 80"
else
    echo "[✘] Apache NOT listening on port 80"
fi

# --- WordPress response check ---
if docker exec "$WP_CONTAINER" curl -fs http://localhost >/dev/null 2>&1; then
    echo "[✔] WordPress responding in container"
else
    echo "[✘] WordPress NOT responding inside container"
fi

# --- DB check ---
if docker exec "$DB_CONTAINER" mysqladmin ping -h localhost --silent; then
    echo "[✔] MySQL alive & accepting credentials"
else
    echo "[✘] MySQL NOT responding"
fi

# --- WP install check ---
if docker exec "$WP_CONTAINER" test -f /var/www/html/wp-config.php; then
    echo "[✔] WordPress installed"
else
    echo "[✘] WordPress NOT installed yet"
fi

# --- DNS vs server ---
DOMAIN=$(grep PRIMARY_DOMAIN "$HOMEDIR/.env" | cut -d= -f2)
DNS_IP=$(dig +short A "$DOMAIN")
SERVER_IP=$(curl -4 -s ifconfig.me)

if [[ "$DNS_IP" == "$SERVER_IP" ]]; then
    echo "[✔] DNS A record matches server IPv4 ($SERVER_IP)"
else
    echo "[✘] DNS mismatch! DNS=$DNS_IP Server=$SERVER_IP"
fi

# --- Proxy connectivity ---
PROXY="proxy-web-auto"

if docker exec "$PROXY" curl -fs "http://$DOMAIN" >/dev/null 2>&1; then
    echo "[✔] Proxy can reach WP container"
else
    echo "[✘] Proxy cannot reach WP container"
fi

# --- SSL cert ---
CERT="/etc/nginx/certs/$DOMAIN.crt"
if docker exec "$PROXY" test -f "$CERT"; then
    echo "[✔] SSL certificate exists"
else
    echo "[✘] SSL certificate NOT found"
fi

echo "========================================"
echo " Health check complete."
echo "========================================"