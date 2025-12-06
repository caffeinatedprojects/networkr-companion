#!/usr/bin/env bash
set -euo pipefail

LOG_ROOT="/var/log/networkr"

echo "=== NETWORKR LOG SUMMARY ==="

echo
echo "--- Bootstrap Logs ---"
ls -1t ${LOG_ROOT}/bootstrap-* 2>/dev/null | head -5 || echo "No bootstrap logs"

echo
echo "--- Daily Update Logs ---"
ls -1t ${LOG_ROOT}/update-* 2>/dev/null | head -5 || echo "No daily update logs"

echo
echo "--- Weekly Maintenance Logs ---"
ls -1t ${LOG_ROOT}/maintenance-* 2>/dev/null | head -5 || echo "No weekly maintenance logs"

echo
echo "--- Proxy Containers Logs (last 20 lines each) ---"

for C in proxy-web-auto docker-gen-auto acme-companion; do
  if docker ps --format '{{.Names}}' | grep -q "$C"; then
      echo "--- $C ---"
      docker logs "$C" 2>&1 | tail -20
  else
      echo "Container $C not found."
  fi
done

echo
echo "=== END SUMMARY ==="