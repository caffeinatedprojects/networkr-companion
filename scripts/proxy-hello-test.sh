#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

ok()   { echo -e "${GREEN}[✔] $*${RESET}"; }
fail() { echo -e "${RED}[✘] $*${RESET}"; }
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

cat > "$TEST_ROOT/docker-compose.yml" <<EOF
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
docker compose up -d
sleep 3

echo
echo "=== DNS CHECK ==="
SERVER_IP=$(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1)
DNS_IP=$(dig +short A "$DOMAIN" | head -n1)

echo "Domain A-record:    ${DNS_IP:-<none>}"
echo "Server IPv4:        $SERVER_IP"

if [[ "$DNS_IP" == "$SERVER_IP" ]]; then
  ok "Domain properly points to this server."
else
  fail "Domain does NOT point to this server."
fi

# ---------------------------------------
# RETRY LOGIC FOR HTTP/HTTPS
# ---------------------------------------

attempt() {
  local cmd="$1"
  local label="$2"
  local success_msg="$3"
  local fail_msg="$4"

  for i in {1..30}; do
    if eval "$cmd"; then
      ok "$success_msg"
      return 0
    fi
    sleep 3
  done

  fail "$fail_msg"
}

echo
echo "=== HTTP TEST ==="
attempt \
  "curl -s -I http://${DOMAIN} | grep -q -E '200|301'" \
  "HTTP" \
  "HTTP reachable" \
  "HTTP failed after retries"


echo
echo "=== HTTPS TEST ==="
attempt \
  "curl -s -I https://${DOMAIN} | grep -q -E '200|301'" \
  "HTTPS" \
  "HTTPS reachable" \
  "HTTPS failed after retries"


echo
echo "=== ROUTING TEST ==="
if docker exec proxy-web-auto curl -s "http://hello-test-${DOMAIN}" >/dev/null 2>&1; then
  ok "Proxy container can route to test container"
else
  fail "Proxy cannot reach backend container!"
fi

echo
echo "=== CERT CHECK ==="
if docker exec proxy-web-auto test -f "/etc/nginx/certs/${DOMAIN}.crt"; then
  ok "SSL certificate exists"
else
  warn "Certificate not present yet (may still be issuing)"
fi

echo
echo "==========================================="
echo " HELLO TEST DEPLOYED → https://${DOMAIN}"
echo "==========================================="

echo -e "${YELLOW}Cleanup test? (y/n)${RESET}"
read -r ANSWER

if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
  docker compose down
  rm -rf "$TEST_ROOT"
  ok "Cleanup complete."
else
  warn "Test left running at: $TEST_ROOT"
fi