#!/bin/sh
set -eu

# Required env vars
: "${PRESSILLION_API_SECRET:?Missing PRESSILLION_API_SECRET}"
: "${PRESSILLION_SERVER_UID:?Missing PRESSILLION_SERVER_UID}"
: "${PRESSILLION_TEAM_ID:?Missing PRESSILLION_TEAM_ID (must match server->team_id)}"

# Optional env vars (stage default)
PRESSILLION_BASE_URL="${PRESSILLION_BASE_URL:-https://stage.pressillion.co.uk}"
PRESSILLION_ENDPOINT_PATH="${PRESSILLION_ENDPOINT_PATH:-/api/v1/backups/complete}"

# Ensure leading slash (Laravel middleware expects "/".$request->path())
case "$PRESSILLION_ENDPOINT_PATH" in
  /*) : ;;
  *) PRESSILLION_ENDPOINT_PATH="/$PRESSILLION_ENDPOINT_PATH" ;;
esac

# Payload defaults (override as needed)
WEBSITE_ID="${WEBSITE_ID:-20}"
WEBSITE_LINUX_USER="${WEBSITE_LINUX_USER:-kronankreative-20}"
KIND="${KIND:-daily}"                 # daily|weekly|snapshot
LABEL="${LABEL:-}"                    # optional
STORAGE_DRIVER="${STORAGE_DRIVER:-s3}"
STORAGE_BUCKET="${STORAGE_BUCKET:-pressillion-processing}"
BYTES="${BYTES:-104857600}"
MANIFEST_SHA256="${MANIFEST_SHA256:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
CHECKSUMS_SHA256="${CHECKSUMS_SHA256:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"

TS="$(date +%s)"
export TS

PY_OUT="$(python3 - <<'PY'
import os, json, uuid, hashlib, hmac
from datetime import datetime, timezone

ts = int(os.environ["TS"])
secret = os.environ["PRESSILLION_API_SECRET"].encode("utf-8")

endpoint_path = os.environ.get("PRESSILLION_ENDPOINT_PATH", "/api/v1/backups/complete")
if not endpoint_path.startswith("/"):
    endpoint_path = "/" + endpoint_path

website_id = int(os.environ.get("WEBSITE_ID", "20"))
linux_user = os.environ.get("WEBSITE_LINUX_USER", "kronankreative-20")
kind = os.environ.get("KIND", "daily")
label = os.environ.get("LABEL", "")
storage_driver = os.environ.get("STORAGE_DRIVER", "s3")
storage_bucket = os.environ.get("STORAGE_BUCKET", "pressillion-processing")
team_id = os.environ["PRESSILLION_TEAM_ID"]
bytes_ = int(os.environ.get("BYTES", "104857600"))
manifest_sha = os.environ.get("MANIFEST_SHA256", "")
checksums_sha = os.environ.get("CHECKSUMS_SHA256", "")

dt = datetime.now(timezone.utc).replace(microsecond=0)
backup_at = dt.strftime("%Y-%m-%d %H:%M:%S")
stamp = dt.strftime("%Y%m%d-%H%M%S")
object_key = f"{kind}/{team_id}/{linux_user}/backup_{stamp}.tar.zst"

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

# Only include optional fields if set (avoids null noise + future signature surprises)
if label != "":
  payload["label"] = label
if manifest_sha != "":
  payload["manifest_sha256"] = manifest_sha
if checksums_sha != "":
  payload["checksums_sha256"] = checksums_sha

# IMPORTANT: body must match what is sent byte-for-byte
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
print(backup_at)
print(object_key)
PY
)"

BODY="$(printf "%s" "$PY_OUT" | sed -n '1p')"
BODY_SHA="$(printf "%s" "$PY_OUT" | sed -n '2p')"
NONCE="$(printf "%s" "$PY_OUT" | sed -n '3p')"
SIG="$(printf "%s" "$PY_OUT" | sed -n '4p')"
BACKUP_AT="$(printf "%s" "$PY_OUT" | sed -n '5p')"
OBJECT_KEY="$(printf "%s" "$PY_OUT" | sed -n '6p')"

URL="${PRESSILLION_BASE_URL}${PRESSILLION_ENDPOINT_PATH}"

echo "== Pressillion Backup Complete Test =="
echo "URL:        ${URL}"
echo "TS:         ${TS}"
echo "Nonce:      ${NONCE}"
echo "Body SHA:   ${BODY_SHA}"
echo "Signature:  ${SIG}"
echo "Backup at:  ${BACKUP_AT}"
echo "Object key: ${OBJECT_KEY}"
echo ""

curl -sS -D- -X POST "${URL}" \
  -H "Content-Type: application/json" \
  -H "X-Pressillion-Server: ${PRESSILLION_SERVER_UID}" \
  -H "X-Pressillion-Timestamp: ${TS}" \
  -H "X-Pressillion-Nonce: ${NONCE}" \
  -H "X-Pressillion-Signature: ${SIG}" \
  --data "${BODY}"

echo ""