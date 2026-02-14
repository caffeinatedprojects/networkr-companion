#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Required args:
#   --linux-user <linux-user>
#
# Optional:
#   --env-file /home/<linux-user>/.env
#   --snapshot
#   --dry-run
#   --keep-local
#   --force
#
# Reads from site env (no renames):
#   WEBSITE_ID
#   TEAM_ID
#   DAILY_BACKUPS_ENABLED
#
# Host-level env required for API notify (not stored per-site):
#   SERVER_UID   (matches servers.uid)
#   API_SECRET   (matches servers.api_secret)
#
# Optional host-level env:
#   BASE_HOST=app.pressillion.co.uk   (no https)
#   API_PATH=/api/v1/backups/complete
#   BUCKET=caffeinated-media
#   SPACES_ENDPOINT=https://ams3.digitaloceanspaces.com
#   AWS_RUN_AS_USER=networkr
# ------------------------------------------------------------------

BASE_HOST="${BASE_HOST:-app.pressillion.co.uk}"          # no https
API_PATH="${API_PATH:-/api/v1/backups/complete}"         # leading slash enforced below
BUCKET="${BUCKET:-caffeinated-media}"
SPACES_ENDPOINT="${SPACES_ENDPOINT:-https://ams3.digitaloceanspaces.com}"
AWS_RUN_AS_USER="${AWS_RUN_AS_USER:-networkr}"

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
  echo "  --dry-run       Build archive but do not upload or notify API"
  echo "  --keep-local    Do not delete local archive after upload"
  echo "  --force         Ignore DAILY_BACKUPS_ENABLED flag"
  echo ""
  echo "Host env needed to notify app:"
  echo "  SERVER_UID      Server uid as stored in Pressillion servers table"
  echo "  API_SECRET      Server api_secret as stored in Pressillion servers table"
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
  if [[ "${p:0:1}" != "/" ]]; then
    echo "/${p}"
  else
    echo "${p}"
  fi
}

# ------------------------------------------------------------------
# Args
# ------------------------------------------------------------------
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

API_PATH="$(ensure_leading_slash "$API_PATH")"

# ------------------------------------------------------------------
# Load site env
# ------------------------------------------------------------------
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

# ------------------------------------------------------------------
# Naming + paths
# ------------------------------------------------------------------
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
HUMAN_TS="$(date -u '+%Y-%m-%d %H:%M:%S')"
BACKUP_AT="${HUMAN_TS}" # matches your API validator "date" format

WORKDIR="/tmp/pressillion-${LINUX_USER}-${STAMP}"
ARCHIVE="${WORKDIR}/archive.tar.gz"
mkdir -p "$WORKDIR"

if [[ "$DO_SNAPSHOT" -eq 1 ]]; then
  KIND="snapshot"
  SPACES_KEY="${BASE_HOST}/archive/snapshots/${TEAM_ID}/${LINUX_USER}/snapshot-${STAMP}.tar.gz"
else
  KIND="daily"
  SPACES_KEY="${BASE_HOST}/archive/backups/${TEAM_ID}/${TEAM_ID}/${LINUX_USER}/backup-${STAMP}.tar.gz"
fi

# ------------------------------------------------------------------
# Create archive
# ------------------------------------------------------------------
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

# ------------------------------------------------------------------
# Upload to Spaces
# ------------------------------------------------------------------
log "Uploading to Spaces:"
log "  endpoint: ${SPACES_ENDPOINT}"
log "  bucket:   s3://${BUCKET}"
log "  object:   ${SPACES_KEY}"
log "  bytes:    ${SIZE}"

aws_cp "$ARCHIVE" "s3://${BUCKET}/${SPACES_KEY}"

# ------------------------------------------------------------------
# Notify Pressillion API (record in DB)
# ------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Dry-run enabled: API notify skipped"
else
  if [[ -z "${SERVER_UID:-}" || -z "${API_SECRET:-}" ]]; then
    echo "Missing SERVER_UID or API_SECRET in host env (needed to notify app)."
    echo "Example:"
    echo "  export SERVER_UID=\"551676231\""
    echo "  export API_SECRET=\"<servers.api_secret>\""
    exit 1
  fi

  # API object_key wants: {kind}/{team_id}/{linux_user}/backup_{YYYYMMDD-HHmmss}.tar.zst
  # BUT your ingest controller *validates* that format. We are recording our tar.gz archive path in Spaces.
  # So for ingest, we must either:
  #  - (A) change ingest validation to accept tar.gz + your archive/... format, OR
  #  - (B) report an object_key that matches existing ingest format and make the uploader match it.
  #
  # You said: "save path" and you want the Spaces path in the record.
  # So we send storage_bucket + object_key as the Spaces key we actually uploaded.
  #
  # IMPORTANT: that means your controller validation must be updated to accept this archive path.
  #
  # For now we send kind as 'snapshot' or 'daily' (existing enum accepts snapshot/daily/weekly in your earlier work).
  # If your controller expects daily/weekly/snapshot, we're good.
  #

  TS="$(date +%s)"

  PY_OUT="$(python3 - <<'PY'
import os, json, uuid, hashlib, hmac

ts = int(os.environ["TS"])
secret = os.environ["API_SECRET"].encode("utf-8")
path = os.environ["API_PATH"]
if not path.startswith("/"):
    path = "/" + path

payload = {
  "website_id": int(os.environ["WEBSITE_ID"]),
  "website_linux_user": os.environ["LINUX_USER"],
  "kind": os.environ["KIND"],
  "storage_driver": "s3",
  "storage_bucket": os.environ["BUCKET"],
  "object_key": os.environ["SPACES_KEY"],
  "bytes": int(os.environ["SIZE"]),
  "backup_at": os.environ["BACKUP_AT"],
}

body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
body_sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
nonce = str(uuid.uuid4())

canonical = "\n".join([
  str(ts),
  nonce,
  "POST",
  path,
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

  URL="https://${BASE_HOST}${API_PATH}"

  log "Notifying Pressillion API:"
  log "  url:  ${URL}"
  log "  ts:   ${TS}"
  log "  sha:  ${BODY_SHA}"

  # Export for python block already run
  RESPONSE="$(
    curl -sS -D /tmp/pressillion-api-headers.txt -o /tmp/pressillion-api-body.txt -X POST "${URL}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "X-Pressillion-Server: ${SERVER_UID}" \
      -H "X-Pressillion-Timestamp: ${TS}" \
      -H "X-Pressillion-Nonce: ${NONCE}" \
      -H "X-Pressillion-Signature: ${SIG}" \
      --data "${BODY}" \
      || true
  )"

  HTTP_CODE="$(awk 'NR==1{print $2}' /tmp/pressillion-api-headers.txt 2>/dev/null || echo "")"
  log "API HTTP: ${HTTP_CODE:-unknown}"

  log "API response body:"
  cat /tmp/pressillion-api-body.txt
  echo ""
fi

# ------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------
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
echo "Spaces Key: ${SPACES_KEY}"