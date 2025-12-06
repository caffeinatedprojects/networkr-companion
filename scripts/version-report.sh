#!/usr/bin/env bash
set -euo pipefail

GREEN="\e[32m"; NC="\e[0m"

echo -e "${GREEN}=== NETWORKR VERSION REPORT ===${NC}"

echo
echo "--- System ---"
lsb_release -a 2>/dev/null || cat /etc/os-release
uname -a

echo
echo "--- Docker ---"
docker --version
docker compose version

echo
echo "--- Proxy Containers ---"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -E "proxy|acme|gen" || echo "Proxy containers not running"

echo
echo "--- networkr-companion Git ---"
REPO="/home/networkr/networkr-companion"
if [[ -d "$REPO/.git" ]]; then
    cd "$REPO"
    git rev-parse HEAD
    git log -1 --pretty=format:"%h - %s (%cr)"
else
    echo "Companion repo not found."
fi

echo
echo "--- WP-CLI Version Check (if available) ---"
if docker ps | grep -q cli; then
    docker exec $(docker ps --format '{{.Names}}' | grep cli | head -n 1) wp --version 2>/dev/null || echo "WP-CLI container exists but wp is not ready"
else
    echo "No WP-CLI containers found."
fi

echo -e "${GREEN}=== END VERSION REPORT ===${NC}"