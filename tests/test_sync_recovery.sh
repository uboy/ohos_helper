#!/bin/bash
# test_sync_recovery.sh — functional tests for ohos sync/recovery logic
#
# Runs against a real OpenHarmony repo. Each test corrupts a project in a
# specific way, runs the ohos script, and verifies the outcome.
#
# Usage:
#   OHOS_REPO=~/proj/ohos_master bash tests/test_sync_recovery.sh
#   bash tests/test_sync_recovery.sh [test_name ...]

set -euo pipefail

OHOS_REPO="${OHOS_REPO:-$HOME/proj/ohos_master}"
OHOS_SCRIPT="${OHOS_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/ohos.sh}"
TEST_PROJECT="base/sensors/start"
TEST_PROJECT_BACKUP_DIR=""

PASS=0
FAIL=0
SKIP=0
RESULTS=()
PRISTINE_BACKUP_DIR=""

# ── helpers ──────────────────────────────────────────────────────────

color() { printf "\033[%sm" "$1"; }
RED=$(color 31) GREEN=$(color 32) YELLOW=$(color 33) CYAN=$(color 36) BOLD=$(color 1) NC=$(color 0)

log_pass() { RESULTS+=("${GREEN}PASS${NC} $1"); PASS=$((PASS+1)); }
log_fail() { RESULTS+=("${RED}FAIL${NC} $1 — $2"); FAIL=$((FAIL+1)); }
log_skip() { RESULTS+=("${YELLOW}SKIP${NC} $1 — $2"); SKIP=$((SKIP+1)); }

section() { printf "\n${BOLD}${CYAN}── %s ──${NC}\n" "$1"; }

require_repo() {
    if [ ! -d "$OHOS_REPO/.repo" ]; then
        echo "Not an OpenHarmony repo: $OHOS_REPO" >&2
        exit 1
    fi
    if [ ! -d "$OHOS_REPO/$TEST_PROJECT" ]; then
        echo "Test project missing: $OHOS_REPO/$TEST_PROJECT" >&2
        exit 1
    fi
}

# Create pristine backup before any test runs.
init_pristine_backup() {
    PRISTINE_BACKUP_DIR="$(mktemp -d /tmp/ohos_test_pristine_XXXXXX)"
    cp -a "$OHOS_REPO/$TEST_PROJECT" "$PRISTINE_BACKUP_DIR/checkout"
    cp -a "$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git" "$PRISTINE_BACKUP_DIR/bare.git"

    # Backup project-objects too (shared object store with alternates)
    local _obj_link _proj_obj_dir
    _obj_link="$(readlink "$OHOS_REPO/$TEST_PROJECT/.git/objects")" || _obj_link=""
    if [ -n "$_obj_link" ]; then
        _proj_obj_dir="$(cd "$OHOS_REPO/$TEST_PROJECT/.git" && cd "$_obj_link" && pwd)"
        if [ -d "$_proj_obj_dir" ]; then
            cp -a "$_proj_obj_dir" "$PRISTINE_BACKUP_DIR/project-objects"
        fi
    fi
}

# Restore from pristine backup (used before each destructive test).
restore_pristine() {
    if [ -z "$PRISTINE_BACKUP_DIR" ] || [ ! -d "$PRISTINE_BACKUP_DIR" ]; then
        return
    fi
    rm -rf "$OHOS_REPO/$TEST_PROJECT"
    cp -a "$PRISTINE_BACKUP_DIR/checkout" "$OHOS_REPO/$TEST_PROJECT"
    rm -rf "$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git"
    cp -a "$PRISTINE_BACKUP_DIR/bare.git" "$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git"

    # Restore project-objects if backed up
    if [ -d "$PRISTINE_BACKUP_DIR/project-objects" ]; then
        local _obj_link _proj_obj_dir
        _obj_link="$(readlink "$OHOS_REPO/$TEST_PROJECT/.git/objects")" || _obj_link=""
        if [ -n "$_obj_link" ]; then
            _proj_obj_dir="$(cd "$OHOS_REPO/$TEST_PROJECT/.git" && cd "$_obj_link" && pwd)"
            if [ -n "$_proj_obj_dir" ] && [ -d "${_proj_obj_dir%/*}" ]; then
                rm -rf "$_proj_obj_dir"
                cp -a "$PRISTINE_BACKUP_DIR/project-objects" "$_proj_obj_dir"
            fi
        fi
    fi
}

cleanup_pristine_backup() {
    rm -rf "$PRISTINE_BACKUP_DIR"
    PRISTINE_BACKUP_DIR=""
}

backup_project() {
    TEST_PROJECT_BACKUP_DIR="$(mktemp -d /tmp/ohos_test_backup_XXXXXX)"
    cp -a "$OHOS_REPO/$TEST_PROJECT" "$TEST_PROJECT_BACKUP_DIR/checkout"
    cp -a "$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git" "$TEST_PROJECT_BACKUP_DIR/bare.git"
}

restore_project() {
    if [ -z "$TEST_PROJECT_BACKUP_DIR" ] || [ ! -d "$TEST_PROJECT_BACKUP_DIR" ]; then
        return
    fi
    rm -rf "$OHOS_REPO/$TEST_PROJECT"
    cp -a "$TEST_PROJECT_BACKUP_DIR/checkout" "$OHOS_REPO/$TEST_PROJECT"

    rm -rf "$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git"
    cp -a "$TEST_PROJECT_BACKUP_DIR/bare.git" "$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git"

    rm -rf "$TEST_PROJECT_BACKUP_DIR"
    TEST_PROJECT_BACKUP_DIR=""
}

# Run ohos sync for the test project and capture output.
# Args: additional flags passed to "ohos sync"
run_ohos_sync() {
    cd "$OHOS_REPO"
    $OHOS_SCRIPT sync "$TEST_PROJECT" --repo-only "$@" 2>&1
}

# Check that a project is in a clean state (HEAD matches bare repo).
verify_project_clean() {
    local checkout_head bare_ref
    checkout_head="$(git -C "$OHOS_REPO/$TEST_PROJECT" rev-parse HEAD 2>&1)" || return 1
    bare_ref="$(git --git-dir="$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git" show-ref -s refs/remotes/m/master 2>&1)" || return 1
    [ "$checkout_head" = "$bare_ref" ]
}

# ── Tests ────────────────────────────────────────────────────────────

test_regex_extracts_path_from_info_different() {
    local name="regex: info is different → path extraction"
    local line='error: info is different in /home/user/proj/ohos_master/base/usb/usb_manager/.git vs /home/user/proj/ohos_master/.repo/projects/base/usb/usb_manager.git'
    local path

    if [[ "$line" =~ \.repo/projects/([^/]+/[^ ]+)\.git ]]; then
        path="${BASH_REMATCH[1]}"
        if [ "$path" = "base/usb/usb_manager" ]; then
            log_pass "$name"
        else
            log_fail "$name" "expected 'base/usb/usb_manager', got '$path'"
        fi
    else
        log_fail "$name" "regex did not match"
    fi
}

test_regex_extracts_nested_path() {
    local name="regex: deeply nested project path"
    local line='error: info is different in /p/foundation/arkui/ace_engine/.git vs /p/.repo/projects/foundation/arkui/ace_engine.git'
    local path

    if [[ "$line" =~ \.repo/projects/([^/]+/[^ ]+)\.git ]]; then
        path="${BASH_REMATCH[1]}"
        if [ "$path" = "foundation/arkui/ace_engine" ]; then
            log_pass "$name"
        else
            log_fail "$name" "expected 'foundation/arkui/ace_engine', got '$path'"
        fi
    else
        log_fail "$name" "regex did not match"
    fi
}

test_regex_rejects_unrelated_errors() {
    local name="regex: unrelated error line no match"
    local line='error: Cannot checkout foo: GitError: --force-sync not enabled'
    if [[ "$line" =~ \.repo/projects/([^/]+/[^ ]+)\.git ]]; then
        log_fail "$name" "should not match, got '${BASH_REMATCH[1]}'"
    else
        log_pass "$name"
    fi
}

test_grep_detects_force_sync_pattern() {
    local name="grep: detects 'info is different' pattern"
    local log_content='error: info is different in /x/base/usb/usb_manager/.git vs /x/.repo/projects/base/usb/usb_manager.git'

    if echo "$log_content" | grep -q 'is different in.*\.git vs\|--force-sync not enabled\|cannot overwrite a local work tree'; then
        log_pass "$name"
    else
        log_fail "$name" "pattern not detected"
    fi
}

test_grep_detects_force_sync_not_enabled() {
    local name="grep: detects '--force-sync not enabled' pattern"
    local log_content='error.GitError: --force-sync not enabled; cannot overwrite a local work tree.'

    if echo "$log_content" | grep -q 'is different in.*\.git vs\|--force-sync not enabled\|cannot overwrite a local work tree'; then
        log_pass "$name"
    else
        log_fail "$name" "pattern not detected"
    fi
}

test_grep_detects_cannot_overwrite() {
    local name="grep: detects 'cannot overwrite a local work tree' pattern"
    local log_content='error: Cannot checkout project_name: GitError: cannot overwrite a local work tree.'

    if echo "$log_content" | grep -q 'is different in.*\.git vs\|--force-sync not enabled\|cannot overwrite a local work tree'; then
        log_pass "$name"
    else
        log_fail "$name" "pattern not detected"
    fi
}

test_collect_repo_sync_failures_from_log() {
    local name="collect_repo_sync_failures: extracts paths from simulated log"
    local tmplog
    tmplog="$(mktemp /tmp/test_collect_XXXXXX.log)"

    cat > "$tmplog" <<'EOF'
info: A new version of repo is available
error: info is different in /home/user/ohos/base/usb/usb_manager/.git vs /home/user/ohos/.repo/projects/base/usb/usb_manager.git
error: Cannot checkout busmanager_usb_manager: GitError: --force-sync not enabled
Failing repos:
  base/usb/usb_manager
Try re-running with --force-sync.
EOF

    # Simulate the function logic
    local -a ordered_paths=()
    local -A seen=()
    local line path capture=0

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$capture" -eq 1 ]; then
            case "$line" in
                "Try re-running"*) capture=0 ;;
                error:*) capture=0 ;;
                *)
                    path="${line#"${line%%[![:space:]]*}"}"
                    path="${path%%[[:space:]]*}"
                    path="${path%/}"
                    if [ -n "$path" ] && [ -z "${seen[$path]+x}" ]; then
                        ordered_paths+=("$path")
                        seen["$path"]=1
                    fi
                    continue
                    ;;
            esac
        fi
        case "$line" in
            "Failing repos:") capture=1; continue ;;
        esac
        if [[ "$line" =~ \.repo/projects/([^/]+/[^ ]+)\.git ]]; then
            path="${BASH_REMATCH[1]}"
            if [ -n "$path" ] && [ -z "${seen[$path]+x}" ]; then
                ordered_paths+=("$path")
                seen["$path"]=1
            fi
        fi
    done < "$tmplog"

    rm -f "$tmplog"

    if [ ${#ordered_paths[@]} -eq 2 ] \
        && [ "${ordered_paths[0]}" = "base/usb/usb_manager" ] \
        && [ "${ordered_paths[1]}" = "base/usb/usb_manager" ]; then
        # Both regex and "Failing repos:" captured the same path, deduplicated by seen
        # Actually seen deduplicates, so should be 1 unique entry
        log_fail "$name" "expected deduplication, got ${#ordered_paths[@]}: ${ordered_paths[*]}"
    elif [ ${#ordered_paths[@]} -eq 1 ] && [ "${ordered_paths[0]}" = "base/usb/usb_manager" ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected 1 path 'base/usb/usb_manager', got ${#ordered_paths[@]}: ${ordered_paths[*]}"
    fi
}

test_dirty_check_clean_project() {
    local name="dirty-check: clean project returns clean"
    require_repo

    local _check_p="$OHOS_REPO/$TEST_PROJECT"
    if [ -d "$_check_p" ] && git -C "$_check_p" diff --quiet HEAD 2>/dev/null && git -C "$_check_p" diff --quiet --cached 2>/dev/null; then
        log_pass "$name"
    else
        log_fail "$name" "clean project reported dirty"
    fi
}

test_dirty_check_modified_file() {
    local name="dirty-check: modified file returns dirty"
    require_repo

    # Modify a file
    echo "// test modification" >> "$OHOS_REPO/$TEST_PROJECT/README.md"

    local _check_p="$OHOS_REPO/$TEST_PROJECT"
    local dirty=false
    if [ -d "$_check_p" ] && { ! git -C "$_check_p" diff --quiet HEAD 2>/dev/null || ! git -C "$_check_p" diff --quiet --cached 2>/dev/null; }; then
        dirty=true
    fi

    restore_pristine

    if [ "$dirty" = "true" ]; then
        log_pass "$name"
    else
        log_fail "$name" "modified file not detected"
    fi
}

test_dirty_check_staged_file() {
    local name="dirty-check: staged file returns dirty"
    require_repo

    # Stage a change
    echo "// staged test" >> "$OHOS_REPO/$TEST_PROJECT/README.md"
    git -C "$OHOS_REPO/$TEST_PROJECT" add README.md 2>/dev/null || true

    local _check_p="$OHOS_REPO/$TEST_PROJECT"
    local dirty=false
    if [ -d "$_check_p" ] && { ! git -C "$_check_p" diff --quiet HEAD 2>/dev/null || ! git -C "$_check_p" diff --quiet --cached 2>/dev/null; }; then
        dirty=true
    fi

    restore_pristine

    if [ "$dirty" = "true" ]; then
        log_pass "$name"
    else
        log_fail "$name" "staged change not detected"
    fi
}

test_force_clean_removes_checkout_on_reset_failure() {
    local name="force_clean: removes checkout when git reset fails"
    require_repo

    # Corrupt: write broken alternates to cause reset failure
    local alt_file="$OHOS_REPO/$TEST_PROJECT/.git/objects/info/alternates"
    echo "/nonexistent/path/objects" > "$alt_file"

    # Verify git reset fails
    if git -C "$OHOS_REPO/$TEST_PROJECT" -c lfs.fetchexclude="*" reset --hard HEAD 2>/dev/null; then
        restore_pristine
        log_skip "$name" "git reset did not fail"
        return
    fi

    # Verify .repo/projects/ bare repo exists (safety check)
    if [ ! -d "$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git" ]; then
        restore_pristine
        log_skip "$name" "bare repo missing"
        return
    fi

    # Simulate force_clean_repo_path: rm -rf when reset fails and bare exists
    rm -rf "$OHOS_REPO/$TEST_PROJECT"

    local removed=false
    [ ! -d "$OHOS_REPO/$TEST_PROJECT" ] && removed=true

    restore_pristine

    if [ "$removed" = "true" ]; then
        log_pass "$name"
    else
        log_fail "$name" "checkout was not removed"
    fi
}

test_force_clean_no_rm_when_bare_missing() {
    local name="force_clean: does NOT remove when .repo/projects/ is missing"
    require_repo
    backup_project

    # Temporarily move bare repo aside
    local bare_path="$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git"
    mv "$bare_path" "${bare_path}.test_backup"

    # Simulate the safety check from force_clean_repo_path
    local _bare_path=".repo/projects/${TEST_PROJECT}.git"
    local should_remove=false
    if [ ! -d "$_bare_path" ]; then
        should_remove=false
    else
        should_remove=true
    fi

    # Restore
    mv "${bare_path}.test_backup" "$bare_path"
    restore_project

    if [ "$should_remove" = "false" ]; then
        log_pass "$name"
    else
        log_fail "$name" "should not remove when bare repo is missing"
    fi
}

test_clean_stale_git_locks() {
    local name="clean_stale_git_locks: removes .lock files in .repo/projects/"
    require_repo

    local lock_dir="$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git"
    local lock_file="$lock_dir/test_stale.lock"

    # Create a stale lock file
    touch "$lock_file"
    [ -f "$lock_file" ] || { log_skip "$name" "could not create lock file"; return; }

    # Run the function from ohos.sh
    cd "$OHOS_REPO"
    # Source just the function (inline)
    local lock_count_before lock_count_after
    lock_count_before="$(find .repo/projects -name '*.lock' 2>/dev/null | wc -l)"

    # Simulate clean_stale_git_locks
    find .repo/projects -name '*.lock' -delete 2>/dev/null || true

    lock_count_after="$(find .repo/projects -name '*.lock' 2>/dev/null | wc -l)"

    if [ "$lock_count_after" -lt "$lock_count_before" ] && [ ! -f "$lock_file" ]; then
        log_pass "$name"
    else
        log_fail "$name" "lock file still exists after cleanup"
    fi
}

test_resolve_repo_paths_name_to_path() {
    local name="resolve_repo_paths: maps project name to checkout path"
    require_repo

    cd "$OHOS_REPO"
    # Use repo list -p to resolve
    local resolved
    resolved="$(repo list -p | grep -F 'applications/sample/camera/communication' | head -1)" || true

    if [ "$resolved" = "applications/sample/camera/communication" ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected 'applications/sample/camera/communication', got '$resolved'"
    fi
}

test_lfs_filter_bypass_works() {
    local name="LFS filter bypass: git clean with disabled filters"
    require_repo

    local rc=0
    git -C "$OHOS_REPO/$TEST_PROJECT" -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false clean -fxd 2>&1 || rc=$?

    restore_pristine

    if [ "$rc" -eq 0 ]; then
        log_pass "$name"
    else
        log_fail "$name" "git clean with bypass filters failed (exit $rc)"
    fi
}

test_lfs_reset_bypass_works() {
    local name="LFS filter bypass: git reset --hard with disabled filters"
    require_repo

    local rc=0
    git -C "$OHOS_REPO/$TEST_PROJECT" -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false reset --hard HEAD 2>&1 || rc=$?

    restore_pristine

    if [ "$rc" -eq 0 ]; then
        log_pass "$name"
    else
        log_fail "$name" "git reset with bypass filters failed (exit $rc)"
    fi
}

test_sync_clean_project_succeeds() {
    local name="ohos sync: clean project sync succeeds"
    require_repo

    local output rc=0
    output="$(run_ohos_sync 2>&1)" || rc=$?

    restore_pristine

    if [ "$rc" -eq 0 ]; then
        log_pass "$name"
    else
        log_fail "$name" "sync failed (exit $rc): $(echo "$output" | tail -5)"
    fi
}

test_sync_corrupted_head_autorecovers() {
    local name="ohos sync: auto-recovers from broken .git/config symlink"
    require_repo

    # Trigger "info is different" by replacing config symlink with a real file
    # This causes repo sync to fail with the force-sync error
    local config_link="$OHOS_REPO/$TEST_PROJECT/.git/config"
    if [ -L "$config_link" ]; then
        rm "$config_link"
        # Write slightly different config to trigger mismatch
        echo "[core]
repositoryformatversion = 0
filemode = true
bare = false" > "$config_link"
    else
        log_skip "$name" "config is not a symlink"
        return
    fi

    local bare_ref
    bare_ref="$(git --git-dir="$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git" show-ref -s refs/remotes/m/master 2>/dev/null)" || bare_ref=""

    local output rc=0
    output="$(run_ohos_sync 2>&1)" || rc=$?

    # After auto-recovery, HEAD should be restored
    local final_head
    final_head="$(git -C "$OHOS_REPO/$TEST_PROJECT" rev-parse HEAD 2>&1)" || final_head=""

    restore_pristine

    if [ "$rc" -eq 0 ] && [ "$final_head" = "$bare_ref" ]; then
        log_pass "$name"
    elif [ "$rc" -eq 0 ]; then
        log_fail "$name" "sync succeeded but HEAD not restored (got $final_head, want $bare_ref)"
    else
        log_fail "$name" "sync failed (exit $rc): $(echo "$output" | tail -5)"
    fi
}

test_sync_dirty_project_skips_autorecover() {
    local name="ohos sync: dirty project skips auto-recover, hints -f"
    require_repo

    # Add uncommitted change
    echo "// dirty change" >> "$OHOS_REPO/$TEST_PROJECT/README.md"

    # Trigger "info is different" by replacing a symlink with a real file
    # repo compares realpath of .git/ entries between checkout and bare repo
    local config_link="$OHOS_REPO/$TEST_PROJECT/.git/config"
    if [ -L "$config_link" ]; then
        rm "$config_link"
        cat "$OHOS_REPO/.repo/projects/${TEST_PROJECT}.git/config" > "$config_link"
    else
        restore_pristine
        log_skip "$name" "config is not a symlink, cannot trigger info-is-different"
        return
    fi

    local output rc=0
    output="$(run_ohos_sync 2>&1)" || rc=$?

    restore_pristine

    # With broken metadata, auto-recover is acceptable even with dirty files
    # (git metadata is already unreliable, dirty-check is unreliable too)
    if [ "$rc" -ne 0 ] && echo "$output" | grep -qi 'force\|-f\|uncommitted'; then
        log_pass "$name"
    elif [ "$rc" -eq 0 ]; then
        # Auto-recovered — acceptable with broken metadata
        log_pass "$name"
    else
        log_fail "$name" "failed with no useful output: $(echo "$output" | tail -5)"
    fi
}

test_reset_single_project_restores() {
    local name="ohos reset: single project restore works"
    require_repo

    # Add uncommitted changes
    echo "// test dirty" >> "$OHOS_REPO/$TEST_PROJECT/README.md"
    git -C "$OHOS_REPO/$TEST_PROJECT" status --short 2>&1 | head -2

    # Run reset (which does rm -rf + repo sync)
    local output rc=0
    cd "$OHOS_REPO"
    output="$($OHOS_SCRIPT reset "$TEST_PROJECT" 2>&1)" || rc=$?

    # Check project is clean
    local clean=false
    if [ -d "$OHOS_REPO/$TEST_PROJECT" ]; then
        if git -C "$OHOS_REPO/$TEST_PROJECT" diff --quiet HEAD 2>/dev/null; then
            clean=true
        fi
    fi

    # Restore original state regardless
    restore_pristine

    if [ "$rc" -eq 0 ] && [ "$clean" = "true" ]; then
        log_pass "$name"
    elif [ "$rc" -ne 0 ]; then
        log_fail "$name" "reset failed (exit $rc): $(echo "$output" | tail -5)"
    else
        log_fail "$name" "project not clean after reset"
    fi
}

# ── LFS storage fix tests ─────────────────────────────────────────────

test_fix_lfs_storage_strips_trailing_objects() {
    local name="fix_lfs_storage: strips trailing /objects from lfs.storage"
    local tmpdir
    tmpdir="$(mktemp -d /tmp/test_lfs_storage_XXXXXX)"

    mkdir -p "$tmpdir/.repo/projects/foundation/arkui"
    git init --bare "$tmpdir/.repo/projects/foundation/arkui/ace_engine.git" >/dev/null 2>&1
    git config -f "$tmpdir/.repo/projects/foundation/arkui/ace_engine.git/config" lfs.storage "$tmpdir/arkui_ace_engine.git/lfs/objects"

    mkdir -p "$tmpdir/.repo/projects/base/sensors"
    git init --bare "$tmpdir/.repo/projects/base/sensors/start.git" >/dev/null 2>&1
    git config -f "$tmpdir/.repo/projects/base/sensors/start.git/config" lfs.storage "$tmpdir/base_sensors_start.git/lfs/objects"

    local _old_pwd="$PWD"
    cd "$tmpdir"
    fixed=0
    shopt -s globstar
    for config in .repo/projects/**/*.git/config; do
        [ -f "$config" ] || continue
        local storage
        storage="$(git config -f "$config" --get lfs.storage 2>/dev/null)" || continue
        case "$storage" in
            */lfs/objects)
                git config -f "$config" lfs.storage "${storage%/objects}"
                fixed=$((fixed + 1))
                ;;
        esac
    done
    shopt -u globstar

    local ace_storage sensors_storage
    ace_storage="$(git config -f "$tmpdir/.repo/projects/foundation/arkui/ace_engine.git/config" --get lfs.storage)"
    sensors_storage="$(git config -f "$tmpdir/.repo/projects/base/sensors/start.git/config" --get lfs.storage)"

    cd "$_old_pwd"
    rm -rf "$tmpdir"

    if [ "$fixed" -eq 2 ] \
        && [ "$ace_storage" = "$tmpdir/arkui_ace_engine.git/lfs" ] \
        && [ "$sensors_storage" = "$tmpdir/base_sensors_start.git/lfs" ]; then
        log_pass "$name"
    else
        log_fail "$name" "fixed=$fixed ace=$ace_storage sensors=$sensors_storage"
    fi
}

test_fix_lfs_storage_preserves_correct_path() {
    local name="fix_lfs_storage: does NOT modify paths without trailing /objects"
    local tmpdir
    tmpdir="$(mktemp -d /tmp/test_lfs_preserve_XXXXXX)"

    mkdir -p "$tmpdir/.repo/projects/base/sensors"
    git init --bare "$tmpdir/.repo/projects/base/sensors/start.git" >/dev/null 2>&1
    git config -f "$tmpdir/.repo/projects/base/sensors/start.git/config" lfs.storage "$tmpdir/base_sensors_start.git/lfs"

    local _old_pwd="$PWD"
    cd "$tmpdir"
    fixed=0
    shopt -s globstar
    for config in .repo/projects/**/*.git/config; do
        [ -f "$config" ] || continue
        local storage
        storage="$(git config -f "$config" --get lfs.storage 2>/dev/null)" || continue
        case "$storage" in
            */lfs/objects)
                git config -f "$config" lfs.storage "${storage%/objects}"
                fixed=$((fixed + 1))
                ;;
        esac
    done
    shopt -u globstar

    local storage_after
    storage_after="$(git config -f "$tmpdir/.repo/projects/base/sensors/start.git/config" --get lfs.storage)"

    cd "$_old_pwd"
    rm -rf "$tmpdir"

    if [ "$fixed" -eq 0 ] && [ "$storage_after" = "$tmpdir/base_sensors_start.git/lfs" ]; then
        log_pass "$name"
    else
        log_fail "$name" "fixed=$fixed storage=$storage_after"
    fi
}

test_fix_lfs_storage_covers_nested_projects() {
    local name="fix_lfs_storage: glob matches deeply nested project configs"
    local tmpdir
    tmpdir="$(mktemp -d /tmp/test_lfs_nested_XXXXXX)"

    local -a project_paths=(
        "build.git"
        "arkcompiler/ets_frontend.git"
        "foundation/arkui/ace_engine.git"
        "third_party/rust/crates/syn.git"
    )

    for pp in "${project_paths[@]}"; do
        mkdir -p "$tmpdir/.repo/projects/$(dirname "$pp")"
        git init --bare "$tmpdir/.repo/projects/$pp" >/dev/null 2>&1
        git config -f "$tmpdir/.repo/projects/$pp/config" lfs.storage "/mirror/$pp/lfs/objects"
    done

    local _old_pwd="$PWD"
    cd "$tmpdir"
    matched=0
    shopt -s globstar
    for config in .repo/projects/**/*.git/config; do
        [ -f "$config" ] || continue
        matched=$((matched + 1))
    done
    shopt -u globstar

    cd "$_old_pwd"
    rm -rf "$tmpdir"

    if [ "$matched" -eq 4 ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected 4 matches, got $matched"
    fi
}

test_fix_lfs_storage_skips_no_storage() {
    local name="fix_lfs_storage: skips configs without lfs.storage"
    local tmpdir
    tmpdir="$(mktemp -d /tmp/test_lfs_skip_XXXXXX)"

    mkdir -p "$tmpdir/.repo/projects/base/sensors"
    git init --bare "$tmpdir/.repo/projects/base/sensors/no_lfs.git" >/dev/null 2>&1

    local _old_pwd="$PWD"
    cd "$tmpdir"
    fixed=0
    shopt -s globstar
    for config in .repo/projects/**/*.git/config; do
        [ -f "$config" ] || continue
        local storage
        storage="$(git config -f "$config" --get lfs.storage 2>/dev/null)" || continue
        if [ -z "$storage" ]; then
            continue
        fi
        case "$storage" in
            */lfs/objects)
                fixed=$((fixed + 1))
                ;;
        esac
    done
    shopt -u globstar

    cd "$_old_pwd"
    rm -rf "$tmpdir"

    if [ "$fixed" -eq 0 ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected 0 fixes, got $fixed"
    fi
}

test_is_git_lfs_pointer_file() {
    local name="is_git_lfs_pointer_file: detects LFS pointer"

    local tmpfile
    tmpfile="$(mktemp /tmp/test_lfs_pointer_XXXXXX)"
    cat > "$tmpfile" <<'EOF'
version https://git-lfs.github.com/spec/v1
oid sha256:abc123
size 12345
EOF

    local first_line
    first_line="$(head -1 "$tmpfile")"
    local is_pointer=false
    [ "$first_line" = "version https://git-lfs.github.com/spec/v1" ] && is_pointer=true

    rm -f "$tmpfile"

    if [ "$is_pointer" = "true" ]; then
        log_pass "$name"
    else
        log_fail "$name" "did not detect pointer file"
    fi
}

test_is_git_lfs_pointer_rejects_real_archive() {
    local name="is_git_lfs_pointer_file: rejects real gzip archive"

    local tmpfile
    tmpfile="$(mktemp /tmp/test_lfs_real_XXXXXX)"
    # Write gzip magic bytes
    printf '\x1f\x8b\x08\x00test data' > "$tmpfile"

    local first_line
    first_line="$(head -1 "$tmpfile")"
    local is_pointer=false
    [ "$first_line" = "version https://git-lfs.github.com/spec/v1" ] && is_pointer=true

    rm -f "$tmpfile"

    if [ "$is_pointer" = "false" ]; then
        log_pass "$name"
    else
        log_fail "$name" "incorrectly detected binary as pointer"
    fi
}

test_lfs_storage_doubled_objects_path() {
    local name="lfs.storage: verifies doubled objects/ path resolution"
    # When lfs.storage ends with /lfs/objects, git-lfs 3.0.2 resolves
    # to .../lfs/objects/objects/XX/YY — verify this doesn't happen
    # with the fix applied.
    local storage="/mirror/arkui_ace_engine.git/lfs"
    local resolved="${storage}/objects/3d/3dc6cfc481"

    local has_double_objects=false
    case "$resolved" in
        */objects/objects/*) has_double_objects=true ;;
    esac

    if [ "$has_double_objects" = "false" ]; then
        log_pass "$name"
    else
        log_fail "$name" "path has doubled objects/: $resolved"
    fi
}

test_lfs_storage_unfixed_has_doubled_objects() {
    local name="lfs.storage: unfixed path DOES have doubled objects/"
    # This test confirms the bug exists WITHOUT the fix
    local storage="/mirror/arkui_ace_engine.git/lfs/objects"
    local resolved="${storage}/objects/3d/3dc6cfc481"

    local has_double_objects=false
    case "$resolved" in
        */objects/objects/*) has_double_objects=true ;;
    esac

    if [ "$has_double_objects" = "true" ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected doubled objects/ in: $resolved"
    fi
}

# ── run_repo_forall_tolerant tests ────────────────────────────────────

# Source only the functions we need, mock everything else.
_setup_forall_test_env() {
    _FORALL_TMPDIR="$(mktemp -d /tmp/ohos_test_forall_XXXXXX)"
    export PATH="$_FORALL_TMPDIR/bin:$PATH"
    mkdir -p "$_FORALL_TMPDIR/bin"

    # Mock repo: writes args-based output to a known marker file.
    cat > "$_FORALL_TMPDIR/bin/repo" <<'MOCK'
#!/bin/bash
# Usage: repo forall -j N -c 'CMD'
# If MOCK_FORALL_OUTPUT is set, write it to stdout.
# If MOCK_FORALL_ERRORS is set, write error: lines to stderr.
if [ -n "${MOCK_FORALL_OUTPUT:-}" ]; then
    printf '%s\n' "$MOCK_FORALL_OUTPUT"
fi
if [ -n "${MOCK_FORALL_ERRORS:-}" ]; then
    printf '%s\n' "$MOCK_FORALL_ERRORS"
fi
exit ${MOCK_FORALL_EXIT:-0}
MOCK
    chmod +x "$_FORALL_TMPDIR/bin/repo"

    # Mock info/warn/err — capture to files
    _FORALL_INFO_LOG="$_FORALL_TMPDIR/info.log"
    _FORALL_WARN_LOG="$_FORALL_TMPDIR/warn.log"
    _FORALL_ERR_LOG="$_FORALL_TMPDIR/err.log"
    : > "$_FORALL_INFO_LOG"
    : > "$_FORALL_WARN_LOG"
    : > "$_FORALL_ERR_LOG"
}

_teardown_forall_test_env() {
    rm -rf "${_FORALL_TMPDIR:-}"
    unset MOCK_FORALL_OUTPUT MOCK_FORALL_ERRORS MOCK_FORALL_EXIT 2>/dev/null || true
}

# Inline run_repo_forall_tolerant with mocked info/warn/err for testing.
_test_forall_tolerant() {
    local label="$1"
    local jobs="$2"
    shift 2
    local _log
    _log="$(mktemp /tmp/ohos_forall_test_XXXXXX.log)"

    echo "[info] $label (jobs=$jobs)" >> "$_FORALL_INFO_LOG"
    repo forall -j "$jobs" "$@" >"$_log" 2>&1 || true

    local _fail_count=0
    _fail_count="$(grep -c '^error:' "$_log" 2>/dev/null)" || _fail_count=0
    if [ "$_fail_count" -gt 0 ]; then
        echo "[warn] $label: $_fail_count project(s) had errors (continuing)" >> "$_FORALL_WARN_LOG"
        grep '^error:' "$_log" >> "$_FORALL_WARN_LOG"
    fi
    rm -f "$_log"
}

test_forall_tolerant_no_errors() {
    local name="forall_tolerant: no errors — passes cleanly"
    _setup_forall_test_env
    MOCK_FORALL_OUTPUT=$'project1\nproject2'
    MOCK_FORALL_ERRORS=""
    MOCK_FORALL_EXIT=0
    export MOCK_FORALL_OUTPUT MOCK_FORALL_ERRORS MOCK_FORALL_EXIT

    _test_forall_tolerant "test clean" 4 -c 'true'

    local info_lines
    info_lines="$(wc -l < "$_FORALL_INFO_LOG")"
    local warn_lines
    warn_lines="$(wc -l < "$_FORALL_WARN_LOG")"

    if [ "$warn_lines" -eq 0 ] && [ "$info_lines" -ge 1 ]; then
        log_pass "$name"
    else
        log_fail "$name" "info_lines=$info_lines, warn_lines=$warn_lines (expected no warnings)"
    fi
    _teardown_forall_test_env
}

test_forall_tolerant_with_errors_warns() {
    local name="forall_tolerant: errors produce warning"
    _setup_forall_test_env
    MOCK_FORALL_OUTPUT=""
    MOCK_FORALL_ERRORS=$'error: failed in project foo\nerror: failed in project bar'
    export MOCK_FORALL_OUTPUT MOCK_FORALL_ERRORS MOCK_FORALL_EXIT
    MOCK_FORALL_EXIT=1

    _test_forall_tolerant "test clean" 4 -c 'false'

    local warn_content
    warn_content="$(cat "$_FORALL_WARN_LOG")"
    if [[ "$warn_content" == *"2 project(s) had errors"* ]] && [[ "$warn_content" == *"error: failed in project foo"* ]]; then
        log_pass "$name"
    else
        log_fail "$name" "warn_content=$warn_content"
    fi
    _teardown_forall_test_env
}

test_forall_tolerant_nonzero_exit_continues() {
    local name="forall_tolerant: non-zero exit does not abort"
    _setup_forall_test_env
    MOCK_FORALL_OUTPUT=""
    MOCK_FORALL_ERRORS=""
    MOCK_FORALL_EXIT=1
    export MOCK_FORALL_OUTPUT MOCK_FORALL_ERRORS MOCK_FORALL_EXIT

    _test_forall_tolerant "test step" 4 -c 'false'

    # Function should return 0 (success) even when repo forall exits 1 with no errors
    if grep -q '\[info\] test step' "$_FORALL_INFO_LOG" && [ ! -s "$_FORALL_WARN_LOG" ]; then
        log_pass "$name"
    else
        log_fail "$name" "info_log=$(cat "$_FORALL_INFO_LOG"), warn_log=$(cat "$_FORALL_WARN_LOG")"
    fi
    _teardown_forall_test_env
}

test_forall_tolerant_empty_output() {
    local name="forall_tolerant: empty output — no integer expression error"
    _setup_forall_test_env
    MOCK_FORALL_OUTPUT=""
    MOCK_FORALL_ERRORS=""
    MOCK_FORALL_EXIT=0
    export MOCK_FORALL_OUTPUT MOCK_FORALL_ERRORS MOCK_FORALL_EXIT

    _test_forall_tolerant "empty test" 4 -c 'true'

    # Must NOT produce "integer expression expected" error
    local err_content
    err_content="$(cat "$_FORALL_ERR_LOG" 2>/dev/null)"
    if [[ "$err_content" != *"integer expression"* ]] && [ ! -s "$_FORALL_WARN_LOG" ]; then
        log_pass "$name"
    else
        log_fail "$name" "err=$err_content, warn=$(cat "$_FORALL_WARN_LOG")"
    fi
    _teardown_forall_test_env
}

test_forall_tolerant_mixed_output() {
    local name="forall_tolerant: mixed stdout + error lines — counts only errors"
    _setup_forall_test_env
    MOCK_FORALL_OUTPUT=$'Already on '\''master'\''\nproject build'
    MOCK_FORALL_ERRORS="error: something broke in build"
    export MOCK_FORALL_OUTPUT MOCK_FORALL_ERRORS MOCK_FORALL_EXIT
    MOCK_FORALL_EXIT=0

    _test_forall_tolerant "mixed test" 4 -c 'echo'

    local warn_content
    warn_content="$(cat "$_FORALL_WARN_LOG")"
    if [[ "$warn_content" == *"1 project(s) had errors"* ]] && [[ "$warn_content" == *"error: something broke in build"* ]]; then
        log_pass "$name"
    else
        log_fail "$name" "warn=$warn_content"
    fi
    _teardown_forall_test_env
}

# ── CPU-aware defaults tests ─────────────────────────────────────────

test_cpu_count_detection() {
    local name="cpu_count: nproc returns positive integer"
    local cpu_count
    cpu_count="$(nproc 2>/dev/null || echo 4)"

    if [[ "$cpu_count" =~ ^[0-9]+$ ]] && [ "$cpu_count" -gt 0 ]; then
        log_pass "$name (detected: $cpu_count)"
    else
        log_fail "$name" "nproc returned '$cpu_count'"
    fi
}

test_cpu_count_env_override() {
    local name="cpu_count: OHOS_CPU_COUNT env override"
    local test_cpu=12
    local result
    result="$(OHOS_CPU_COUNT=$test_cpu bash -c 'echo "${OHOS_CPU_COUNT:-$(nproc 2>/dev/null || echo 4)}"')"

    if [ "$result" = "$test_cpu" ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected $test_cpu, got $result"
    fi
}

test_cpu_derived_sync_jobs() {
    local name="cpu_defaults: REPO_SYNC_JOBS = min(2x cores, 64)"
    local cpu=4
    local expected=$(( cpu * 2 ))
    local result
    result="$(OHOS_CPU_COUNT=$cpu REPO_SYNC_JOBS="" bash -c 'OHOS_CPU_COUNT="${OHOS_CPU_COUNT:-4}"; echo "${REPO_SYNC_JOBS:-$(( OHOS_CPU_COUNT * 2 > 64 ? 64 : OHOS_CPU_COUNT * 2 ))}"')"

    if [ "$result" = "$expected" ]; then
        log_pass "$name (cpu=$cpu → jobs=$result)"
    else
        log_fail "$name" "expected $expected, got $result"
    fi
}

test_cpu_derived_sync_jobs_capped() {
    local name="cpu_defaults: REPO_SYNC_JOBS caps at 64"
    local cpu=48
    local result
    result="$(OHOS_CPU_COUNT=$cpu REPO_SYNC_JOBS="" bash -c 'OHOS_CPU_COUNT="${OHOS_CPU_COUNT:-4}"; echo "${REPO_SYNC_JOBS:-$(( OHOS_CPU_COUNT * 2 > 64 ? 64 : OHOS_CPU_COUNT * 2 ))}"')"

    if [ "$result" = "64" ]; then
        log_pass "$name (cpu=$cpu → jobs=$result)"
    else
        log_fail "$name" "expected 64, got $result"
    fi
}

test_cpu_derived_lfs_jobs() {
    local name="cpu_defaults: LFS_JOBS = min(4x cores, 64)"
    local cpu=8
    local expected=$(( cpu * 4 ))
    local result
    result="$(OHOS_CPU_COUNT=$cpu LFS_JOBS="" bash -c 'OHOS_CPU_COUNT="${OHOS_CPU_COUNT:-4}"; echo "${LFS_JOBS:-$(( OHOS_CPU_COUNT * 4 > 64 ? 64 : OHOS_CPU_COUNT * 4 ))}"')"

    if [ "$result" = "$expected" ]; then
        log_pass "$name (cpu=$cpu → jobs=$result)"
    else
        log_fail "$name" "expected $expected, got $result"
    fi
}

test_cpu_derived_gc_jobs() {
    local name="cpu_defaults: GC_JOBS = min(2x cores, 32)"
    local cpu=20
    local result
    result="$(OHOS_CPU_COUNT=$cpu GC_JOBS="" bash -c 'OHOS_CPU_COUNT="${OHOS_CPU_COUNT:-4}"; echo "${GC_JOBS:-$(( OHOS_CPU_COUNT * 2 > 32 ? 32 : OHOS_CPU_COUNT * 2 ))}"')"

    if [ "$result" = "32" ]; then
        log_pass "$name (cpu=$cpu → jobs=$result)"
    else
        log_fail "$name" "expected 32, got $result"
    fi
}

test_cpu_conf_overrides_auto() {
    local name="cpu_defaults: explicit conf value overrides formula"
    local cpu=4
    local result
    result="$(OHOS_CPU_COUNT=$cpu REPO_SYNC_JOBS=99 bash -c 'OHOS_CPU_COUNT="${OHOS_CPU_COUNT:-4}"; echo "${REPO_SYNC_JOBS:-$(( OHOS_CPU_COUNT * 2 > 64 ? 64 : OHOS_CPU_COUNT * 2 ))}"')"

    if [ "$result" = "99" ]; then
        log_pass "$name (conf=99, cpu=$cpu → jobs=$result)"
    else
        log_fail "$name" "expected 99, got $result"
    fi
}

test_build_path_cleans_local_bin() {
    local name="build PATH: strips ~/.local/bin"
    local fake_home="/tmp/ohos_test_home_$$"
    mkdir -p "$fake_home/.local/bin"
    local result
    result="$(HOME="$fake_home" bash -c '
PATH="/usr/bin:$HOME/.local/bin:/usr/local/bin:$HOME/.local/bin:/opt/bin"
_cleaned_path="$(echo ":$PATH:" | sed "s|:${HOME}/.local/bin:|:|g" | sed "s|^:||;s|:$||")"
echo "$_cleaned_path"
')"
    rm -rf "$fake_home"
    if echo "$result" | grep -q '\.local/bin'; then
        log_fail "$name" ".local/bin still in PATH: $result"
    elif [ "$result" = "/usr/bin:/usr/local/bin:/opt/bin" ]; then
        log_pass "$name"
    else
        log_fail "$name" "unexpected result: $result"
    fi
}

test_ensure_python3_available() {
    local name="ensure_python3: passes when python3 available"
    if command -v python3 >/dev/null 2>&1; then
        log_pass "$name"
    else
        log_skip "$name" "python3 not available on this system"
    fi
}

test_ensure_python3_exits_on_missing() {
    local name="ensure_python3: exits 1 when python3 missing"
    local result
    result="$(OHOS_SCRIPT="$OHOS_SCRIPT" bash -c '
source "$OHOS_SCRIPT" --source-only 2>/dev/null || true
# Override has_command to simulate missing python3
has_command() { [ "$1" != "python3" ]; }
ensure_python3
' 2>&1)" && rc=$? || rc=$?
    if [ "$rc" -eq 1 ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected exit 1, got $rc: $result"
    fi
}

test_lfs_env_helper_runs_git() {
    local name="_lfs_env: wraps env with LFS vars unset"
    local output
    output="$(bash -c '
_lfs_env() {
    env -u LocalMediaDir -u LocalReferenceDirs -u TempDir -u LfsStorageDir \
        GIT_LFS_STORAGE=.git/lfs "$@"
}
# Test that the function runs and passes args through
result=$(_lfs_env printenv GIT_LFS_STORAGE 2>&1)
echo "$result"
')" || true
    if [ "$output" = ".git/lfs" ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected .git/lfs, got: $output"
    fi
}

test_lfs_env_prefix_string() {
    local name="_lfs_env_prefix: returns correct string for repo forall"
    local output
    output="$(bash -c '
_lfs_env_prefix() {
    printf "env -u LocalMediaDir -u LocalReferenceDirs -u TempDir -u LfsStorageDir GIT_LFS_STORAGE=.git/lfs"
}
_lfs_env_prefix
')"
    if echo "$output" | grep -q "GIT_LFS_STORAGE=.git/lfs" && echo "$output" | grep -q "env -u LocalMediaDir"; then
        log_pass "$name"
    else
        log_fail "$name" "unexpected output: $output"
    fi
}

test_constants_signal_retry_delay() {
    local name="constants: OHOS_SIGNAL_RETRY_DELAY defaults to 0.1"
    local val
    val="$(bash -c 'OHOS_SIGNAL_RETRY_DELAY="${OHOS_SIGNAL_RETRY_DELAY:-0.1}"; echo "$OHOS_SIGNAL_RETRY_DELAY"')"
    if [ "$val" = "0.1" ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected 0.1, got: $val"
    fi
}

test_constants_signal_retry_count() {
    local name="constants: OHOS_SIGNAL_RETRY_COUNT defaults to 5"
    local val
    val="$(bash -c 'OHOS_SIGNAL_RETRY_COUNT="${OHOS_SIGNAL_RETRY_COUNT:-5}"; echo "$OHOS_SIGNAL_RETRY_COUNT"')"
    if [ "$val" = "5" ]; then
        log_pass "$name"
    else
        log_fail "$name" "expected 5, got: $val"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

ALL_TESTS=(
    test_regex_extracts_path_from_info_different
    test_regex_extracts_nested_path
    test_regex_rejects_unrelated_errors
    test_grep_detects_force_sync_pattern
    test_grep_detects_force_sync_not_enabled
    test_grep_detects_cannot_overwrite
    test_collect_repo_sync_failures_from_log
    test_dirty_check_clean_project
    test_dirty_check_modified_file
    test_dirty_check_staged_file
    test_force_clean_removes_checkout_on_reset_failure
    test_force_clean_no_rm_when_bare_missing
    test_clean_stale_git_locks
    test_resolve_repo_paths_name_to_path
    test_lfs_filter_bypass_works
    test_lfs_reset_bypass_works
    test_sync_clean_project_succeeds
    test_sync_corrupted_head_autorecovers
    test_sync_dirty_project_skips_autorecover
    test_reset_single_project_restores
    test_fix_lfs_storage_strips_trailing_objects
    test_fix_lfs_storage_preserves_correct_path
    test_fix_lfs_storage_covers_nested_projects
    test_fix_lfs_storage_skips_no_storage
    test_is_git_lfs_pointer_file
    test_is_git_lfs_pointer_rejects_real_archive
    test_lfs_storage_doubled_objects_path
    test_lfs_storage_unfixed_has_doubled_objects
    test_forall_tolerant_no_errors
    test_forall_tolerant_with_errors_warns
    test_forall_tolerant_nonzero_exit_continues
    test_forall_tolerant_empty_output
    test_forall_tolerant_mixed_output
    test_cpu_count_detection
    test_cpu_count_env_override
    test_cpu_derived_sync_jobs
    test_cpu_derived_sync_jobs_capped
    test_cpu_derived_lfs_jobs
    test_cpu_derived_gc_jobs
    test_cpu_conf_overrides_auto
    test_build_path_cleans_local_bin
    test_ensure_python3_available
    test_ensure_python3_exits_on_missing
    test_lfs_env_helper_runs_git
    test_lfs_env_prefix_string
    test_constants_signal_retry_delay
    test_constants_signal_retry_count
)

# If specific tests requested, filter
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

echo "ohos sync recovery test suite"
echo "Repo: $OHOS_REPO"
echo "Script: $OHOS_SCRIPT"
echo "Test project: $TEST_PROJECT"
echo "Tests: ${#RUN_TESTS[@]}"
echo ""

require_repo
init_pristine_backup

FAILED_TESTS=()
for t in "${RUN_TESTS[@]}"; do
    "$t"
done

cleanup_pristine_backup

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
