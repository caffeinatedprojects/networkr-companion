#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------
# Reverse Proxy / SSL / Routing Hello-World Tester
# ---------------------------------------------------------
# Usage:
#   sudo bash proxy-hello-test.sh test.example.com email@example.com
#
# It will:
#   - Create ~/hello-test
#   - Deploy a simple nginx container behind nginx-proxy
#   - Issue SSL via ACME companion
#   - Test HTTP, HTTPS, and routing
#   - Print a diagnostics summary
#   - Optionally clean up afterwards
# ---------------------------------------------------------

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

fail() { echo -e "${RED}[✘] $*${RESET}"; }
ok()   { echo -e "${GREEN}[✔] $*${RESET}"; }
warn() { echo -e "${YELLOW}[!] $*${RESET}"; }

DOMAIN="${1:-}"
EMAIL="${2:-}"

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
  echo "Usage: sudo bash proxy-hello-test.sh <domain> <email>"
  exit 1
fi

TEST_ROOT="/home/networkr/hello-test-${DOMAIN}"
mkdir -p "$TEST_ROOT/html"

echo "<h1>Hello from ${DOMAIN}</h1>" > "$TEST_ROOT/html/index.html"

# -----------------------------
# Create docker-compose.yml
# -----------------------------
cat > "$TEST_ROOT/docker-compose.yml" <<EOF
version: "3.8"

services:
  hello-test:
    image: nginx:alpine
    container_name: hello-test-${DOMAIN}
    environment:
      VIRTUAL_HOST: ${DOMAIN}
      LETSENCRYPT_HOST: ${DOMAIN}
      LETSENCRYPT_EMAIL: ${EMAIL}
      VIRTUAL_PORT: 80
    networks:
      - proxy
    volumes:
      - ./html:/usr/share/nginx/html

networks:
  proxy:
    external: true
EOF

cd "$TEST_ROOT"

echo -e "${YELLOW}Bringing up test container...${RESET}"
docker compose up -d

sleep 3

# -----------------------------
# DNS Resolution Test
# -----------------------------
SERVER_IP=$(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1)
DNS_IP=$(dig +short A "$DOMAIN" | head -n1)

echo
echo "=== DNS CHECK ==="
echo "Domain A-record:    ${DNS_IP:-<none>}"
echo "Server IPv4:        $SERVER_IP"

if [[ -z "$DNS_IP" ]]; then
  fail "No A-record found!"
elif [[ "$DNS_IP" != "$SERVER_IP" ]]; then
  fail "Domain does NOT point to this server!"
else
  ok "Domain properly points to this server."
fi

# -----------------------------
# HTTP TEST (port 80)
# -----------------------------
echo
echo "=== HTTP TEST (port 80) ==="
if curl -s -I "http://${DOMAIN}" | grep -q "200 OK"; then
  ok "HTTP reachable"
else
  fail "HTTP not reachable"
fi

# -----------------------------
# HTTPS TEST (port 443)
# -----------------------------
echo
echo "=== HTTPS TEST (port 443) ==="
if curl -s -I "https://${DOMAIN}" | grep -q "200 OK"; then
  ok "HTTPS reachable"
else
  fail "HTTPS not reachable yet (ACME may still be issuing cert)"
fi

# -----------------------------
# PROXY ↔ CONTAINER ROUTING
# -----------------------------
echo
echo "=== PROXY ROUTING TEST ==="
if docker exec proxy-web-auto curl -s "http://hello-test-${DOMAIN}" >/dev/null 2>&1; then
  ok "Proxy container can route to hello-test container"
else
  fail "Proxy cannot reach container! Check proxy network."
fi

# -----------------------------
# CERTIFICATE TEST
# -----------------------------
echo
echo "=== SSL CERTIFICATE CHECK ==="
if docker exec proxy-web-auto test -f "/etc/nginx/certs/${DOMAIN}.crt"; then
  ok "SSL certificate exists"
else
  warn "Certificate not yet present (may take 30–90 seconds)"
fi

echo
echo "==========================================="
echo " HELLO TEST DEPLOYED: http://${DOMAIN}"
echo "==========================================="

# -----------------------------
# Cleanup prompt
# -----------------------------
echo -e "${YELLOW}Do you want to remove the test site now? (y/n)${RESET}"
read -r ANSWER
if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
  echo "Removing test container and files..."
  docker compose down
  rm -rf "$TEST_ROOT"
  ok "Cleanup complete."
else
  warn "Test site left running at: $TEST_ROOT"
fi