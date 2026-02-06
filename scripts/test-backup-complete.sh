#!/usr/bin/env bash
set -euo pipefail

URL="${URL:-https://pressillion-app.test/api/v1/backups/complete}"
SERVER_UID="${PRESSILLION_SERVER_UID:-549706955}"
SECRET="${PRESSILLION_API_SECRET:-}"

if [[ -z "$SECRET" ]]; then
  echo "Missing PRESSILLION_API_SECRET env var"
  echo "Run like:"
  echo "  PRESSILLION_API_SECRET='...secret...' bash scripts/test-backup-complete.sh"
  exit 1
fi

BODY='{
  "website_id": 19,
  "website_linux_user": "kronankreative-19",
  "kind": "daily",
  "label": null,
  "storage_driver": "s3",
  "storage_bucket": "pressillion-processing",
  "object_key": "daily/1/kronankreative-19/backup_20260206-001500.tar.zst",
  "bytes": 104857600,
  "backup_at": "2026-02-06 00:15:00",
  "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "checksums_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}'

TS="$(date +%s)"

NONCE="$(
python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

BODY_SHA="$(
printf "%s" "$BODY" | shasum -a 256 | awk '{print $1}'
)"

# IMPORTANT: must match middleware exactly:
# implode("\n", [$ts, $nonce, METHOD, '/'.$request->path(), sha256(body)])
METHOD="POST"
PATH="/api/v1/backups/complete"

CANON="$(
printf "%s\n%s\n%s\n%s\n%s" "$TS" "$NONCE" "$METHOD" "$PATH" "$BODY_SHA"
)"

SIG="$(
printf "%s" "$CANON" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}'
)"

echo "== Debug =="
echo "URL:       $URL"
echo "Server:    $SERVER_UID"
echo "TS:        $TS"
echo "Nonce:     $NONCE"
echo "Body sha:  $BODY_SHA"
echo "Canonical:"
printf '%s\n' "$CANON"
echo "Signature: $SIG"
echo

curl -vk "$URL" \
  -H "Content-Type: application/json" \
  -H "X-Pressillion-Server: $SERVER_UID" \
  -H "X-Pressillion-Timestamp: $TS" \
  -H "X-Pressillion-Nonce: $NONCE" \
  -H "X-Pressillion-Signature: $SIG" \
  --data "$BODY"
echo