#!/usr/bin/env bash
set -euo pipefail

SITE_USER="$1"

if [[ -z "${SITE_USER}" ]]; then
  echo "Usage: pressilion-delete-site <user-site-xxx>"
  exit 1
fi

SITE_HOME="/home/${SITE_USER}"
COMPOSE_FILE="${SITE_HOME}/docker-compose.yml"

echo "[INFO] Deleting site: ${SITE_USER}"

if [[ -f "${COMPOSE_FILE}" ]]; then
  echo "[INFO] Stopping containers..."
  docker compose -f "${COMPOSE_FILE}" down --remove-orphans || true
fi

echo "[INFO] Removing linux user..."
deluser --remove-home "${SITE_USER}" || true
rm -rf "${SITE_HOME}" || true

echo "[INFO] Deleting wordpress-vpc network (if exists)..."
docker network rm "${SITE_USER}_wordpress-vpc" || true

echo "[DONE] Site ${SITE_USER} has been removed."