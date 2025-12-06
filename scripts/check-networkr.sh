#!/usr/bin/env bash
set -euo pipefail

GREEN="\\e[32m"
RED="\\e[31m"
NC="\\e[0m"

check() {
    if eval "$1" >/dev/null 2>&1; then
        echo -e "[${GREEN}✓${NC}] $2"
    else
        echo -e "[${RED}✗${NC}] $2"
    fi
}

echo "=== NETWORKR SERVER CHECKLIST ==="

check "id networkr" "User 'networkr' exists"
check "groups networkr | grep -q docker" "'networkr' is in docker group"
check "docker ps" "Docker is running"
check "docker ps | grep -q proxy-web-auto" "Proxy Web container running"
check "docker ps | grep -q docker-gen-auto" "Proxy Docker-Gen running"
check "docker ps | grep -q acme" "ACME Companion running"
check "test -d /home/networkr/networkr-companion" "Companion repo exists"
check "test -f /etc/cron.daily/networkr-companion-update" "Daily cron installed"
check "test -f /etc/cron.weekly/networkr-docker-maintenance" "Weekly cron installed"
check "systemctl is-enabled networkr-companion-update.service" "Boot update service enabled"
check "grep -q '^PermitRootLogin no' /etc/ssh/sshd_config" "SSH root login disabled"
check "grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config" "SSH passwords disabled"
check "ufw status | grep -q '22/tcp'" "Firewall: SSH allowed"
check "ufw status | grep -q '80/tcp'" "Firewall: HTTP allowed"
check "ufw status | grep -q '443/tcp'" "Firewall: HTTPS allowed"

echo "=== DONE ==="