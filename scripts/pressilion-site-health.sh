#!/usr/bin/env bash
set -euo pipefail

SITEUSER="$1"
SITEROOT="/home/${SITEUSER}"
ENVFILE="${SITEROOT}/.env"
DCFILE="${SITEROOT}/docker-compose.yml"

WP_CONTAINER="${SITEUSER}-wp"
DB_CONTAINER="${SITEUSER}-db"
CLI_CONTAINER="${SITEUSER}-cli"

GREEN="✔"
RED="✘"
YELLOW="⚠"

print() {
  echo "[$1] $2"
}

echo "========================================"
echo "   SITE HEALTH CHECK: ${SITEUSER}"
echo "========================================"

# -------------------------------
# BASIC FILES
# -------------------------------
[[ -d "${SITEROOT}" ]] && print "$GREEN" "Home folder exists" || print "$RED" "Home folder missing"
[[ -f "${ENVFILE}" ]] && print "$GREEN" ".env file exists" || print "$RED" ".env missing"
[[ -f "${DCFILE}" ]] && print "$GREEN" "docker-compose.yml exists" || print "$RED" "docker-compose.yml missing"

# Load env vars for testing
if [[ -f "${ENVFILE}" ]]; then
  source "${ENVFILE}"
fi

# -------------------------------
# CONTAINER STATUS
# -------------------------------
docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$" \
  && print "$GREEN" "DB container running" \
  || print "$RED" "DB container NOT running"

docker ps --format '{{.Names}}' | grep -q "^${WP_CONTAINER}$" \
  && print "$GREEN" "WP container running" \
  || print "$RED" "WP container NOT running"

docker ps --format '{{.Names}}' | grep -q "^${CLI_CONTAINER}$" \
  && print "$GREEN" "CLI container running" \
  || print "$RED" "CLI container NOT running"

# -------------------------------
# MYSQL CHECK
# -------------------------------
if docker exec "${DB_CONTAINER}" mysqladmin ping -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --silent >/dev/null 2>&1; then
  print "$GREEN" "MySQL alive & accepting credentials"
else
  print "$RED" "MySQL NOT responding"
fi

# -------------------------------
# APACHE CHECK
# -------------------------------
APACHE_OK=0

if docker exec "${WP_CONTAINER}" pgrep apache2 >/dev/null 2>&1; then
  print "$GREEN" "Apache running"
  APACHE_OK=1
else
  print "$RED" "Apache NOT running"
fi

# Is Apache actually serving pages?
if docker exec "${WP_CONTAINER}" curl -fs http://localhost >/dev/null 2>&1; then
  print "$GREEN" "Apache serving HTTP normally"
else
  print "$RED" "Apache NOT serving HTTP"
fi

# -------------------------------
# WORDPRESS CHECK
# -------------------------------
if docker exec "${WP_CONTAINER}" curl -fs "http://localhost/wp-admin/install.php" >/dev/null 2>&1; then
  print "$YELLOW" "WordPress NOT installed (install.php still reachable)"
else
  print "$GREEN" "WordPress installed"
fi

# -------------------------------
# DNS CHECK (IPv4 only to avoid IPv6 false alarms)
# -------------------------------
SERVER_IPV4=$(curl -4 -s https://icanhazip.com || echo "UNKNOWN")
DOMAIN_IPV4=$(dig +short A "${PRIMARY_DOMAIN}" | head -n1)

if [[ "${SERVER_IPV4}" == "${DOMAIN_IPV4}" ]]; then
  print "$GREEN" "DNS A record matches server IPv4 (${SERVER_IPV4})"
else
  print "$RED" "DNS mismatch! Domain → ${DOMAIN_IPV4}, Server → ${SERVER_IPV4}"
fi

# -------------------------------
# PROXY → WP CONNECTIVITY
# -------------------------------
PROXY=$(docker ps --format '{{.Names}}' | grep '^proxy-web-auto$' || true)

if [[ -n "${PROXY}" ]]; then
  # Inspect generated nginx config to confirm server block exists
  if docker exec "${PROXY}" grep -q "${PRIMARY_DOMAIN}" /etc/nginx/conf.d/default.conf; then
    print "$GREEN" "Domain present in Nginx config"
  else
    print "$RED" "Domain NOT present in Nginx proxy config"
  fi

  # Test proxy reaching container
  WP_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${WP_CONTAINER}")

  if docker exec "${PROXY}" curl -fs "http://${WP_IP}" >/dev/null 2>&1; then
    print "$GREEN" "Proxy can reach WP container"
  else
    print "$RED" "Proxy cannot reach WP container"
  fi
else
  print "$RED" "Proxy container not found"
fi

# -------------------------------
# SSL CERT CHECK
# -------------------------------
CERT_PATH="/etc/nginx/certs/${PRIMARY_DOMAIN}.crt"

if docker exec proxy-web-auto bash -c "[ -f '${CERT_PATH}' ]" >/dev/null 2>&1; then
  print "$GREEN" "SSL certificate exists"
else
  print "$RED" "SSL certificate missing"
fi

echo "========================================"
echo " Health check complete."
echo "========================================"