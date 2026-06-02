#!/usr/bin/env bash
set -u
set -o pipefail

MIRROR_DIR="${MIRROR_DIR:-$HOME/.cache/ohos_mirror}"
LOCK_FILE="$MIRROR_DIR/.repo_sync_inprogress"
SYNC_LOG="$MIRROR_DIR/sync.log"
LFS_LOG="$MIRROR_DIR/lfs.log"
MAIN_LOG="$MIRROR_DIR/mirror-sync.log"
STATUS_FILE="$MIRROR_DIR/last_sync_date"
REPO_CMD="${REPO_CMD:-/usr/bin/repo}"

log() {
  local msg="$1"
  echo "[$(date '+%F %T')] $msg" | tee -a "$MAIN_LOG"
}

cd "$MIRROR_DIR" || exit 1

if [ -f "$LOCK_FILE" ]; then
  lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
  if [ "$lock_age" -gt 1800 ]; then
    log "stale lock file detected (${lock_age}s old), removing"
    rm -f "$LOCK_FILE"
  else
    log "sync in progress, exiting"
    exit 0
  fi
fi

trap 'rm -f "$LOCK_FILE"' EXIT
date '+%F %T' > "$LOCK_FILE"

log "repo sync started"

echo "=== repo sync started at $(date '+%F %T') ===" > "$SYNC_LOG"
$REPO_CMD sync -j 8 --retry-fetches=5 >> "$SYNC_LOG" 2>&1
SYNC_RC=$?
echo "=== repo sync finished at $(date '+%F %T') with code $SYNC_RC ===" >> "$SYNC_LOG"

log "repo sync finished with code $SYNC_RC"

if [ "$SYNC_RC" -eq 0 ]; then
  log "lfs fetch started"
  echo "=== lfs fetch started at $(date '+%F %T') ===" > "$LFS_LOG"

  $REPO_CMD forall -j 8 -c '
    if git config --get-regexp "^(lfs\.url|remote\..*\.lfsurl)$" >/dev/null 2>&1 || git lfs env >/dev/null 2>&1; then
      remote_name=origin
      if git remote get-url gitcode >/dev/null 2>&1; then
        remote_name=gitcode
      fi

      echo "[$(date "+%F %T")] [$REPO_PROJECT] git lfs fetch --all $remote_name"
      git lfs fetch --all "$remote_name" 2>&1 || true
    else
      echo "[$(date "+%F %T")] [$REPO_PROJECT] git lfs not enabled, skipped"
    fi
  ' >> "$LFS_LOG" 2>&1

  LFS_RC=0
  echo "=== lfs fetch finished at $(date '+%F %T') ===" >> "$LFS_LOG"
  log "lfs fetch finished with code $LFS_RC"
else
  LFS_RC=99
  log "repo sync failed, skipping lfs fetch"
fi

{
  echo "date=$(date '+%F %T')"
  echo "repo_sync=$SYNC_RC"
  echo "lfs_fetch=$LFS_RC"
} > "$STATUS_FILE"

log "status written to $STATUS_FILE"

exit "$SYNC_RC"
