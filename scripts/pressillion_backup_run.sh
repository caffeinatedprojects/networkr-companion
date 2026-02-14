#!/usr/bin/env bash
set -euo pipefail

BASE_HOST="${BASE_HOST:-app.pressillion.co.uk}"   # no https
BUCKET="${BUCKET:-caffeinated-media}"
SPACES_ENDPOINT="${SPACES_ENDPOINT:-https://ams3.digitaloceanspaces.com}"
AWS_RUN_AS_USER="${AWS_RUN_AS_USER:-networkr}"

# API notify (host env)
SERVER_UID="${SERVER_UID:-}"
API_SECRET="${API_SECRET:-}"
ENDPOINT_PATH="${ENDPOINT_PATH:-/api/v1/backups/complete}"

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
  echo "  --dry-run       Build archive but do not upload / notify"
  echo "  --keep-local    Do not delete local archive after upload"
  echo "  --force         Ignore DAILY_BACKUPS_ENABLED flag"
  echo ""
  echo "Host env (for notify):"
  echo "  SERVER_UID and API_SECRET (servers.api_secret) are required to notify the app"
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

aws_cp() {
  local src="$1"
  local dst="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-run enabled: upload skipped"
    return 0
  fi

  # If running as root, use networkr's AWS config/creds (where Spaces creds likely are)
  if [[ "$(id -u)" -eq 0 ]]; then
    if ! id -u "$AWS_RUN_AS_USER" >/dev/null 2>&1; then
      echo "AWS run-as user missing: ${AWS_RUN_AS_USER}"
      exit 1
    fi

    chmod 0644 "$src"
    sudo -u "$AWS_RUN_AS_USER" -H aws s3 cp "$src" "$dst" --endpoint-url "$SPACES_ENDPOINT"
    return $?
  fi

  aws s3 cp "$src" "$dst" --endpoint-url "$SPACES_ENDPOINT"
}

ensure_leading_slash() {
  local p="$1"
  if [[ "${p}" == /* ]]; then
    echo "$p"
  else
    echo "/$p"
  fi
}

notify_app() {
  local kind="$1"         # daily|weekly|snapshot
  local object_key="$2"
  local bytes="$3"
  local backup_at="$4"    # "YYYY-mm-dd HH:MM:SS"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-run enabled: notify skipped"
    return 0
  fi

  if [[ -z "$SERVER_UID" || -z "$API_SECRET" ]]; then
    echo "Missing SERVER_UID or API_SECRET in host env (needed to notify app)."
    echo "Example:"
    echo "  export SERVER_UID=\"551676231\""
    echo "  export API_SECRET=\"<servers.api_secret>\""
    return 1
  fi

  local endpoint_path
  endpoint_path="$(ensure_leading_slash "$ENDPOINT_PATH")"

  local base_url="https://${BASE_HOST}"
  local url="${base_url}${endpoint_path}"

  TS="$(date +%s)"
  export TS

  log "Notifying app: ${url}"

  # Build + sign exactly like the working test script
  PY_OUT="$(python3 - <<'PY'
import os, json, uuid, hashlib, hmac
from datetime import datetime, timezone

ts = int(os.environ["TS"])
secret = os.environ["API_SECRET"].encode("utf-8")

endpoint_path = os.environ.get("ENDPOINT_PATH", "/api/v1/backups/complete")
if not endpoint_path.startswith("/"):
    endpoint_path = "/" + endpoint_path

website_id = int(os.environ["WEBSITE_ID"])
linux_user = os.environ["LINUX_USER"]
kind = os.environ["KIND"]
storage_driver = "s3"
storage_bucket = os.environ["BUCKET"]
object_key = os.environ["OBJECT_KEY"]
bytes_ = int(os.environ["BYTES"])
backup_at = os.environ["BACKUP_AT"]

payload = {
  "website_id": website_id,
  "website_linux_user": linux_user,
  "kind": kind,
  "storage_driver": storage_driver,
  "storage_bucket": storage_bucket,
  "object_key": object_key,
  "bytes": bytes_,
  "backup_at": backup_at,
}

body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
body_sha = hashlib.sha256(body.encode("utf-8")).hexdigest()

nonce = str(uuid.uuid4())

canonical = "\n".join([
  str(ts),
  nonce,
  "POST",
  endpoint_path,
  body_sha,
])

sig = hmac.new(secret, canonical.encode("utf-8"), hashlib.sha256).hexdigest()

print(body)
print(body_sha)
print(nonce)
print(sig)
PY
)"

  BODY="$(printf "%s" "$PY_OUT" | sed -n '1p')"
  BODY_SHA="$(printf "%s" "$PY_OUT" | sed -n '2p')"
  NONCE="$(printf "%s" "$PY_OUT" | sed -n '3p')"
  SIG="$(printf "%s" "$PY_OUT" | sed -n '4p')"

  log "Notify headers: ts=${TS} nonce=${NONCE} body_sha=${BODY_SHA}"

  curl -sS -D /tmp/pressillion-notify-headers.txt -o /tmp/pressillion-notify-body.txt \
    -X POST "${url}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "X-Pressillion-Server: ${SERVER_UID}" \
    -H "X-Pressillion-Timestamp: ${TS}" \
    -H "X-Pressillion-Nonce: ${NONCE}" \
    -H "X-Pressillion-Signature: ${SIG}" \
    --data "${BODY}"

  HTTP_LINE="$(head -n1 /tmp/pressillion-notify-headers.txt || true)"
  log "Notify response: ${HTTP_LINE}"

  cat /tmp/pressillion-notify-body.txt
  echo ""
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

if [[ -z "${LINUX_USER}" ]]; then
  usage
  exit 1
fi

if [[ -z "${ENV_FILE}" ]]; then
  ENV_FILE="/home/${LINUX_USER}/.env"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

if [[ ! -d "/home/${LINUX_USER}" ]]; then
  echo "Linux user home not found: /home/${LINUX_USER}"
  exit 1
fi

# Load site env
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
BACKUP_AT="${HUMAN_TS}"

WORKDIR="/tmp/pressillion-${LINUX_USER}-${STAMP}"
ARCHIVE="${WORKDIR}/archive.tar.gz"

mkdir -p "$WORKDIR"

if [[ "$DO_SNAPSHOT" -eq 1 ]]; then
  KIND="snapshot"
  OBJECT_KEY="${BASE_HOST}/archive/snapshots/${TEAM_ID}/${LINUX_USER}/snapshot-${STAMP}.tar.gz"
else
  KIND="daily"
  OBJECT_KEY="${BASE_HOST}/archive/backups/${TEAM_ID}/${TEAM_ID}/${LINUX_USER}/backup-${STAMP}.tar.gz"
fi

log "Creating archive: $ARCHIVE"
log "Source: /home/${LINUX_USER} (data, docker-compose.yml, .env if present)"

TAR_ITEMS=( "data" "docker-compose.yml" )
if [[ -f "/home/${LINUX_USER}/.env" ]]; then
  TAR_ITEMS+=( ".env" )
fi

tar -czf "$ARCHIVE" \
  --warning=no-file-changed \
  --ignore-failed-read \
  -C "/home/${LINUX_USER}" "${TAR_ITEMS[@]}"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Archive was not created: $ARCHIVE"
  exit 1
fi

SIZE="$(file_size_bytes "$ARCHIVE")"
if [[ "$SIZE" -lt 1024 ]]; then
  echo "Archive looks too small (${SIZE} bytes) - refusing to upload"
  exit 1
fi

log "Uploading to Spaces:"
log "  endpoint: ${SPACES_ENDPOINT}"
log "  bucket:   s3://${BUCKET}"
log "  object:   ${OBJECT_KEY}"
log "  bytes:    ${SIZE}"

aws_cp "$ARCHIVE" "s3://${BUCKET}/${OBJECT_KEY}"

# Notify app (records backup row)
export WEBSITE_ID
export LINUX_USER
export KIND
export BUCKET
export ENDPOINT_PATH
export OBJECT_KEY
export BYTES="$SIZE"
export BACKUP_AT

notify_app "$KIND" "$OBJECT_KEY" "$SIZE" "$BACKUP_AT"

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
echo "Kind:       ${KIND}"
echo "Size:       ${SIZE} bytes"
echo "Path:       ${OBJECT_KEY}"