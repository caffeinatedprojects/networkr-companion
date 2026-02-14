#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Required:
#   --linux-user
#   --env-file
#
# Uses existing env vars inside site env:
#   WEBSITE_ID
#   TEAM_ID
#   DAILY_BACKUPS_ENABLED
#
# No new identity variables.
# ------------------------------------------------------------------

BASE_HOST="${BASE_HOST:-app.pressillion.co.uk}"   # no https (kept for future use; not required today)
BUCKET="${BUCKET:-caffeinated-media}"
SPACES_ENDPOINT="${SPACES_ENDPOINT:-https://ams3.digitaloceanspaces.com}"

LINUX_USER=""
ENV_FILE=""
DO_SNAPSHOT=0
DRY_RUN=0
KEEP_LOCAL=0
FORCE=0

usage() {
  echo "Usage:"
  echo "  $0 --linux-user <linux-user> [--env-file /home/<linux-user>/.env] [--snapshot] [--dry-run] [--keep-local] [--force]"
  echo ""
  echo "Options:"
  echo "  --linux-user    Linux user that owns the site (required)"
  echo "  --env-file      Path to site .env (defaults to /home/<linux-user>/.env)"
  echo "  --snapshot      Create snapshot (runs even if daily backups disabled)"
  echo "  --dry-run       Build archive but do not upload"
  echo "  --keep-local    Do not delete local archive after upload"
  echo "  --force         Ignore DAILY_BACKUPS_ENABLED flag"
}

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

file_size_bytes() {
  local f="$1"
  if command -v stat >/dev/null 2>&1; then
    if stat -c%s "$f" >/dev/null 2>&1; then
      stat -c%s "$f"
      return 0
    fi
    if stat -f%z "$f" >/dev/null 2>&1; then
      stat -f%z "$f"
      return 0
    fi
  fi
  wc -c < "$f" | tr -d ' '
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --snapshot) DO_SNAPSHOT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keep-local) KEEP_LOCAL=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$LINUX_USER" || -z "$ENV_FILE" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

# Load site env (expects a simple KEY=VALUE file)
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${WEBSITE_ID:-}" ]]; then
  echo "WEBSITE_ID missing in env: $ENV_FILE"
  exit 1
fi

if [[ -z "${TEAM_ID:-}" ]]; then
  echo "TEAM_ID missing in env: $ENV_FILE"
  exit 1
fi

if [[ "$DO_SNAPSHOT" -eq 0 && "${DAILY_BACKUPS_ENABLED:-0}" != "1" && "$FORCE" -ne 1 ]]; then
  log "Daily backups disabled (DAILY_BACKUPS_ENABLED=${DAILY_BACKUPS_ENABLED:-0}). Use --force to override."
  exit 0
fi

STAMP="$(date -u '+%Y%m%d-%H%M%S')"
HUMAN_TS="$(date -u '+%Y-%m-%d %H:%M:%S')"

WORKDIR="/tmp/pressillion-${LINUX_USER}-${STAMP}"
ARCHIVE="${WORKDIR}/archive.tar.gz"

mkdir -p "$WORKDIR"

if [[ ! -d "/home/${LINUX_USER}" ]]; then
  echo "Linux user home not found: /home/${LINUX_USER}"
  exit 1
fi

if [[ "$DO_SNAPSHOT" -eq 1 ]]; then
  OBJECT_KEY="archive/snapshots/${TEAM_ID}/${LINUX_USER}/snapshot-${STAMP}.tar.gz"
else
  OBJECT_KEY="archive/backups/${TEAM_ID}/${TEAM_ID}/${LINUX_USER}/backup-${STAMP}.tar.gz"
fi

log "Creating archive: $ARCHIVE"
log "Source: /home/${LINUX_USER} (data, docker-compose.yml, .env if present)"

# Create archive.
# - include .env only if present
# - tar warnings shouldn't fail the whole run
TAR_ITEMS=( "data" "docker-compose.yml" )
if [[ -f "/home/${LINUX_USER}/.env" ]]; then
  TAR_ITEMS+=( ".env" )
fi

set +e
tar -czf "$ARCHIVE" -C "/home/${LINUX_USER}" "${TAR_ITEMS[@]}"
TAR_RC=$?
set -e

if [[ "$TAR_RC" -ne 0 ]]; then
  echo "tar failed (exit ${TAR_RC})"
  exit 1
fi

SIZE="$(file_size_bytes "$ARCHIVE")"

log "Uploading to Spaces:"
log "  endpoint: ${SPACES_ENDPOINT}"
log "  bucket:   s3://${BUCKET}"
log "  object:   ${OBJECT_KEY}"
log "  bytes:    ${SIZE}"

if [[ "$DRY_RUN" -eq 0 ]]; then
  aws s3 cp "$ARCHIVE" \
    "s3://${BUCKET}/${OBJECT_KEY}" \
    --endpoint-url "$SPACES_ENDPOINT"
else
  log "Dry-run enabled: upload skipped"
fi

if [[ "$KEEP_LOCAL" -ne 1 ]]; then
  rm -rf "$WORKDIR"
else
  log "Keeping local workdir: $WORKDIR"
fi

echo ""
log "Backup complete"
echo "Timestamp:  ${HUMAN_TS} (UTC)"
echo "Website ID: ${WEBSITE_ID}"
echo "Team ID:    ${TEAM_ID}"
echo "Linux User: ${LINUX_USER}"
echo "Size:       ${SIZE} bytes"
echo "Path:       ${OBJECT_KEY}"