#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Pressillion WordPress backup runner
#
# Creates a portable WP backup:
#   - DB export (mysqldump/mariadb-dump) -> db.sql.gz
#   - wp-content directory (and optionally wp-config.php, .htaccess)
#
# Uploads to Spaces and notifies Pressillion API (/api/v1/backups/complete).
#
# Required:
#   --linux-user <linux-user>
#
# Optional:
#   --env-file /home/<linux-user>/.env
#   --snapshot
#   --dry-run
#   --keep-local
#   --force            (ignores DAILY_BACKUPS_ENABLED=0)
# ------------------------------------------------------------------

BASE_HOST="${BASE_HOST:-app.pressillion.co.uk}"               # no https
ENDPOINT_PATH="${ENDPOINT_PATH:-/api/v1/backups/complete}"    # API path
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
  echo "Host env (for API notify / DB record):"
  echo "  SERVER_UID   (Servers.uid)"
  echo "  API_SECRET   (Servers.api_secret)"
  echo ""
  echo "Examples:"
  echo "  sudo BASE_HOST=\"stage.pressillion.co.uk\" SERVER_UID=\"551676231\" API_SECRET=\"<secret>\" \\"
  echo "    bash $0 --linux-user example-21"
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

  # Running as root usually loses AWS creds; use networkr's profile/config.
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

notify_app() {
  local kind="$1"
  local object_key="$2"
  local bytes="$3"
  local backup_at="$4"

  # If missing, we cannot record in DB.
  if [[ -z "${SERVER_UID:-}" || -z "${API_SECRET:-}" ]]; then
    echo "Missing SERVER_UID or API_SECRET in host env (needed to notify app)."
    echo "Example:"
    echo "  sudo SERVER_UID=\"551676231\" API_SECRET=\"<servers.api_secret>\" \\"
    echo "    bash $0 --linux-user ${LINUX_USER}"
    return 2
  fi

  local url="https://${BASE_HOST}${ENDPOINT_PATH}"

  # Generate signed request via python (keeps canonical exactly consistent)
  local py_out
  py_out="$(python3 - <<'PY'
import os, json, uuid, hashlib, hmac
from datetime import datetime, timezone

server_uid = os.environ["SERVER_UID"]
api_secret = os.environ["API_SECRET"].encode("utf-8")
endpoint_path = os.environ.get("ENDPOINT_PATH", "/api/v1/backups/complete")
if not endpoint_path.startswith("/"):
    endpoint_path = "/" + endpoint_path

website_id = int(os.environ["WEBSITE_ID"])
linux_user = os.environ["LINUX_USER"]
team_id = os.environ["TEAM_ID"]
kind = os.environ["KIND"]
object_key = os.environ["OBJECT_KEY"]
bytes_ = int(os.environ["BYTES"])
backup_at = os.environ["BACKUP_AT"]

ts = int(datetime.now(timezone.utc).timestamp())
nonce = str(uuid.uuid4())

payload = {
  "website_id": website_id,
  "website_linux_user": linux_user,
  "kind": kind,
  "storage_driver": "s3",
  "storage_bucket": os.environ.get("BUCKET", ""),
  "object_key": object_key,
  "bytes": bytes_,
  "backup_at": backup_at,
}

body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
body_sha = hashlib.sha256(body.encode("utf-8")).hexdigest()

canonical = "\n".join([
  str(ts),
  nonce,
  "POST",
  endpoint_path,
  body_sha,
])

sig = hmac.new(api_secret, canonical.encode("utf-8"), hashlib.sha256).hexdigest()

print(ts)
print(nonce)
print(sig)
print(body)
PY
)"

  local ts nonce sig body
  ts="$(printf "%s" "$py_out" | sed -n '1p')"
  nonce="$(printf "%s" "$py_out" | sed -n '2p')"
  sig="$(printf "%s" "$py_out" | sed -n '3p')"
  body="$(printf "%s" "$py_out" | sed -n '4p')"

  log "Notifying app (records backup in DB)..."
  log "  url:   ${url}"
  log "  kind:  ${kind}"
  log "  bytes: ${bytes}"
  log "  key:   ${object_key}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-run enabled: notify skipped"
    return 0
  fi

  # Show status+headers, and JSON body at end
  curl -sS -D- -X POST "${url}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "X-Pressillion-Server: ${SERVER_UID}" \
    -H "X-Pressillion-Timestamp: ${ts}" \
    -H "X-Pressillion-Nonce: ${nonce}" \
    -H "X-Pressillion-Signature: ${sig}" \
    --data "${body}"

  echo ""
  return 0
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

# Required site env vars
: "${WEBSITE_ID:?WEBSITE_ID missing in env}"
: "${TEAM_ID:?TEAM_ID missing in env}"
: "${CONTAINER_DB_NAME:?CONTAINER_DB_NAME missing in env}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE missing in env}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD missing in env}"

if [[ "$DO_SNAPSHOT" -eq 0 && "${DAILY_BACKUPS_ENABLED:-0}" != "1" && "$FORCE" -ne 1 ]]; then
  log "Daily backups disabled (DAILY_BACKUPS_ENABLED=${DAILY_BACKUPS_ENABLED:-0}). Use --force to override."
  exit 0
fi

STAMP="$(date -u '+%Y%m%d-%H%M%S')"
HUMAN_TS="$(date -u '+%Y-%m-%d %H:%M:%S')"
BACKUP_AT_UTC="${HUMAN_TS}"

WORKDIR="/tmp/pressillion-${LINUX_USER}-${STAMP}"
OUTDIR="${WORKDIR}/payload"
ARCHIVE="${WORKDIR}/backup-${STAMP}.tar.gz"

mkdir -p "$OUTDIR"

# Determine object key
if [[ "$DO_SNAPSHOT" -eq 1 ]]; then
  KIND="snapshot"
  OBJECT_KEY="${BASE_HOST}/archive/snapshots/${TEAM_ID}/${LINUX_USER}/snapshot-${STAMP}.tar.gz"
else
  KIND="daily"
  OBJECT_KEY="${BASE_HOST}/archive/backups/${TEAM_ID}/${TEAM_ID}/${LINUX_USER}/backup-${STAMP}.tar.gz"
fi

# Export DB
log "Exporting DB from container: ${CONTAINER_DB_NAME}"
log "  database: ${MYSQL_DATABASE}"
DB_DUMP="${OUTDIR}/db.sql"
DB_GZ="${OUTDIR}/db.sql.gz"

# Try mysqldump first, then mariadb-dump
if docker exec "${CONTAINER_DB_NAME}" sh -lc "command -v mysqldump >/dev/null 2>&1"; then
  docker exec "${CONTAINER_DB_NAME}" sh -lc \
    "mysqldump -uroot -p\"${MYSQL_ROOT_PASSWORD}\" --single-transaction --quick --routines --triggers \"${MYSQL_DATABASE}\"" \
    > "${DB_DUMP}"
else
  docker exec "${CONTAINER_DB_NAME}" sh -lc \
    "mariadb-dump -uroot -p\"${MYSQL_ROOT_PASSWORD}\" --single-transaction --quick --routines --triggers \"${MYSQL_DATABASE}\"" \
    > "${DB_DUMP}"
fi

gzip -9 "${DB_DUMP}"
if [[ ! -f "${DB_GZ}" ]]; then
  echo "DB dump failed: ${DB_GZ} not created"
  exit 1
fi

# Collect WP files (portable restore set)
SITE_DIR="/home/${LINUX_USER}/data/site"
WP_CONTENT="${SITE_DIR}/wp-content"
WP_CONFIG="${SITE_DIR}/wp-config.php"
HTACCESS="${SITE_DIR}/.htaccess"

if [[ ! -d "${SITE_DIR}" ]]; then
  echo "Missing site dir: ${SITE_DIR}"
  exit 1
fi

if [[ -d "${WP_CONTENT}" ]]; then
  log "Copying wp-content..."
  mkdir -p "${OUTDIR}/wp-content"
  rsync -a --delete "${WP_CONTENT}/" "${OUTDIR}/wp-content/"
else
  echo "Missing wp-content folder: ${WP_CONTENT}"
  exit 1
fi

if [[ -f "${WP_CONFIG}" ]]; then
  log "Including wp-config.php"
  cp -f "${WP_CONFIG}" "${OUTDIR}/wp-config.php"
fi

if [[ -f "${HTACCESS}" ]]; then
  log "Including .htaccess"
  cp -f "${HTACCESS}" "${OUTDIR}/.htaccess"
fi

# Add a tiny manifest for sanity
cat > "${OUTDIR}/manifest.json" <<EOF
{
  "created_at_utc": "${BACKUP_AT_UTC}",
  "kind": "${KIND}",
  "website_id": ${WEBSITE_ID},
  "team_id": ${TEAM_ID},
  "linux_user": "${LINUX_USER}",
  "base_host": "${BASE_HOST}",
  "object_key": "${OBJECT_KEY}",
  "contains": [
    "db.sql.gz",
    "wp-content/",
    "wp-config.php (if present)",
    ".htaccess (if present)",
    "manifest.json"
  ]
}
EOF

# Create archive
log "Creating archive: ${ARCHIVE}"
tar -czf "${ARCHIVE}" -C "${OUTDIR}" .

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "Archive was not created: ${ARCHIVE}"
  exit 1
fi

SIZE="$(file_size_bytes "${ARCHIVE}")"
if [[ "$SIZE" -lt 10240 ]]; then
  echo "Archive looks too small (${SIZE} bytes) - refusing to upload"
  exit 1
fi

log "Uploading to Spaces:"
log "  endpoint: ${SPACES_ENDPOINT}"
log "  bucket:   s3://${BUCKET}"
log "  object:   ${OBJECT_KEY}"
log "  bytes:    ${SIZE}"

aws_cp "${ARCHIVE}" "s3://${BUCKET}/${OBJECT_KEY}"

# Notify app to record in DB
# Export vars needed by notify_app's python block
export WEBSITE_ID TEAM_ID LINUX_USER KIND OBJECT_KEY BYTES="${SIZE}" BACKUP_AT="${BACKUP_AT_UTC}" \
       BASE_HOST ENDPOINT_PATH BUCKET

notify_app "${KIND}" "${OBJECT_KEY}" "${SIZE}" "${BACKUP_AT_UTC}" || true

if [[ "$KEEP_LOCAL" -ne 1 ]]; then
  rm -rf "$WORKDIR"
else
  log "Keeping local workdir: $WORKDIR"
fi

echo ""
log "Backup complete"
echo "Timestamp:  ${HUMAN_TS} (UTC)"
echo "Kind:       ${KIND}"
echo "Website ID: ${WEBSITE_ID}"
echo "Team ID:    ${TEAM_ID}"
echo "Linux User: ${LINUX_USER}"
echo "Size:       ${SIZE} bytes"
echo "Path:       ${OBJECT_KEY}"