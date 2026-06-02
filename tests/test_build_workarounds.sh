#!/bin/bash
# test_build_workarounds.sh — verify build-workarounds apply/revert logic
#
# Run: bash tests/test_build_workarounds.sh
# Requires: git, a temp directory
set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_true() {
    local desc="$1"
    if eval "$2"; then
        echo "  PASS: $desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $desc"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $desc (expected to contain '$needle')"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

summary() {
    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped ==="
    [ "$FAIL_COUNT" -eq 0 ] || exit 1
}

cleanup() {
    rm -rf "$TEST_DIR"
}

# ----------------------------------------------------------------
# Test: _parse_workarounds_for_target returns expected entries
# ----------------------------------------------------------------
test_parse_config() {
    echo ""
    echo "=== Test: _parse_workarounds_for_target returns expected PRs ==="

    local test_target="xts-static"

    # Source the library
    SCRIPT_DIR="$PROJECT_DIR"
    WORKAROUNDS_CONF="$PROJECT_DIR/build-workarounds.yaml"
    source "$PROJECT_DIR/ohos_build_workarounds.sh"

    local result
    result="$(_parse_workarounds_for_target "$test_target")" || true

    local count
    count="$(echo "$result" | grep -c .)" || count=0
    assert_eq "xts-static has 5 workarounds" "5" "$count"

    assert_contains "contains interface/sdk-js PR 33070" "interface/sdk-js|33070" "$result"
    assert_contains "contains ets_frontend PR 10773" "arkcompiler/ets_frontend|10773" "$result"
    assert_contains "contains ace_ets2bundle PR 6751" "developtools/ace_ets2bundle|6751" "$result"
    assert_contains "contains ets_frontend PR 9996" "arkcompiler/ets_frontend|9996" "$result"

    # Unknown target should return nothing
    local nothing
    nothing="$(_parse_workarounds_for_target "nonexistent_target")" || true
    assert_eq "unknown target returns empty" "" "$nothing"
}

# ----------------------------------------------------------------
# Test: apply and revert workarounds on temp git repos
# ----------------------------------------------------------------
test_apply_revert() {
    echo ""
    echo "=== Test: apply and revert workarounds on temp git repos ==="

    TEST_DIR="$(mktemp -d /tmp/ohos-test-workarounds-XXXXXX)"

    # Create two fake repos with an initial commit
    mkdir -p "$TEST_DIR/repo1" "$TEST_DIR/repo2"

    # repo1: initial commit
    cd "$TEST_DIR/repo1"
    git init -q
    echo "base" > file.txt
    git add -A
    git commit -q -m "Initial commit repo1"
    local repo1_base
    repo1_base="$(git rev-parse HEAD)"

    # repo2: initial commit  
    cd "$TEST_DIR/repo2"
    git init -q
    echo "base" > file.txt
    git add -A
    git commit -q -m "Initial commit repo2"
    local repo2_base
    repo2_base="$(git rev-parse HEAD)"

    # Create a bare remote repo to simulate GitCode
    mkdir -p "$TEST_DIR/remote1"
    cd "$TEST_DIR/remote1"
    git init -q --bare

    # Build a simulated "PR" on a separate branch with Gitee-style ref
    cd "$TEST_DIR/repo1"
    git remote add origin "$TEST_DIR/remote1"
    git checkout -q -b pr_42
    echo "pr_content" >> file.txt
    git add -A
    git commit -q -m "PR #42 change"
    # Push as Gitee-style merge-requests ref
    git push origin "HEAD:refs/merge-requests/42/head" -q 2>/dev/null

    # Go back to master — master should NOT have the PR commit
    git checkout -q master

    # Create a minimal workarounds config
    local test_config="$TEST_DIR/workarounds.yaml"
    cat > "$test_config" <<EOF
# test config
test-target:
  - repo: repo1
    pr: 42
    remote: file://$TEST_DIR/remote1
    description: "test PR"
  - repo: repo2
    pr: 99
    remote: file://$TEST_DIR/remote1
    description: "second test (will fail fetch, optional)"
    optional: true
EOF

    # Source the library with test config
    SCRIPT_DIR="$TEST_DIR"
    WORKAROUNDS_CONF="$test_config"
    source "$PROJECT_DIR/ohos_build_workarounds.sh"

    # Apply
    echo "  --- Applying workarounds ---"
    apply_build_workarounds "test-target" "$TEST_DIR" || true

    cd "$TEST_DIR/repo1"
    local head_msg
    head_msg="$(git log --oneline -1 HEAD)"
    assert_contains "repo1 has PR #42 merged" "PR #42" "$head_msg"

    cd "$TEST_DIR/repo2"
    local repo2_head
    repo2_head="$(git rev-parse HEAD)"
    assert_eq "repo2 stays at base (optional PR not fetched)" "$repo2_base" "$repo2_head"

    # Revert
    echo "  --- Reverting workarounds ---"
    revert_build_workarounds "test-target" "$TEST_DIR" || true

    cd "$TEST_DIR/repo1"
    local reverted_head
    reverted_head="$(git rev-parse HEAD)"
    assert_eq "repo1 reverted to base commit" "$repo1_base" "$reverted_head"

    # Revert again — should be idempotent
    echo "  --- Reverting again (idempotent) ---"
    revert_build_workarounds "test-target" "$TEST_DIR" || true

    cd "$TEST_DIR/repo1"
    local reverted2_head
    reverted2_head="$(git rev-parse HEAD)"
    assert_eq "second revert is idempotent" "$repo1_base" "$reverted2_head"

    rm -rf "$TEST_DIR"
}

# ----------------------------------------------------------------
# Run
# ----------------------------------------------------------------
test_parse_config
test_apply_revert
summary
cleanup 2>/dev/null || true
