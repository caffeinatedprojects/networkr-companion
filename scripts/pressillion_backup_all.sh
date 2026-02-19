#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# pressillion_backup_all.sh
#
# Runs pressillion_backup_run.sh for each /home/<user> (excluding system users)
# and only backs up sites where DAILY_BACKUPS_ENABLED=1 by default.
#
# Flags:
#   --force          Run backups even if DAILY_BACKUPS_ENABLED != 1
#   --snapshot       Run snapshots (snapshots ignore DAILY_BACKUPS_ENABLED inside run script anyway)
#   --dry-run        Pass through to run script
#   --keep-local     Pass through to run script
#   --env-file NAME  Use a non-standard env filename (default: .env)
#
# Host env (for API notify / DB record):
#   BASE_HOST   (default app.pressillion.com)
#   SERVER_UID
#   API_SECRET
# ------------------------------------------------------------------

RUN_SCRIPT="/home/networkr/networkr-companion/scripts/pressillion_backup_run.sh"

ENV_FILENAME=".env"
FORCE=0
DO_SNAPSHOT=0
DRY_RUN=0
KEEP_LOCAL=0

usage() {
  echo "Usage:"
  echo "  sudo BASE_HOST=\"stage.pressillion.co.uk\" SERVER_UID=\"...\" API_SECRET=\"...\" \\"
  echo "    bash $0 [--force] [--snapshot] [--dry-run] [--keep-local] [--env-file .env]"
  echo ""
  echo "Options:"
  echo "  --force          Run backups even if DAILY_BACKUPS_ENABLED=0"
  echo "  --snapshot       Run snapshot for each site (ignores DAILY_BACKUPS_ENABLED)"
  echo "  --dry-run        Build archives but do not upload or notify"
  echo "  --keep-local     Keep local temp folders created by per-site script"
  echo "  --env-file       Env filename inside /home/<user>/ (default: .env)"
}

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --snapshot) DO_SNAPSHOT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keep-local) KEEP_LOCAL=1; shift ;;
    --env-file) ENV_FILENAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ ! -x "$RUN_SCRIPT" && ! -f "$RUN_SCRIPT" ]]; then
  echo "Missing run script: $RUN_SCRIPT"
  exit 1
fi

# Require host env for notify unless dry-run
if [[ "$DRY_RUN" -eq 0 ]]; then
  if [[ -z "${SERVER_UID:-}" || -z "${API_SECRET:-}" ]]; then
    echo "Missing SERVER_UID or API_SECRET in host env."
    echo "Example:"
    echo "  sudo BASE_HOST=\"stage.pressillion.co.uk\" SERVER_UID=\"551676231\" API_SECRET=\"<servers.api_secret>\" \\"
    echo "    bash $0"
    exit 1
  fi
fi

EXCLUDE_USERS=("pressillion" "networkr" "root")

should_exclude() {
  local u="$1"
  for x in "${EXCLUDE_USERS[@]}"; do
    if [[ "$u" == "$x" ]]; then
      return 0
    fi
  done
  return 1
}

get_env_value() {
  local env_file="$1"
  local key="$2"
  # Reads simple KEY=VALUE lines (ignores comments). No eval.
  grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

log "Starting bulk backup run..."
log "BASE_HOST: ${BASE_HOST:-app.pressillion.com}"
log "ENV file:  ${ENV_FILENAME}"
log "Mode:      $([[ "$DO_SNAPSHOT" -eq 1 ]] && echo snapshot || echo backup)"
log "Force:     $FORCE"
log "Dry-run:   $DRY_RUN"
log ""

FOUND=0
SKIPPED=0
RAN=0
FAILED=0

for home_path in /home/*; do
  [[ -d "$home_path" ]] || continue

  user="$(basename "$home_path")"

  if should_exclude "$user"; then
    continue
  fi

  # must look like a real site home
  env_file="${home_path}/${ENV_FILENAME}"
  if [[ ! -f "$env_file" ]]; then
    continue
  fi

  # must have the identity vars we introduced
  website_id="$(get_env_value "$env_file" "WEBSITE_ID")"
  team_id="$(get_env_value "$env_file" "TEAM_ID")"
  daily_enabled="$(get_env_value "$env_file" "DAILY_BACKUPS_ENABLED")"

  if [[ -z "$website_id" || -z "$team_id" ]]; then
    log "Skip ${user}: missing WEBSITE_ID/TEAM_ID in ${env_file}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [[ "$DO_SNAPSHOT" -eq 0 ]]; then
    if [[ "${daily_enabled:-0}" != "1" && "$FORCE" -ne 1 ]]; then
      log "Skip ${user}: DAILY_BACKUPS_ENABLED=${daily_enabled:-0}"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  FOUND=$((FOUND + 1))

  log "Running for ${user} (website_id=${website_id}, team_id=${team_id})..."

  cmd=( bash "$RUN_SCRIPT" --linux-user "$user" --env-file "$env_file" )

  if [[ "$DO_SNAPSHOT" -eq 1 ]]; then
    cmd+=( --snapshot )
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cmd+=( --dry-run )
  fi

  if [[ "$KEEP_LOCAL" -eq 1 ]]; then
    cmd+=( --keep-local )
  fi

  if [[ "$FORCE" -eq 1 ]]; then
    cmd+=( --force )
  fi

  # run with the current environment (BASE_HOST/SERVER_UID/API_SECRET etc already set)
  if "${cmd[@]}"; then
    RAN=$((RAN + 1))
    log "OK ${user}"
  else
    FAILED=$((FAILED + 1))
    log "FAIL ${user}"
  fi

  log ""
done

log "Bulk backup run complete"
log "Eligible sites found: ${FOUND}"
log "Ran:                 ${RAN}"
log "Skipped:             ${SKIPPED}"
log "Failed:              ${FAILED}"

if [[ "$FAILED" -gt 0 ]]; then
  exit 2
fi

exit 0