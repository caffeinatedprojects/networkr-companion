#!/usr/bin/env bash
set -euo pipefail

# ========================================================================
#   Pressilion — Create Site Script (Apache version)
# ========================================================================

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; NC="\033[0m"
ts() { printf "[%s] " "$(date +%s)"; }

FORCE_INSTALL=false

# ------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) SITEUSER="$2"; shift;;
        --website-id) WEBSITE_ID="$2"; shift;;
        --domain) DOMAIN="$2"; shift;;
        --letsencrypt-email) LETSENCRYPT_EMAIL="$2"; shift;;
        --wp-admin-email) WP_ADMIN_MAIL="$2"; shift;;
        --force-install) FORCE_INSTALL=true;;
        *) echo "Unknown argument: $1"; exit 1;;
    esac
    shift
done

# Validate
[[ -z "${SITEUSER:-}" ]] && { echo "Missing --user"; exit 1; }
[[ -z "${WEBSITE_ID:-}" ]] && { echo "Missing --website-id"; exit 1; }
[[ -z "${DOMAIN:-}" ]] && { echo "Missing --domain"; exit 1; }
[[ -z "${LETSENCRYPT_EMAIL:-}" ]] && { echo "Missing --letsencrypt-email"; exit 1; }
[[ -z "${WP_ADMIN_MAIL:-}" ]] && { echo "Missing --wp-admin-email"; exit 1; }

HOMEDIR="/home/$SITEUSER"
TEMPLATES="/home/networkr/networkr-companion/templates"

DB_NAME="wp_${WEBSITE_ID}"
DB_USER="wp_${WEBSITE_ID}_u"
DB_PASS=$(openssl rand -hex 16)
DB_ROOT_PASS=$(openssl rand -hex 16)
WP_ADMIN_USER="admin"
WP_ADMIN_TEMP_PASS=$(openssl rand -hex 12)
COMPOSE_PROJECT_NAME="$SITEUSER"
CONTAINER_DB_NAME="${SITEUSER}-db"
CONTAINER_SITE_NAME="${SITEUSER}-wp"
CONTAINER_CLI_NAME="${SITEUSER}-cli"
DB_LOCAL_PORT=$((33060 + RANDOM % 200))

rollback() {
    echo -e "${YELLOW}Rolling back…${NC}"
    docker compose -f "$HOMEDIR/docker-compose.yml" down || true
    userdel -rf "$SITEUSER" || true
}
trap rollback ERR

# ========================================================================
# Create Linux user
# ========================================================================
ts; echo -e "Creating Linux user '${GREEN}${SITEUSER}${NC}'…"
id "$SITEUSER" >/dev/null 2>&1 || useradd -m "$SITEUSER"
echo "${SITEUSER}:$(openssl rand -hex 4)" | chpasswd

# ========================================================================
# Directory structure
# ========================================================================
ts; echo "Preparing directory structure…"

mkdir -p "$HOMEDIR"/data/db
mkdir -p "$HOMEDIR"/data/site
mkdir -p "$HOMEDIR"/conf.d

cp "$TEMPLATES/php.ini" "$HOMEDIR/conf.d/php.ini"

# ========================================================================
# Generate .env
# ========================================================================
ts; echo "Generating .env…"

export WEBSITE_ID COMPOSE_PROJECT_NAME DOMAIN PRIMARY_DOMAIN="$DOMAIN" \
PRIMARY_URL="https://$DOMAIN" URL_WITHOUT_HTTP="$DOMAIN" \
DOMAINS="$DOMAIN" LETSENCRYPT_EMAIL DB_ROOT_PASS DB_NAME DB_USER DB_PASS \
CONTAINER_DB_NAME CONTAINER_SITE_NAME CONTAINER_CLI_NAME \
SITEUSER WP_ADMIN_USER WP_ADMIN_TEMP_PASS WP_ADMIN_MAIL DB_LOCAL_PORT

envsubst < "$TEMPLATES/env.template" > "$HOMEDIR/.env"

# ========================================================================
# Copy docker-compose.yml
# ========================================================================
ts; echo "Copying docker-compose template…"
cp "$TEMPLATES/docker-compose.yml" "$HOMEDIR/docker-compose.yml"

# ========================================================================
# Start Docker stack
# ========================================================================
ts; echo "Starting Docker services…"
cd "$HOMEDIR"
docker compose up -d

# ========================================================================
# Wait for MySQL
# ========================================================================
ts; echo "Waiting for MySQL to become ready…"
for i in {1..60}; do
    if docker exec "$CONTAINER_DB_NAME" mysqladmin ping -p"$DB_ROOT_PASS" --silent &>/dev/null; then
        echo -e "${GREEN}MySQL Ready.${NC}"
        break
    fi
    sleep 2
    [[ $i -eq 60 ]] && { echo -e "${RED}MySQL failed to start.${NC}"; exit 1; }
done

# ========================================================================
# Create database user + database
# ========================================================================
ts; echo "Initialising database…"
docker exec "$CONTAINER_DB_NAME" mysql -uroot -p"$DB_ROOT_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
SQL

# ========================================================================
# Wait for Apache
# ========================================================================
ts; echo "Waiting for Apache inside container…"
for i in {1..40}; do
    if docker exec "$CONTAINER_SITE_NAME" curl -s localhost >/dev/null 2>&1; then
        echo -e "${GREEN}Apache Ready.${NC}"
        break
    fi
    sleep 2
    [[ $i -eq 40 ]] && { echo -e "${RED}Apache failed to respond.${NC}"; exit 1; }
done

# ========================================================================
# WordPress Auto Install
# ========================================================================
ts; echo "Checking if WordPress DB already contains tables…"

TABLE_COUNT=$(docker exec "$CONTAINER_DB_NAME" \
  sh -c "mysql -u'$DB_USER' -p'$DB_PASS' -N -B -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';\"")

if [[ "$TABLE_COUNT" -eq 0 || "$FORCE_INSTALL" = true ]]; then
    ts; echo -e "${YELLOW}Installing WordPress…${NC}"

    docker exec "$CONTAINER_CLI_NAME" wp core install \
        --url="https://$DOMAIN" \
        --title="$DOMAIN" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_password="$WP_ADMIN_TEMP_PASS" \
        --admin_email="$WP_ADMIN_MAIL" \
        --skip-email \
        --path=/var/www/html

else
    ts; echo -e "${GREEN}WordPress already installed — skipping.${NC}"
fi

# ========================================================================
# Success Output
# ========================================================================
echo "====================================================="
echo "Site Created Successfully"
echo "====================================================="
echo "Linux user:        $SITEUSER"
echo "Domain:            $DOMAIN"
echo "Admin Email:       $WP_ADMIN_MAIL"
echo "Admin Temp Pass:   $WP_ADMIN_TEMP_PASS"
echo "DB Name:           $DB_NAME"
echo "DB User:           $DB_USER"
echo "DB Pass:           $DB_PASS"
echo "SSH DB Tunnel:     ssh -L ${DB_LOCAL_PORT}:127.0.0.1:${DB_LOCAL_PORT} ${SITEUSER}@SERVER-IP"
echo "====================================================="

exit 0