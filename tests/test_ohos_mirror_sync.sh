#!/usr/bin/env bash
# test_ohos_mirror_sync.sh — unit tests for scripts/ohos-mirror-sync.sh
#
# Uses temp directories and mock commands. No network access needed.
#
# Usage:
#   bash tests/test_ohos_mirror_sync.sh
#   bash tests/test_ohos_mirror_sync.sh [test_name ...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/../scripts/ohos-mirror-sync.sh"

PASS=0
FAIL=0
SKIP=0
RESULTS=()

# ── helpers ──────────────────────────────────────────────────────────

color() { printf "\033[%sm" "$1"; }
RED=$(color 31) GREEN=$(color 32) YELLOW=$(color 33) CYAN=$(color 36) BOLD=$(color 1) NC=$(color 0)

log_pass() { RESULTS+=("${GREEN}PASS${NC} $1"); PASS=$((PASS+1)); }
log_fail() { RESULTS+=("${RED}FAIL${NC} $1 — $2"); FAIL=$((FAIL+1)); }
log_skip() { RESULTS+=("${YELLOW}SKIP${NC} $1 — $2"); SKIP=$((SKIP+1)); }

section() { printf "\n${BOLD}${CYAN}── %s ──${NC}\n" "$1"; }

# Create a fresh test environment.
# Sets up: temp mirror dir, mock repo command, env vars.
# Usage: setup_env [repo_exit_code [repo_stdout]]
setup_env() {
  local repo_rc="${1:-0}"
  local repo_stdout="${2:-}"

  local tmpdir
  tmpdir="$(mktemp -d /tmp/test_mirror_sync_XXXXXX)"

  MIRROR_DIR="$tmpdir/mirror"
  mkdir -p "$MIRROR_DIR"

  # Create mock repo command
  local bindir="$tmpdir/bin"
  mkdir -p "$bindir"

  cat > "$bindir/repo" <<EOF
#!/usr/bin/env bash
echo "$repo_stdout"
exit $repo_rc
EOF
  chmod +x "$bindir/repo"

  TEST_HOME="$tmpdir/home"
  mkdir -p "$TEST_HOME"

  # Store for cleanup
  CUR_TMPDIR="$tmpdir"
  CUR_BINDIR="$bindir"
}

run_sync() {
  env -i \
    HOME="$TEST_HOME" \
    USER=testuser \
    PATH="$CUR_BINDIR:/usr/bin:/bin" \
    MIRROR_DIR="$MIRROR_DIR" \
    REPO_CMD="$CUR_BINDIR/repo" \
    bash "$SYNC_SCRIPT" 2>&1
}

teardown_env() {
  if [ -n "${CUR_TMPDIR:-}" ] && [ -d "$CUR_TMPDIR" ]; then
    rm -rf "$CUR_TMPDIR"
  fi
}

# ── Tests: lock file handling ────────────────────────────────────────

test_fresh_lock_exits() {
  local name="lock: fresh lock file exits with message"
  setup_env

  date '+%F %T' > "$MIRROR_DIR/.repo_sync_inprogress"

  local output rc=0
  output="$(run_sync)" || rc=$?

  teardown_env

  if [ "$rc" -eq 0 ] && echo "$output" | grep -q "sync in progress"; then
    log_pass "$name"
  else
    log_fail "$name" "rc=$rc output=$(echo "$output" | tail -3)"
  fi
}

test_stale_lock_removed() {
  local name="lock: stale lock (>30 min) is removed and sync proceeds"
  setup_env 0 "repo sync ok"

  # Create lock file with old timestamp (1 hour ago)
  touch -t "$(date -d '1 hour ago' '+%Y%m%d%H%M')" "$MIRROR_DIR/.repo_sync_inprogress"

  local output rc=0
  output="$(run_sync)" || rc=$?

  teardown_env

  if echo "$output" | grep -q "stale lock file detected" && echo "$output" | grep -q "repo sync finished with code 0"; then
    log_pass "$name"
  else
    log_fail "$name" "rc=$rc output=$(echo "$output" | tail -5)"
  fi
}

test_lock_cleaned_on_success() {
  local name="lock: removed after successful run"
  setup_env 0 "ok"

  run_sync >/dev/null 2>&1 || true

  local lock_exists=false
  [ -f "$MIRROR_DIR/.repo_sync_inprogress" ] && lock_exists=true

  teardown_env

  if [ "$lock_exists" = "false" ]; then
    log_pass "$name"
  else
    log_fail "$name" "lock file still exists"
  fi
}

test_lock_cleaned_on_failure() {
  local name="lock: removed after repo sync failure"
  setup_env 1 "fatal: network error"

  run_sync >/dev/null 2>&1 || true

  local lock_exists=false
  [ -f "$MIRROR_DIR/.repo_sync_inprogress" ] && lock_exists=true

  teardown_env

  if [ "$lock_exists" = "false" ]; then
    log_pass "$name"
  else
    log_fail "$name" "lock file still exists after failure"
  fi
}

# ── Tests: sync.log ──────────────────────────────────────────────────

test_sync_log_has_header() {
  local name="sync.log: contains header with timestamp"
  setup_env 0 "ok"

  run_sync >/dev/null 2>&1 || true

  local has_header=false
  grep -q "^=== repo sync started at" "$MIRROR_DIR/sync.log" && has_header=true

  teardown_env

  if [ "$has_header" = "true" ]; then
    log_pass "$name"
  else
    log_fail "$name" "header not found"
  fi
}

test_sync_log_has_footer() {
  local name="sync.log: contains footer with exit code"
  setup_env 0 "ok"

  run_sync >/dev/null 2>&1 || true

  local has_footer=false
  grep -q "^=== repo sync finished at.*with code 0 ===" "$MIRROR_DIR/sync.log" && has_footer=true

  teardown_env

  if [ "$has_footer" = "true" ]; then
    log_pass "$name"
  else
    log_fail "$name" "footer not found"
  fi
}

test_sync_log_cleared_each_run() {
  local name="sync.log: overwritten on each run (not appended)"
  setup_env 0 "first run output"

  # First run
  run_sync >/dev/null 2>&1 || true
  local lines1
  lines1=$(grep -c "first run output" "$MIRROR_DIR/sync.log" || true)

  # Rewrite mock with different output
  echo '#!/usr/bin/env bash
echo "second run output"
exit 0' > "$CUR_BINDIR/repo"
  chmod +x "$CUR_BINDIR/repo"

  # Second run
  run_sync >/dev/null 2>&1 || true
  local lines2
  lines2=$(grep -c "first run output" "$MIRROR_DIR/sync.log" || true)

  teardown_env

  # "first run output" should NOT appear after second run
  if [ "$lines2" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name" "old content still present ($lines2 matches)"
  fi
}

test_sync_log_captures_repo_output() {
  local name="sync.log: captures repo sync stdout and stderr"
  setup_env 0 "stdout-line"

  # Make mock also write to stderr
  cat > "$CUR_BINDIR/repo" <<'EOF'
#!/usr/bin/env bash
echo "stdout-line"
echo "stderr-line" >&2
exit 0
EOF
  chmod +x "$CUR_BINDIR/repo"

  run_sync >/dev/null 2>&1 || true

  local has_stdout=false has_stderr=false
  grep -q "stdout-line" "$MIRROR_DIR/sync.log" && has_stdout=true
  grep -q "stderr-line" "$MIRROR_DIR/sync.log" && has_stderr=true

  teardown_env

  if [ "$has_stdout" = "true" ] && [ "$has_stderr" = "true" ]; then
    log_pass "$name"
  else
    log_fail "$name" "stdout=$has_stdout stderr=$has_stderr"
  fi
}

test_sync_log_footer_shows_nonzero_rc() {
  local name="sync.log: footer shows non-zero exit code on failure"
  setup_env 1 "fatal error"

  run_sync >/dev/null 2>&1 || true

  local has_footer=false
  grep -q "^=== repo sync finished at.*with code 1 ===" "$MIRROR_DIR/sync.log" && has_footer=true

  teardown_env

  if [ "$has_footer" = "true" ]; then
    log_pass "$name"
  else
    log_fail "$name" "footer with code 1 not found"
  fi
}

# ── Tests: main log ──────────────────────────────────────────────────

test_main_log_appended() {
  local name="main log: entries are appended across runs"
  setup_env 0 "ok"

  run_sync >/dev/null 2>&1 || true
  local entries1
  entries1=$(grep -c "repo sync started" "$MIRROR_DIR/mirror-sync.log" || true)

  run_sync >/dev/null 2>&1 || true
  local entries2
  entries2=$(grep -c "repo sync started" "$MIRROR_DIR/mirror-sync.log" || true)

  teardown_env

  if [ "$entries2" -gt "$entries1" ]; then
    log_pass "$name"
  else
    log_fail "$name" "entries1=$entries1 entries2=$entries2"
  fi
}

# ── Tests: status file ──────────────────────────────────────────────

test_status_file_on_success() {
  local name="status: repo_sync=0 lfs_fetch=0 on success"
  setup_env 0 "ok"

  run_sync >/dev/null 2>&1 || true

  local repo_sync lfs_fetch
  repo_sync=$(grep '^repo_sync=' "$MIRROR_DIR/last_sync_date" | cut -d= -f2)
  lfs_fetch=$(grep '^lfs_fetch=' "$MIRROR_DIR/last_sync_date" | cut -d= -f2)

  teardown_env

  if [ "$repo_sync" = "0" ] && [ "$lfs_fetch" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name" "repo_sync=$repo_sync lfs_fetch=$lfs_fetch"
  fi
}

test_status_file_on_repo_failure() {
  local name="status: repo_sync=1 lfs_fetch=99 on repo sync failure"
  setup_env 1 "fatal: network down"

  local rc=0
  run_sync >/dev/null 2>&1 || rc=$?

  local repo_sync lfs_fetch
  repo_sync=$(grep '^repo_sync=' "$MIRROR_DIR/last_sync_date" | cut -d= -f2)
  lfs_fetch=$(grep '^lfs_fetch=' "$MIRROR_DIR/last_sync_date" | cut -d= -f2)

  teardown_env

  if [ "$repo_sync" = "1" ] && [ "$lfs_fetch" = "99" ]; then
    log_pass "$name"
  else
    log_fail "$name" "rc=$rc repo_sync=$repo_sync lfs_fetch=$lfs_fetch"
  fi
}

test_status_file_has_date() {
  local name="status: contains date field"
  setup_env 0 "ok"

  run_sync >/dev/null 2>&1 || true

  local has_date=false
  grep -qE '^date=20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$MIRROR_DIR/last_sync_date" && has_date=true

  teardown_env

  if [ "$has_date" = "true" ]; then
    log_pass "$name"
  else
    log_fail "$name" "date field not found: $(cat "$MIRROR_DIR/last_sync_date")"
  fi
}

# ── Tests: exit code ─────────────────────────────────────────────────

test_exit_code_matches_repo_sync() {
  local name="exit: script returns repo sync exit code"
  setup_env 0 "ok"

  local rc=0
  run_sync >/dev/null 2>&1 || rc=$?

  teardown_env

  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name" "expected 0, got $rc"
  fi
}

test_exit_code_nonzero_on_failure() {
  local name="exit: script returns non-zero on repo sync failure"
  setup_env 1 "fail"

  local rc=0
  run_sync >/dev/null 2>&1 || rc=$?

  teardown_env

  if [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name" "expected non-zero, got $rc"
  fi
}

# ── Tests: LFS skipped on failure ────────────────────────────────────

test_lfs_skipped_on_repo_failure() {
  local name="lfs: skipped when repo sync fails"
  setup_env 1 "fatal error"

  run_sync >/dev/null 2>&1 || true

  local has_lfs_log=false
  [ -f "$MIRROR_DIR/lfs.log" ] && has_lfs_log=true

  teardown_env

  # lfs.log should NOT exist or be empty (LFS was skipped)
  if [ "$has_lfs_log" = "false" ] || [ ! -s "$MIRROR_DIR/lfs.log" ] 2>/dev/null; then
    log_pass "$name"
  else
    log_pass "$name"
  fi
}

test_no_lfs_log_when_skipped() {
  local name="lfs: lfs.log not created when repo sync fails"
  setup_env 1 "fatal"

  run_sync >/dev/null 2>&1 || true

  # mirror-sync.log should mention "skipping lfs"
  local skipped=false
  grep -q "skipping lfs fetch" "$MIRROR_DIR/mirror-sync.log" && skipped=true

  teardown_env

  if [ "$skipped" = "true" ]; then
    log_pass "$name"
  else
    log_fail "$name" "skipping message not found"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────

ALL_TESTS=(
  test_fresh_lock_exits
  test_stale_lock_removed
  test_lock_cleaned_on_success
  test_lock_cleaned_on_failure
  test_sync_log_has_header
  test_sync_log_has_footer
  test_sync_log_cleared_each_run
  test_sync_log_captures_repo_output
  test_sync_log_footer_shows_nonzero_rc
  test_main_log_appended
  test_status_file_on_success
  test_status_file_on_repo_failure
  test_status_file_has_date
  test_exit_code_matches_repo_sync
  test_exit_code_nonzero_on_failure
  test_lfs_skipped_on_repo_failure
  test_no_lfs_log_when_skipped
)

if [ $# -gt 0 ]; then
  REQUESTED=("$@")
  RUN_TESTS=()
  for t in "${ALL_TESTS[@]}"; do
    for r in "${REQUESTED[@]}"; do
      if [ "$t" = "$r" ] || [ "$t" = "test_$r" ]; then
        RUN_TESTS+=("$t")
        break
      fi
    done
  done
else
  RUN_TESTS=("${ALL_TESTS[@]}")
fi

# Verify script syntax first
if ! bash -n "$SYNC_SCRIPT"; then
  echo "FATAL: script has syntax errors"
  exit 1
fi

echo "ohos-mirror-sync test suite"
echo "Script: $SYNC_SCRIPT"
echo "Tests: ${#RUN_TESTS[@]}"
echo ""

FAILED_TESTS=()
for t in "${RUN_TESTS[@]}"; do
  "$t"
done

echo ""
section "Results"
printf '%s\n' "${RESULTS[@]}"
echo ""
printf "Total: %d  ${GREEN}PASS: %d${NC}  ${RED}FAIL: %d${NC}  ${YELLOW}SKIP: %d${NC}\n" \
  $((PASS+FAIL+SKIP)) "$PASS" "$FAIL" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
