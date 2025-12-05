#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG – tweak to taste
########################################

PRESSILION_USER="pressilion"

# Where this repo lives
NETWORKR_ROOT="/home/${PRESSILION_USER}/networkr-companion"

# Shared proxy stack (nginx-proxy-automation)
PROXY_ROOT="/home/${PRESSILION_USER}/docker-proxy"
PROXY_DATA_ROOT="/home/${PRESSILION_USER}/proxy-data"

# Let’s Encrypt email for the proxy
PROXY_LE_EMAIL="networkr@caffeinatedprojects.com"

# Git branch for networkr-companion
NETWORKR_BRANCH="main"

# Cron schedule to update networkr-companion
NETWORKR_UPDATE_CRON="0 3 * * *"   # daily 03:00

# SSH / firewall
SSH_PORT="22"

# Base Docker images to pre-pull
BASE_IMAGES=(
  "wordpress:php8.2-fpm"
  "wordpress:cli-php8.2"
  "mysql:8.0"
)

########################################
# Helpers
########################################

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

confirm_ubuntu() {
  if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    log "WARNING: This script is designed for Ubuntu. Continue anyway? (y/N)"
    read -r ans
    if [[ "${ans:-n}" != "y" && "${ans:-n}" != "Y" ]]; then
      exit 1
    fi
  fi
}

ensure_pressilion_user() {
  if ! id -u "${PRESSILION_USER}" >/dev/null 2>&1; then
    echo "User '${PRESSILION_USER}' does not exist. Please create it first." >&2
    exit 1
  fi
}

########################################
# System setup
########################################

set_timezone() {
  log "Setting timezone to Europe/London..."
  timedatectl set-timezone Europe/London || true
}

apt_update_upgrade() {
  log "Updating and upgrading packages..."
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

install_base_packages() {
  log "Installing base packages..."

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    ufw \
    fail2ban \
    unattended-upgrades \
    software-properties-common \
    zip \
    unzip \
    tar \
    gzip \
    bzip2 \
    rsync \
    wget \
    jq \
    htop \
    nano \
    vim \
    gettext-base \
    openssh-server
}

configure_unattended_upgrades() {
  log "Configuring unattended-upgrades..."
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
}

install_docker() {
  log "Installing Docker Engine and docker compose plugin..."

  if command -v docker &>/dev/null; then
    log "Docker already installed, skipping."
    return
  fi

  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable docker
  systemctl start docker
}

########################################
# Users / groups / ssh / firewall
########################################

setup_pressadmin_group() {
  log "Ensuring pressadmin group exists..."
  if ! getent group pressadmin >/dev/null; then
    groupadd pressadmin
  fi

  log "Adding ${PRESSILION_USER} to pressadmin and docker..."
  usermod -aG pressadmin,docker "${PRESSILION_USER}"
}

setup_passwordless_sudo() {
  log "Configuring passwordless sudo for ${PRESSILION_USER}..."
  local sudo_file="/etc/sudoers.d/99-${PRESSILION_USER}"
  echo "${PRESSILION_USER} ALL=(ALL) NOPASSWD:ALL" > "${sudo_file}"
  chmod 440 "${sudo_file}"
}

harden_ssh() {
  log "Hardening SSH config..."

  local conf="/etc/ssh/sshd_config"

  if [[ ! -f "${conf}.pressilion.bak" ]]; then
    cp "${conf}" "${conf}.pressilion.bak"
  fi

  sed -ri "s/^#?Port .*/Port ${SSH_PORT}/" "${conf}"
  sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin no/' "${conf}"
  sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' "${conf}"
  sed -ri 's/^#?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' "${conf}"
  sed -ri 's/^#?UsePAM .*/UsePAM yes/' "${conf}"
  sed -ri 's/^#?X11Forwarding .*/X11Forwarding no/' "${conf}"

  systemctl reload sshd
}

configure_firewall() {
  log "Configuring UFW firewall..."

  ufw default deny incoming || true
  ufw default allow outgoing || true

  ufw allow "${SSH_PORT}"/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true

  ufw --force enable || true
}

configure_fail2ban() {
  log "Configuring Fail2Ban sshd jail..."

  mkdir -p /etc/fail2ban/jail.d

  cat >/etc/fail2ban/jail.d/pressilion-sshd.conf <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
}

########################################
# Proxy stack (nginx-proxy-automation)
########################################

detect_ip_address() {
  local ip=""
  local interfaces=(eth0 ens3 ens4 enp0s3 enp1s0)

  for iface in "${interfaces[@]}"; do
    if ip address show "$iface" &>/dev/null; then
      ip=$(ip address show "$iface" | grep "inet\b" | head -n1 | awk '{print $2}' | cut -d/ -f1 || true)
      [[ -n "$ip" ]] && break
    fi
  done

  echo "$ip"
}

setup_proxy_stack() {
  log "Setting up nginx-proxy-automation stack..."

  mkdir -p "$(dirname "${PROXY_ROOT}")"

  if [[ ! -d "${PROXY_ROOT}/.git" ]]; then
    log "Cloning nginx-proxy-automation..."
    git clone --recurse-submodules https://github.com/evertramos/nginx-proxy-automation.git "${PROXY_ROOT}"
  else
    log "Updating nginx-proxy-automation..."
    cd "${PROXY_ROOT}"
    git fetch --all || true
    git reset --hard origin/main 2>/dev/null || git reset --hard origin/master 2>/dev/null || true
  fi

  cd "${PROXY_ROOT}"

  # Ensure data dir exists
  mkdir -p "${PROXY_DATA_ROOT}"

  # Copy .env if needed
  if [[ ! -f .env ]]; then
    if [[ -f .env.sample ]]; then
      cp .env.sample .env
    elif [[ -f .env.example ]]; then
      cp .env.example .env
    else
      touch .env
    fi
  fi

  local ip
  ip=$(detect_ip_address)
  if [[ -z "$ip" ]]; then
    log "Could not automatically detect public IP. fresh-start.sh will still run, but check config."
  fi

  log "Running fresh-start.sh for nginx-proxy-automation..."
  cd "${PROXY_ROOT}/bin"

  ./fresh-start.sh \
    --data-files-location="${PROXY_DATA_ROOT}" \
    --default-email="${PROXY_LE_EMAIL}" \
    --ip-address="${ip}" \
    --skip-docker-image-check \
    --use-nginx-conf-files \
    --update-nginx-template \
    --yes \
    --silent || log "fresh-start.sh completed with non-zero status, check proxy logs."

  cd -
}

########################################
# networkr-companion + scripts
########################################

setup_networkr_root() {
  log "Ensuring networkr-companion is under ${NETWORKR_ROOT}..."

  if [[ ! -d "${NETWORKR_ROOT}" ]]; then
    log "Expected networkr-companion at ${NETWORKR_ROOT}, but it does not exist."
    log "If you cloned it elsewhere, move or symlink it to ${NETWORKR_ROOT}."
    exit 1
  fi

  chown -R "${PRESSILION_USER}:pressadmin" "${NETWORKR_ROOT}"
}

install_networkr_update_cron() {
  log "Installing cron to update networkr-companion..."

  cat >/usr/local/bin/pressilion-networkr-update.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${NETWORKR_ROOT}"
BRANCH="${NETWORKR_BRANCH}"
LOG_DIR="/var/log/pressilion"

mkdir -p "\${LOG_DIR}"

if [[ ! -d "\${REPO_DIR}/.git" ]]; then
  echo "networkr-companion repo not found at \${REPO_DIR}" >> "\${LOG_DIR}/networkr-update.log"
  exit 0
fi

cd "\${REPO_DIR}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Updating networkr-companion..." >> "\${LOG_DIR}/networkr-update.log"
git fetch --all >> "\${LOG_DIR}/networkr-update.log" 2>&1 || true
git reset --hard "origin/\${BRANCH}" >> "\${LOG_DIR}/networkr-update.log" 2>&1 || true
EOF

  chmod +x /usr/local/bin/pressilion-networkr-update.sh

  cat >/etc/cron.d/pressilion-networkr-update <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${NETWORKR_UPDATE_CRON} root /usr/local/bin/pressilion-networkr-update.sh
EOF

  chmod 644 /etc/cron.d/pressilion-networkr-update
}

########################################
# Housekeeping / Docker images
########################################

prepull_base_images() {
  if [[ "${#BASE_IMAGES[@]}" -eq 0 ]]; then
    log "No base images configured to pre-pull."
    return
  fi

  log "Pre-pulling base Docker images..."
  for img in "${BASE_IMAGES[@]}"; do
    log "  -> docker pull ${img}"
    docker pull "${img}" || log "WARNING: Failed to pull ${img}"
  done
}

install_housekeeping_crons() {
  log "Installing housekeeping cronjobs..."

  mkdir -p /var/log/pressilion

  # Weekly docker prune
  cat >/etc/cron.d/pressilion-docker-prune <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 4 * * 0 root docker system prune -f > /var/log/pressilion/docker-prune.log 2>&1
EOF

  chmod 644 /etc/cron.d/pressilion-docker-prune

  # Weekly image refresh (proxy stack only – per-site images get pulled on demand)
  cat >/usr/local/bin/pressilion-image-refresh.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/pressilion"
PROXY_ROOT="/home/pressilion/docker-proxy"

mkdir -p "${LOG_DIR}"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_DIR}/image-refresh.log"
}

log "Starting image refresh..."

if [[ -d "${PROXY_ROOT}" ]]; then
  cd "${PROXY_ROOT}"
  if command -v docker &>/dev/null; then
    log "Running docker compose pull for proxy stack..."
    docker compose pull >> "${LOG_DIR}/image-refresh.log" 2>&1 || log "docker compose pull failed"
  fi
fi

log "Image refresh complete."
EOF

  chmod +x /usr/local/bin/pressilion-image-refresh.sh

  cat >/etc/cron.d/pressilion-image-refresh <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 3 * * 0 root /usr/local/bin/pressilion-image-refresh.sh
EOF

  chmod 644 /etc/cron.d/pressilion-image-refresh
}

########################################
# Install create-site script (if present)
########################################

install_create_site_script() {
  local src="${NETWORKR_ROOT}/Scripts/pressilion-create-site.sh"

  if [[ -f "${src}" ]]; then
    log "Installing pressilion-create-site helper..."
    install -m 0755 "${src}" /usr/local/bin/pressilion-create-site
  else
    log "pressilion-create-site.sh not found yet under ${NETWORKR_ROOT}/Scripts."
    log "Once you add it there, re-run this part or symlink manually."
  fi
}

########################################
# Summary
########################################

summary() {
  cat <<EOF

=====================================================
Pressilion snapshot base setup complete.
=====================================================

Included in this image:

  - User: ${PRESSILION_USER}
      - Passwordless sudo
      - Member of groups: pressadmin, docker
  - OS updated, unattended security upgrades enabled
  - Timezone: Europe/London
  - UFW firewall: ports ${SSH_PORT}, 80, 443 open
  - SSH hardened: no root login, no password auth
  - Fail2Ban sshd jail configured
  - Docker Engine & docker compose plugin installed
  - nginx-proxy-automation stack under:
      ${PROXY_ROOT}
    Data under:
      ${PROXY_DATA_ROOT}
  - networkr-companion under:
      ${NETWORKR_ROOT}
  - Housekeeping crons:
      /etc/cron.d/pressilion-docker-prune
      /etc/cron.d/pressilion-image-refresh
      /etc/cron.d/pressilion-networkr-update

You can now:

  - Do any final manual checks you want
  - Power off the server
  - Create a snapshot in your provider

Pressilion can then:

  - Create per-site users under /home/user-site-xxx
  - Use /usr/local/bin/pressilion-create-site (once installed)
  - Attach per-site stacks to the shared proxy
EOF
}

########################################
# MAIN
########################################

main() {
  require_root
  confirm_ubuntu
  ensure_pressilion_user

  set_timezone
  apt_update_upgrade
  install_base_packages
  configure_unattended_upgrades
  install_docker

  setup_pressadmin_group
  setup_passwordless_sudo
  harden_ssh
  configure_firewall
  configure_fail2ban

  setup_proxy_stack
  setup_networkr_root
  install_networkr_update_cron
  prepull_base_images
  install_housekeeping_crons
  install_create_site_script

  summary
}

main "$@"