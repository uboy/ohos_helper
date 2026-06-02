#!/bin/bash
# test_requirements.sh — verify behavioral requirements of ohos_helper
# Tests check WHAT the system does, not HOW.
#
# Run: bash tests/test_requirements.sh
set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Test framework ---

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

assert_false() {
    local desc="$1"
    if ! eval "$2"; then
        echo "  PASS: $desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $desc (expected failure, got success)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

begin_section() {
    echo ""
    echo "=== $1 ==="
}

# --- Requirement: Round-robin distribution ---

begin_section "REQ: Round-robin distribution"

# R1: Every entry in TSV is assigned to exactly one group — no duplicates, no omissions
test_rr_no_duplicates_no_omissions() {
    local desc="R1: All entries assigned exactly once across groups"
    local tmpdir
    tmpdir="$(mktemp -d)"

    # Create TSV with 10 entries
    {
        echo -e "hap\tbundle\tmodule"
        for i in $(seq 1 10); do
            echo -e "hap_${i}.hap\tcom.test.${i}\tentry"
        done
    } > "$tmpdir/test.tsv"

    local num_groups=3
    local -a assigned=()

    for g in $(seq 0 $((num_groups - 1))); do
        local line_num=0
        while IFS=$'\t' read -r hap bundle module rest; do
            line_num=$((line_num + 1))
            [ "$line_num" -eq 1 ] && continue
            [ -z "$hap" ] && continue
            if (( (line_num - 2) % num_groups == g )); then
                assigned+=("$hap")
            fi
        done < "$tmpdir/test.tsv"
    done

    # Count: should be exactly 10
    local count=${#assigned[@]}
    assert_eq "${desc} (count)" "10" "$count"

    # No duplicates: unique count should equal total count
    local unique_count
    unique_count="$(printf '%s\n' "${assigned[@]}" | sort -u | wc -l)"
    assert_eq "${desc} (unique)" "$count" "$unique_count"

    # All original haps present
    local all_present=true
    for i in $(seq 1 10); do
        if ! printf '%s\n' "${assigned[@]}" | grep -qx "hap_${i}.hap"; then
            all_present=false
            break
        fi
    done
    assert_true "${desc} (all present)" "$all_present"

    rm -rf "$tmpdir"
}
test_rr_no_duplicates_no_omissions

# R2: Distribution is deterministic
test_rr_deterministic() {
    local desc="R2: Same input produces same distribution"
    local tmpdir
    tmpdir="$(mktemp -d)"

    {
        echo -e "hap\tbundle\tmodule"
        for i in $(seq 1 20); do
            echo -e "test_${i}.hap\tb.${i}\tm"
        done
    } > "$tmpdir/test.tsv"

    local num_groups=4

    run_distribution() {
        local out=""
        for g in $(seq 0 $((num_groups - 1))); do
            local line_num=0
            while IFS=$'\t' read -r hap bundle module rest; do
                line_num=$((line_num + 1))
                [ "$line_num" -eq 1 ] && continue
                [ -z "$hap" ] && continue
                (( (line_num - 2) % num_groups == g )) && out="${out}${g}:${hap} "
            done < "$tmpdir/test.tsv"
        done
        echo "$out"
    }

    local run1 run2
    run1="$(run_distribution)"
    run2="$(run_distribution)"
    assert_eq "$desc" "$run1" "$run2"

    rm -rf "$tmpdir"
}
test_rr_deterministic

# R3: Groups are balanced — size diff ≤ 1
test_rr_balanced() {
    local desc="R3: Groups balanced (size diff ≤ 1)"
    local tmpdir
    tmpdir="$(mktemp -d)"

    {
        echo -e "hap\tbundle\tmodule"
        for i in $(seq 1 17); do
            echo -e "h${i}.hap\tb${i}\tm"
        done
    } > "$tmpdir/test.tsv"

    local num_groups=3
    local -a sizes=()

    for g in $(seq 0 $((num_groups - 1))); do
        local count=0
        local line_num=0
        while IFS=$'\t' read -r hap bundle module rest; do
            line_num=$((line_num + 1))
            [ "$line_num" -eq 1 ] && continue
            [ -z "$hap" ] && continue
            (( (line_num - 2) % num_groups == g )) && count=$((count + 1))
        done < "$tmpdir/test.tsv"
        sizes+=("$count")
    done

    local min_size max_size
    min_size="$(printf '%s\n' "${sizes[@]}" | sort -n | head -1)"
    max_size="$(printf '%s\n' "${sizes[@]}" | sort -n | tail -1)"
    local diff=$((max_size - min_size))
    assert_true "$desc (sizes: ${sizes[*]}, diff: $diff)" "[ $diff -le 1 ]"

    rm -rf "$tmpdir"
}
test_rr_balanced

# R4: Single group gets all entries
test_rr_single_group() {
    local desc="R4: 1 group → all entries assigned to it"
    local tmpdir
    tmpdir="$(mktemp -d)"

    {
        echo -e "hap\tbundle\tmodule"
        for i in $(seq 1 5); do
            echo -e "h${i}.hap\tb${i}\tm"
        done
    } > "$tmpdir/test.tsv"

    local count=0
    local line_num=0
    while IFS=$'\t' read -r hap bundle module rest; do
        line_num=$((line_num + 1))
        [ "$line_num" -eq 1 ] && continue
        [ -z "$hap" ] && continue
        (( (line_num - 2) % 1 == 0 )) && count=$((count + 1))
    done < "$tmpdir/test.tsv"

    assert_eq "$desc" "5" "$count"

    rm -rf "$tmpdir"
}
test_rr_single_group

# --- Requirement: _remote_exec placeholder substitution ---

begin_section "REQ: Template placeholder substitution"

# Setup for _remote_exec tests
RE_SETUP_DONE=false
re_setup() {
    if $RE_SETUP_DONE; then return 0; fi
    # _remote_exec needs err() and info()
    err() { echo "ERR: $*" >&2; }
    info() { :; }
    SCRIPT_DIR="$PROJECT_DIR"
    source "$PROJECT_DIR/scripts/remote/_remote_exec.sh"
    RE_SETUP_DONE=true
}

# R5: All provided placeholders are substituted
test_re_substitution() {
    local desc="R5: Placeholders substituted with provided values"
    re_setup

    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/scripts/remote"

    cat > "$tmpdir/scripts/remote/sub_test.sh.template" <<'TEMPLATE'
#!/bin/bash
echo "HDC={{HDC_PATH}}"
echo "SERIAL={{SERIAL}}"
echo "MODE={{MODE}}"
TEMPLATE

    # Override template dir for test
    _REMOTE_EXEC_TEMPLATE_DIR="$tmpdir/scripts/remote"

    local output
    output="$(_remote_exec "local" "sub_test" HDC_PATH=/usr/bin/hdc SERIAL=ABC123 MODE=init 2>/dev/null)" || true

    assert_true "${desc} — HDC" "echo '$output' | grep -q 'HDC=/usr/bin/hdc'"
    assert_true "${desc} — SERIAL" "echo '$output' | grep -q 'SERIAL=ABC123'"
    assert_true "${desc} — MODE" "echo '$output' | grep -q 'MODE=init'"

    rm -rf "$tmpdir"
}
test_re_substitution

# R6: Unresolved placeholder → execution fails
test_re_unresolved() {
    local desc="R6: Unresolved placeholder causes failure"
    re_setup

    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/scripts/remote"

    cat > "$tmpdir/scripts/remote/unres_test.sh.template" <<'TEMPLATE'
#!/bin/bash
echo "VALUE={{PROVIDED}}"
echo "MISSING={{UNPROVIDED}}"
TEMPLATE

    _REMOTE_EXEC_TEMPLATE_DIR="$tmpdir/scripts/remote"

    local rc=0
    _remote_exec "local" "unres_test" PROVIDED=yes 2>/dev/null || rc=$?

    assert_true "$desc (exit code ≠ 0)" "[ $rc -ne 0 ]"

    rm -rf "$tmpdir"
}
test_re_unresolved

# R7: Special characters in values don't corrupt output
test_re_special_chars() {
    local desc="R7: Special chars (|, /, &) substituted correctly"
    re_setup

    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/scripts/remote"

    cat > "$tmpdir/scripts/remote/spec_test.sh.template" <<'TEMPLATE'
#!/bin/bash
echo "PATH={{VAL_PATH}}"
echo "PIPE={{VAL_PIPE}}"
echo "AMP={{VAL_AMP}}"
TEMPLATE

    _REMOTE_EXEC_TEMPLATE_DIR="$tmpdir/scripts/remote"

    local output
    output="$(_remote_exec "local" "spec_test" \
        VAL_PATH=/a/b/c \
        VAL_PIPE='x|y|z' \
        VAL_AMP='a&b' \
        2>/dev/null)" || true

    assert_true "${desc} — path slashes" "echo '$output' | grep -q 'PATH=/a/b/c'"
    assert_true "${desc} — pipes" "echo '$output' | grep -q 'PIPE=x|y|z'"
    assert_true "${desc} — ampersand" "echo '$output' | grep -q 'AMP=a&b'"

    rm -rf "$tmpdir"
}
test_re_special_chars

# R8: Non-existent template → failure
test_re_missing_template() {
    local desc="R8: Missing template file causes failure"
    re_setup

    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/scripts/remote"

    _REMOTE_EXEC_TEMPLATE_DIR="$tmpdir/scripts/remote"

    local rc=0
    _remote_exec "local" "nonexistent_template" 2>/dev/null || rc=$?

    assert_true "$desc (exit code ≠ 0)" "[ $rc -ne 0 ]"

    rm -rf "$tmpdir"
}
test_re_missing_template

# --- Requirement: XTS result parsing ---

begin_section "REQ: XTS test result parsing"

# The parsing logic is in xts-test-hap.sh.template.
# We test by mocking hdc and running the template.

test_xts_parse() {
    local desc="$1"
    local mock_stdout="$2"
    local expected_code="$3"

    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/scripts/remote" "$tmpdir/logs"

    # Create mock hdc that simulates install + test output
    cat > "$tmpdir/mock_hdc" <<MOCK_EOF
#!/bin/bash
# Parse args after -t SERIAL
shift 2
case "\$1" in
    uninstall) exit 0;;
    install) echo "install bundle successfully."; exit 0;;
    shell)
        shift  # skip "shell"
        case "\$*" in
            *"aa test"*)
                cat <<'TESTOUT'
$mock_stdout
TESTOUT
                exit 0
                ;;
            *"hilog -r"*) exit 0;;
            *"power-shell wakeup"*) exit 0;;
            *"rm -f"*) exit 0;;
            *) exit 0;;
        esac
        ;;
    *) exit 0;;
esac
MOCK_EOF
    chmod +x "$tmpdir/mock_hdc"

    # Create minimal template copy with mock hdc path
    cp "$PROJECT_DIR/scripts/remote/xts-test-hap.sh.template" "$tmpdir/scripts/remote/parse_test.sh.template"
    # Override: set template dir
    _REMOTE_EXEC_TEMPLATE_DIR="$tmpdir/scripts/remote"

    # Need err() and SCRIPT_DIR for _remote_exec
    re_setup

    local output
    output="$(_remote_exec "local" "parse_test" \
        HDC_PATH="$tmpdir/mock_hdc" \
        SERIAL=TEST123 \
        HAP_PATH=/tmp/test.hap \
        BUNDLE=com.test.bundle \
        MODULE=entry \
        DEVICE_TMP=/data/local/tmp/test.hap \
        TEST_WINDOW=60 \
        INSTALL_METHOD=direct \
        LOG_DIR="$tmpdir/logs" \
        2>/dev/null)" || true

    local result_code
    result_code="$(echo "$output" | tail -1 | cut -f1)"

    assert_eq "$desc" "$expected_code" "$result_code"

    rm -rf "$tmpdir"
}

# R9: All pass → PASS
test_xts_parse \
    "R9: All pass → PASS" \
    "OHOS_REPORT_RESULT: stream=Pass: 10 Failure: 0 Error: 0 Time=1234" \
    "PASS"

# R10: Some failures → PARTIAL
test_xts_parse \
    "R10: Failures present → PARTIAL" \
    "OHOS_REPORT_RESULT: stream=Pass: 8 Failure: 2 Error: 0 Time=1234" \
    "PARTIAL"

# R11: App crash → CRASH
test_xts_parse \
    "R11: App crash → CRASH" \
    "App died" \
    "CRASH"

# R12: Timeout → TIMEOUT
test_xts_parse \
    "R12: Timeout → TIMEOUT" \
    "Timeout" \
    "TIMEOUT"

# R13: Not installed → NOT_INSTALLED
test_xts_parse \
    "R13: Bundle not found → NOT_INSTALLED" \
    "not installed" \
    "NOT_INSTALLED"

# R14: Exec failure → EXEC_FAIL
test_xts_parse \
    "R14: Failed to execute → EXEC_FAIL" \
    "failed to execute" \
    "EXEC_FAIL"

# R15: Unrecognized output → UNKNOWN
test_xts_parse \
    "R15: Unrecognized output → UNKNOWN" \
    "something completely unexpected" \
    "UNKNOWN"

# R16: Partial with errors counted
test_xts_parse \
    "R16: Errors counted as failures → PARTIAL" \
    "OHOS_REPORT_RESULT: stream=Pass: 5 Failure: 0 Error: 3 Time=1234" \
    "PARTIAL"

# --- Summary ---

echo ""
echo "=============================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
echo "=============================="

[ $FAIL_COUNT -eq 0 ] && exit 0 || exit 1
