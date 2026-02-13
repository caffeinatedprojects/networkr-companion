#!/bin/bash
set -e

CREATE_SUDO=0
SUDO_USER=""
SUDO_PASS=""
API_SECRET=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --create-sudo-user)
      CREATE_SUDO="$2"
      shift 2
      ;;
    --sudo-user)
      SUDO_USER="$2"
      shift 2
      ;;
    --sudo-pass)
      SUDO_PASS="$2"
      shift 2
      ;;
    --api-secret)
      API_SECRET="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

cd /home/networkr/networkr-companion
git pull

docker pull wordpress:latest
docker pull wordpress:cli
docker pull mariadb:latest

# Write / update env file
ENV_FILE="/home/networkr/networkr-companion/.env"

if [ ! -f "$ENV_FILE" ]; then
  touch "$ENV_FILE"
fi

if grep -q "^PRESSILLION_API_SECRET=" "$ENV_FILE"; then
  sed -i "s|^PRESSILLION_API_SECRET=.*|PRESSILLION_API_SECRET=${API_SECRET}|" "$ENV_FILE"
else
  echo "PRESSILLION_API_SECRET=${API_SECRET}" >> "$ENV_FILE"
fi

if [ "$CREATE_SUDO" = "1" ]; then
  bash /home/networkr/networkr-companion/scripts/create_sudo_user.sh \
    --user "$SUDO_USER" \
    --password "$SUDO_PASS"
fi

echo '{"status":"success"}'