#!/usr/bin/env bash
set -euo pipefail

# Required env vars
: "${PRESSILLION_API_SECRET:?Missing PRESSILLION_API_SECRET}"
: "${PRESSILLION_SERVER_UID:?Missing PRESSILLION_SERVER_UID}"

# Optional env vars
PRESSILLION_BASE_URL="${PRESSILLION_BASE_URL:-https://pressillion-app.test}"
PRESSILLION_ENDPOINT_PATH="${PRESSILLION_ENDPOINT_PATH:-/api/v1/backups/complete}"

# These must match what your controller expects
WEBSITE_ID="${WEBSITE_ID:-19}"
WEBSITE_LINUX_USER="${WEBSITE_LINUX_USER:-kronankreative-19}"
KIND="${KIND:-daily}"                         # daily|weekly|snapshot
LABEL="${LABEL:-}"                            # optional, blank lets API set it
STORAGE_DRIVER="${STORAGE_DRIVER:-s3}"        # optional, API defaults to s3 if empty
STORAGE_BUCKET="${STORAGE_BUCKET:-pressillion-processing}"
TEAM_ID="${TEAM_ID:-1}"                       # MUST match $server->team_id for object_key validation
BYTES="${BYTES:-104857600}"                   # 100 MiB default
MANIFEST_SHA256="${MANIFEST_SHA256:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
CHECKSUMS_SHA256="${CHECKSUMS_SHA256:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"

# Generate backup_at + stamp (UTC) so object_key matches your controller rules
read -r BACKUP_AT STAMP <<<"$(python3 - <<'PY'
from datetime import datetime, timezone
dt = datetime.now(timezone.utc).replace(microsecond=0)
print(dt.strftime("%Y-%m-%d %H:%M:%S"), dt.strftime("%Y%m%d-%H%M%S"))
PY
)"

OBJECT_KEY="${KIND}/${TEAM_ID}/${WEBSITE_LINUX_USER}/backup_${STAMP}.tar.zst"

# Build the JSON body (stable formatting, no extra whitespace)
BODY="$(python3 - <<PY
import json
payload = {
  "website_id": int("${WEBSITE_ID}"),
  "website_linux_user": "${WEBSITE_LINUX_USER}",
  "kind": "${KIND}",
  "label": (None if "${LABEL}" == "" else "${LABEL}"),
  "storage_driver": "${STORAGE_DRIVER}",
  "storage_bucket": "${STORAGE_BUCKET}",
  "object_key": "${OBJECT_KEY}",
  "bytes": int("${BYTES}"),
  "backup_at": "${BACKUP_AT}",
  "manifest_sha256": "${MANIFEST_SHA256}",
  "checksums_sha256": "${CHECKSUMS_SHA256}",
}
print(json.dumps(payload, separators=(",", ":"), ensure_ascii=False))
PY
)"

TS="$(date +%s)"
NONCE="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

# Compute body sha + signature using python (no openssl/awk needed)
read -r BODY_SHA SIG CANONICAL <<<"$(python3 - <<PY
import hashlib, hmac
secret = "${PRESSILLION_API_SECRET}".encode("utf-8")
body = ${BODY!r}.encode("utf-8")

body_sha = hashlib.sha256(body).hexdigest()

canonical = "\n".join([
  str(int("${TS}")),
  "${NONCE}",
  "POST",
  "${PRESSILLION_ENDPOINT_PATH}",
  body_sha,
])

sig = hmac.new(secret, canonical.encode("utf-8"), hashlib.sha256).hexdigest()
print(body_sha, sig, canonical.replace("\\n", "\\\\n"))
PY
)"

URL="${PRESSILLION_BASE_URL}${PRESSILLION_ENDPOINT_PATH}"

echo "== Pressillion Backup Complete Test =="
echo "URL:        ${URL}"
echo "TS:         ${TS}"
echo "Nonce:      ${NONCE}"
echo "Body SHA:   ${BODY_SHA}"
echo "Signature:  ${SIG}"
echo "Object key: ${OBJECT_KEY}"
echo ""

curl -sk -D- "${URL}" \
  -H "Content-Type: application/json" \
  -H "X-Pressillion-Server: ${PRESSILLION_SERVER_UID}" \
  -H "X-Pressillion-Timestamp: ${TS}" \
  -H "X-Pressillion-Nonce: ${NONCE}" \
  -H "X-Pressillion-Signature: ${SIG}" \
  --data "${BODY}"
echo ""