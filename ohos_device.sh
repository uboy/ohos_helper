#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
    case "$0" in
        */ohos_device.sh|ohos_device.sh)
            exec bash "$0" "$@"
            ;;
    esac
    printf '%s\n' "ohos_device.sh requires bash. Run it with: bash $0 ..." >&2
    return 1 2>/dev/null || exit 1
fi

set -euo pipefail

resolve_launch_script_path() {
    local raw_path="$1"
    local resolved="$raw_path"

    if [[ "$resolved" != */* ]]; then
        resolved="$(command -v "$resolved" 2>/dev/null || printf '%s' "$resolved")"
    fi
    if [[ "$resolved" != /* ]]; then
        resolved="$(pwd)/$resolved"
    fi
    printf '%s\n' "$resolved"
}

resolve_real_script_path() {
    local source_path="$1"
    local source_dir=""
    local linked_target=""

    while [ -L "$source_path" ]; do
        source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
        linked_target="$(readlink "$source_path")"
        if [[ "$linked_target" = /* ]]; then
            source_path="$linked_target"
        else
            source_path="${source_dir}/${linked_target}"
        fi
    done
    source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
    printf '%s\n' "${source_dir}/$(basename "$source_path")"
}

OHOS_LAUNCH_PATH="$(resolve_launch_script_path "$0")"
OHOS_LAUNCH_DIR="$(cd -L "$(dirname "$OHOS_LAUNCH_PATH")" && pwd)"
OHOS_REAL_PATH="$(resolve_real_script_path "$OHOS_LAUNCH_PATH")"
OHOS_REAL_DIR="$(cd -P "$(dirname "$OHOS_REAL_PATH")" && pwd)"
SCRIPT_DIR="$OHOS_REAL_DIR"
OHOS_CONF_DIR="${OHOS_CONF_DIR:-${SCRIPT_DIR}/conf}"
OHOS_CONF="${OHOS_CONF:-${OHOS_CONF_DIR}/ohos.conf}"
OHOS_XTS_RUNTIME_LIB="${OHOS_XTS_RUNTIME_LIB:-${SCRIPT_DIR}/ohos_xts_runtime.sh}"
OHOS_XTS_ARTIFACTS_TOOL="${OHOS_XTS_ARTIFACTS_TOOL:-${SCRIPT_DIR}/ohos_xts_artifacts.py}"
OHOS_XTS_BRIDGE_TOOL="${OHOS_XTS_BRIDGE_TOOL:-${SCRIPT_DIR}/ohos_xts_bridge.py}"
ARKUI_XTS_SELECTOR_DIR="${ARKUI_XTS_SELECTOR_DIR:-${SCRIPT_DIR}/arkui-xts-selector}"
XTS_WINDOWS_BRIDGE_OUTPUT_ROOT="${XTS_WINDOWS_BRIDGE_OUTPUT_ROOT:-$HOME/ohos-xts-bridge}"
OHOS_DEVICE_SERVER_HOST="${OHOS_DEVICE_SERVER_HOST:-}"
OHOS_DEVICE_SERVER_USER="${OHOS_DEVICE_SERVER_USER:-}"
OHOS_REPO_ROOT="${OHOS_REPO_ROOT:-}"
OHOS_DEVICE_ACTIVE_CHILD_PID=""
OHOS_DEVICE_ACTIVE_CHILD_PGID=""
OHOS_DEVICE_SIGNAL_MESSAGE_EMITTED=0

if [ -f "$OHOS_CONF" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_CONF"
fi

BOARDS_CONF="${BOARDS_CONF:-${OHOS_CONF_DIR}/boards.conf}"
if [ -f "$BOARDS_CONF" ]; then
    # shellcheck disable=SC1090
    source "$BOARDS_CONF"
fi

OHOS_SHARED_ENV="${SCRIPT_DIR}/ohos-shared-env.sh"
if [ -f "$OHOS_SHARED_ENV" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_SHARED_ENV"
fi

REMOTE_EXEC_LIB="${SCRIPT_DIR}/scripts/remote/_remote_exec.sh"
if [ -f "$REMOTE_EXEC_LIB" ]; then
    # shellcheck disable=SC1090
    source "$REMOTE_EXEC_LIB"
fi

if [ -f "$OHOS_XTS_RUNTIME_LIB" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_XTS_RUNTIME_LIB"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[ohos-device]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ohos-device]${NC} $*" >&2; }
err()   { echo -e "${RED}[ohos-device]${NC} $*" >&2; }

has_command() {
    command -v "$1" >/dev/null 2>&1
}

device_wait_active_child() {
    local rc=0

    if [ -z "${OHOS_DEVICE_ACTIVE_CHILD_PID:-}" ]; then
        return 0
    fi

    if wait "$OHOS_DEVICE_ACTIVE_CHILD_PID"; then
        rc=0
    else
        rc=$?
    fi
    OHOS_DEVICE_ACTIVE_CHILD_PID=""
    OHOS_DEVICE_ACTIVE_CHILD_PGID=""
    return "$rc"
}

device_run_foreground() {
    local detected_pgid=""
    if has_command setsid; then
        setsid "$@" &
    else
        "$@" &
    fi
    OHOS_DEVICE_ACTIVE_CHILD_PID=$!
    detected_pgid="$(ps -o pgid= -p "${OHOS_DEVICE_ACTIVE_CHILD_PID}" 2>/dev/null || true)"
    OHOS_DEVICE_ACTIVE_CHILD_PGID="$(printf '%s' "$detected_pgid" | tr -d '[:space:]')"
    if [ -z "${OHOS_DEVICE_ACTIVE_CHILD_PGID:-}" ]; then
        OHOS_DEVICE_ACTIVE_CHILD_PGID="${OHOS_DEVICE_ACTIVE_CHILD_PID}"
    fi
    device_wait_active_child
}

device_forward_signal() {
    local signal_name="$1"
    local pid="${OHOS_DEVICE_ACTIVE_CHILD_PID:-}"
    local pgid="${OHOS_DEVICE_ACTIVE_CHILD_PGID:-}"
    local _attempt=0

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        if [ -n "$pgid" ] && [[ "$pgid" =~ ^[0-9]+$ ]]; then
            kill -s "$signal_name" "-$pgid" 2>/dev/null || kill -s "$signal_name" "$pid" 2>/dev/null || true
        else
            kill -s "$signal_name" "$pid" 2>/dev/null || true
        fi
        for _attempt in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                OHOS_DEVICE_ACTIVE_CHILD_PID=""
                OHOS_DEVICE_ACTIVE_CHILD_PGID=""
                return 0
            fi
            sleep 0.1
        done
        if [ -n "$pgid" ] && [[ "$pgid" =~ ^[0-9]+$ ]]; then
            kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        else
            kill -TERM "$pid" 2>/dev/null || true
        fi
        for _attempt in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                OHOS_DEVICE_ACTIVE_CHILD_PID=""
                OHOS_DEVICE_ACTIVE_CHILD_PGID=""
                return 0
            fi
            sleep 0.1
        done
        if [ -n "$pgid" ] && [[ "$pgid" =~ ^[0-9]+$ ]]; then
            kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        else
            kill -KILL "$pid" 2>/dev/null || true
        fi
        OHOS_DEVICE_ACTIVE_CHILD_PID=""
        OHOS_DEVICE_ACTIVE_CHILD_PGID=""
    fi
}

device_handle_signal() {
    local signal_name="$1"
    local exit_code="$2"
    local message="$3"

    if [ "${OHOS_DEVICE_SIGNAL_MESSAGE_EMITTED:-0}" -eq 0 ]; then
        err "$message"
        OHOS_DEVICE_SIGNAL_MESSAGE_EMITTED=1
    fi
    device_forward_signal "$signal_name"
    exit "$exit_code"
}

trap 'device_handle_signal INT 130 "Script stopped by Ctrl+C."' INT
trap 'device_handle_signal TERM 143 "Script stopped by SIGTERM."' TERM
trap 'device_handle_signal HUP 129 "Script stopped by SIGHUP."' HUP

flash_py_has_neighbor_tool() {
    local flash_py_path="${1:-}"
    local machine=""
    local candidate=""

    [ -n "${flash_py_path}" ] || return 1
    [ -f "${flash_py_path}" ] || return 1

    machine="$(uname -m 2>/dev/null || printf '%s' 'x86_64')"
    candidate="$(cd "$(dirname "${flash_py_path}")" 2>/dev/null && pwd)/bin/flash.${machine}"
    [ -f "${candidate}" ]
}

resolve_preferred_flash_py_path() {
    local flash_py="${OHOS_TOOLS_DIR:-$HOME/ohos_cache/tools}/linux/flash.py"

    if [ -f "${flash_py}" ] && flash_py_has_neighbor_tool "${flash_py}"; then
        printf '%s\n' "${flash_py}"
        return 0
    fi

    return 1
}

# Run a command on a remote board server via SSH.
_ssh_run() {
    local server="$1"; shift
    local ssh_user="${OHOS_SSH_USER:-${USER}}"
    ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${server}" "$@"
}

# Kill running hdc daemon, print its argv for later restore.
# Returns 0 if killed, 1 if not running.
kill_hdc_daemon() {
    local pgrep_out
    pgrep_out="$(pgrep -af 'hdc -m' 2>/dev/null)" || return 1
    [ -z "$pgrep_out" ] && return 1

    local pid argv
    pid="$(echo "$pgrep_out" | head -1 | awk '{print $1}')"
    argv="$(echo "$pgrep_out" | head -1 | sed 's/^[0-9]* //')"

    # Verify PID still belongs to hdc
    local cmdline
    cmdline="$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ')" || return 1
    echo "$cmdline" | grep -q 'hdc' || return 1

    kill "$pid" 2>/dev/null || return 1
    sleep 2

    # Force kill if still alive
    if [ -d "/proc/$pid" ] && cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | grep -q 'hdc'; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    # Print argv for restore
    printf '%s\n' "$argv"
    return 0
}

# Restore previously killed hdc daemon.
restore_hdc_daemon() {
    local argv="$1"
    [ -z "$argv" ] && return 0

    # Don't start if already running
    pgrep -af 'hdc -m' >/dev/null 2>&1 && return 0

    $argv >/dev/null 2>&1 &
    sleep 2
}

# Wait for a device to appear in Rockchip Loader mode via flash_tool LD.
# Args: flash_tool_path [timeout_seconds]
# Prints the DevNo of the first Loader device found.
wait_for_loader() {
    local flash_tool="$1"
    local timeout="${2:-30}"
    local deadline now start
    start="$(date +%s)"
    deadline=$((start + timeout))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local ld_out
        ld_out="$("$flash_tool" LD 2>&1)" || true
        local loader_line
        loader_line="$(echo "$ld_out" | grep 'Mode=Loader' | head -1)" || true
        if [ -n "$loader_line" ]; then
            local devno
            devno="${loader_line#DevNo=}"
            devno="${devno%%[!0-9]*}"
            [ -n "$devno" ] && printf '%s\n' "$devno" && return 0
        fi
        sleep 2
    done
    return 1
}

# Switch device to Loader mode via hdc target boot -bootloader.
# Args: hdc_path device_serial flash_tool_path
switch_to_loader() {
    local hdc_path="$1"
    local device="$2"
    local flash_tool="$3"

    if [ -n "$device" ]; then
        "$hdc_path" -t "$device" target boot -bootloader 2>&1 || true
    else
        "$hdc_path" target boot -bootloader 2>&1 || true
    fi
}

# ── Board State Tracking ─────────────────────────────────────────────────

# Return path to board-state.json.
_board_state_file() {
    printf '%s/board-state.json' "$OHOS_CONF_DIR"
}

# Read board-state.json. Prints default empty state if missing.
_board_state_read() {
    local state_file
    state_file="$(_board_state_file)"
    if [ -f "$state_file" ] && [ -s "$state_file" ]; then
        cat "$state_file"
    else
        printf '%s\n' '{"version":1,"boards":{}}'
    fi
}

# Extract version info from a firmware directory.
# Args: firmware_path [remote_server]
# Prints KEY=VALUE lines for version fields.
_extract_firmware_version() {
    local firmware_path="$1"
    local remote_server="${2:-}"
    local _run_cmd

    if [ -n "$remote_server" ]; then
        _run_cmd() { _ssh_run "$remote_server" "$@"; }
    else
        _run_cmd() { eval "$@" 2>/dev/null; }
    fi

    local openharmony_version=""
    local firmware_ver=""
    local machine_model=""
    local manifest_hash=""
    local tarball_name=""

    # OpenHarmony version from tarball name in firmware dir or parent
    tarball_name="$(_run_cmd "ls '${firmware_path}'/../version-*.tar.gz '${firmware_path}/version-*.tar.gz' 2>/dev/null | head -1" 2>/dev/null)" || true
    if [ -n "$tarball_name" ]; then
        tarball_name="$(basename "$tarball_name")"
        # Extract OpenHarmony_X.Y.Z.W from tarball name
        openharmony_version="$(echo "$tarball_name" | grep -oP 'OpenHarmony_[\d.]+' | head -1)" || true
    fi

    # Fallback: extract from daily_build.log first line
    if [ -z "$openharmony_version" ]; then
        openharmony_version="$(_run_cmd "head -1 '${firmware_path}/daily_build.log' 2>/dev/null | grep -oP \"versionName['\\\"]?\\s*:\\s*['\\\"]?\\KOpenHarmony_[\\d.]+\" | head -1")" || true
    fi

    # FIRMWARE_VER and MACHINE_MODEL from parameter.txt
    firmware_ver="$(_run_cmd "grep '^FIRMWARE_VER:' '${firmware_path}/parameter.txt' 2>/dev/null | head -1 | cut -d: -f2- | tr -d '[:space:]'")" || true
    machine_model="$(_run_cmd "grep '^MACHINE_MODEL:' '${firmware_path}/parameter.txt' 2>/dev/null | head -1 | cut -d: -f2- | tr -d '[:space:]'")" || true

    # Manifest hash from manifest_tag.xml
    manifest_hash="$(_run_cmd "grep -m1 'revision=' '${firmware_path}/manifest_tag.xml' 2>/dev/null | grep -oP 'revision=\"\\K[a-f0-9]+' | head -1")" || true

    printf 'OPENHARMONY_VERSION=%s\n' "$openharmony_version"
    printf 'FIRMWARE_VER=%s\n' "$firmware_ver"
    printf 'MACHINE_MODEL=%s\n' "$machine_model"
    printf 'MANIFEST_HASH=%s\n' "$manifest_hash"
    printf 'TARBALL_NAME=%s\n' "$tarball_name"
}

# Update board-state.json after successful flash.
# Args: serial firmware_path [remote_server]
# Non-fatal: warns on failure, never returns non-zero.
_board_state_update() {
    local serial="$1"
    local firmware_path="$2"
    local remote_server="${3:-}"

    if [ -z "$serial" ] || [ -z "$firmware_path" ]; then
        warn "board_state_update: missing serial or firmware_path"
        return 0
    fi

    # Extract version info
    local version_output
    version_output="$(_extract_firmware_version "$firmware_path" "$remote_server")" || true

    local openharmony_version="" firmware_ver="" machine_model="" manifest_hash="" tarball_name=""
    local line
    while IFS= read -r line; do
        case "$line" in
            OPENHARMONY_VERSION=*) openharmony_version="${line#OPENHARMONY_VERSION=}" ;;
            FIRMWARE_VER=*) firmware_ver="${line#FIRMWARE_VER=}" ;;
            MACHINE_MODEL=*) machine_model="${line#MACHINE_MODEL=}" ;;
            MANIFEST_HASH=*) manifest_hash="${line#MANIFEST_HASH=}" ;;
            TARBALL_NAME=*) tarball_name="${line#TARBALL_NAME=}" ;;
        esac
    done <<< "$version_output"

    # Resolve board short/server from boards.conf
    local board_short="" board_server=""
    local i
    for i in $(seq 1 "${BOARD_COUNT:-0}"); do
        local serial_var="BOARD_${i}_SERIAL"
        if [ "${!serial_var}" = "$serial" ]; then
            local short_var="BOARD_${i}_SHORT"
            local server_var="BOARD_${i}_SERVER"
            board_short="${!short_var}"
            board_server="${!server_var}"
            break
        fi
    done

    # Build JSON entry and update file
    local state_file
    state_file="$(_board_state_file)"
    local flashed_at
    flashed_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    local flashed_by="${USER:-unknown}"

    python3 -c "
import json, sys, os

serial = sys.argv[1]
state_file = sys.argv[2]
board_short = sys.argv[3]
board_server = sys.argv[4]
firmware_path = sys.argv[5]
flashed_at = sys.argv[6]
flashed_by = sys.argv[7]
openharmony_version = sys.argv[8]
firmware_ver = sys.argv[9]
machine_model = sys.argv[10]
manifest_hash = sys.argv[11]
tarball_name = sys.argv[12]

# Read existing state
if os.path.isfile(state_file):
    with open(state_file, 'r') as f:
        state = json.load(f)
else:
    state = {'version': 1, 'boards': {}}

state.setdefault('boards', {})[serial] = {
    'serial': serial,
    'short': board_short,
    'server': board_server,
    'firmware': {
        'path': firmware_path,
        'flashed_at': flashed_at,
        'flashed_by': flashed_by,
        'openharmony_version': openharmony_version,
        'firmware_ver': firmware_ver,
        'machine_model': machine_model,
        'manifest_hash': manifest_hash,
        'tarball_name': tarball_name,
    }
}

# Atomic write via temp file in same directory
import tempfile
state_dir = os.path.dirname(os.path.abspath(state_file))
fd, tmp_path = tempfile.mkstemp(dir=state_dir, suffix='.json.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, state_file)
except:
    os.unlink(tmp_path) if os.path.exists(tmp_path) else None
    raise
" "$serial" "$state_file" "$board_short" "$board_server" "$firmware_path" \
  "$flashed_at" "$flashed_by" "$openharmony_version" "$firmware_ver" \
  "$machine_model" "$manifest_hash" "$tarball_name" 2>/dev/null || {
    warn "board_state_update: failed to update $state_file"
    return 0
  }

    info "Board state updated: $state_file"
    return 0
}

# ── Device Mode Detection ────────────────────────────────────────────────

# Check current device mode via flash_tool LD.
# Args: flash_tool_path [locationid]
# Prints: "Loader" or "Maskrom" or "" (not found)
# Exit: 0 if device found, 1 if not found
_check_device_mode() {
    local flash_tool="$1"
    local locationid="${2:-}"
    local ld_out
    ld_out="$("$flash_tool" LD 2>&1)" || true

    if [ -z "$ld_out" ]; then
        return 1
    fi

    if [ -n "$locationid" ]; then
        # Filter by LocationID — line must contain both LocationID and Mode
        local match_line
        match_line="$(echo "$ld_out" | grep "LocationID=${locationid}" | head -1)" || true
        if [ -n "$match_line" ]; then
            local mode
            mode="$(echo "$match_line" | grep -oP 'Mode=\K[^ ]+' | head -1)" || true
            if [ -n "$mode" ]; then
                printf '%s\n' "$mode"
                return 0
            fi
        fi
        return 1
    fi

    # No LocationID filter — return first device mode
    local mode
    mode="$(echo "$ld_out" | grep -m1 'Mode=' | sed 's/.*Mode=//' | awk '{print $1}')" || true
    if [ -n "$mode" ]; then
        printf '%s\n' "$mode"
        return 0
    fi
    return 1
}

# Check device mode on remote server.
# Args: server flash_tool_path [locationid]
_check_device_mode_remote() {
    local server="$1"
    local flash_tool="$2"
    local locationid="${3:-}"
    local ld_out
    ld_out="$(_ssh_run "$server" "${flash_tool} LD 2>&1")" || true

    if [ -z "$ld_out" ]; then
        return 1
    fi

    if [ -n "$locationid" ]; then
        local match_line
        match_line="$(echo "$ld_out" | grep "LocationID=${locationid}" | head -1)" || true
        if [ -n "$match_line" ]; then
            local mode
            mode="$(echo "$match_line" | grep -oP 'Mode=\K[^ ]+' | head -1)" || true
            if [ -n "$mode" ]; then
                printf '%s\n' "$mode"
                return 0
            fi
        fi
        return 1
    fi

    local mode
    mode="$(echo "$ld_out" | grep -m1 'Mode=' | sed 's/.*Mode=//' | awk '{print $1}')" || true
    if [ -n "$mode" ]; then
        printf '%s\n' "$mode"
        return 0
    fi
    return 1
}

# ── Flash Locking ────────────────────────────────────────────────────────

# Return lock file path for a device.
# Args: device_serial
_flash_lock_path() {
    printf '/tmp/ohos-flash-%s.lock' "${1: -6}"
}

# Acquire per-board flash lock.
# Args: device_serial [remote_server]
# Exit: 0 on success, 1 if locked by live process
_flash_acquire_lock() {
    local serial="$1"
    local remote_server="${2:-}"
    local lock_path
    lock_path="$(_flash_lock_path "$serial")"
    local stamp
    stamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    if [ -n "$remote_server" ]; then
        # Remote lock: check and create in one SSH invocation to avoid TOCTOU
        local result
        result="$(_ssh_run "$remote_server" "
lock_path='${lock_path}'
if [ -f \"\$lock_path\" ]; then
    old_pid=\$(grep -oP 'PID:\\K[0-9]+' \"\$lock_path\" 2>/dev/null || true)
    if [ -n \"\$old_pid\" ] && kill -0 \"\$old_pid\" 2>/dev/null; then
        old_user=\$(grep -oP 'USER:\\K[^ ]+' \"\$lock_path\" 2>/dev/null || echo unknown)
        old_started=\$(grep -oP 'STARTED:\\K.*' \"\$lock_path\" 2>/dev/null || echo unknown)
        echo \"LOCKED:\${old_user}:\${old_started}:\${old_pid}\"
        exit 0
    fi
    echo 'STALE' >&2
    rm -f \"\$lock_path\"
fi
printf 'PID:%s USER:%s STARTED:%s\n' '\$\$' '${USER:-unknown}' '${stamp}' > \"\$lock_path\"
echo 'ACQUIRED'
")" || true
        if echo "$result" | grep -q '^LOCKED:'; then
            local locked_info
            locked_info="$(echo "$result" | grep '^LOCKED:')"
            local lock_user="${locked_info%%:*}" ; lock_user="${locked_info#*:}" ; lock_user="${lock_user%%:*}"
            local lock_time="${locked_info#*:*:}" ; lock_time="${lock_time%%:*}"
            err "Board ${serial: -6} is locked by $lock_user since $lock_time (remote $remote_server)"
            return 1
        fi
        return 0
    fi

    # Local lock
    if [ -f "$lock_path" ]; then
        local old_pid
        old_pid="$(grep -oP 'PID:\K[0-9]+' "$lock_path" 2>/dev/null)" || true
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            local old_user old_started
            old_user="$(grep -oP 'USER:\K[^ ]+' "$lock_path" 2>/dev/null || echo unknown)"
            old_started="$(grep -oP 'STARTED:\K.*' "$lock_path" 2>/dev/null || echo unknown)"
            err "Board ${serial: -6} is locked by $old_user since $old_started"
            return 1
        fi
        warn "Removing stale lock for board ${serial: -6}"
        rm -f "$lock_path"
    fi

    printf 'PID:%s USER:%s STARTED:%s\n' "$$" "${USER:-unknown}" "$stamp" > "$lock_path"
    return 0
}

# Release per-board flash lock.
# Args: device_serial [remote_server]
# Best-effort: always returns 0.
_flash_release_lock() {
    local serial="$1"
    local remote_server="${2:-}"
    local lock_path
    lock_path="$(_flash_lock_path "$serial")"

    if [ -n "$remote_server" ]; then
        _ssh_run "$remote_server" "rm -f '${lock_path}'" 2>/dev/null || true
    else
        rm -f "$lock_path" 2>/dev/null || true
    fi
    return 0
}

run_xts_artifacts_tool() {
    if [ ! -d "$ARKUI_XTS_SELECTOR_DIR" ]; then
        err "Missing XTS selector repo: $ARKUI_XTS_SELECTOR_DIR"
        exit 1
    fi
    if [ ! -f "$OHOS_XTS_ARTIFACTS_TOOL" ]; then
        err "Missing XTS artifacts tool: $OHOS_XTS_ARTIFACTS_TOOL"
        exit 1
    fi

    local xts_env=()
    local explicit_hdc_path="${1:-}"
    shift || true
    local resolved_hdc_path="${explicit_hdc_path:-}"
    local hdc_lib_dir=""

    xts_env+=(PYTHONPATH="${ARKUI_XTS_SELECTOR_DIR}/src")
    xts_env+=(ARKUI_XTS_SELECTOR_COMMAND_MODE="wrapper")
    if hdc_lib_dir="$(detect_hdc_library_path "${resolved_hdc_path:-${HDC_PATH:-}}" 2>/dev/null)"; then
        xts_env+=(ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH="$hdc_lib_dir")
        xts_env+=(LD_LIBRARY_PATH="$hdc_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
    fi
    device_run_foreground env \
        "${xts_env[@]}" \
        ARKUI_XTS_SELECTOR_DIR="${ARKUI_XTS_SELECTOR_DIR}" \
        python3 "$OHOS_XTS_ARTIFACTS_TOOL" "$@"
}

is_non_loopback_ipv4() {
    local candidate="${1:-}"
    local octet=""
    local IFS='.'
    local -a octets=()

    case "$candidate" in
        ""|127.*|169.254.*)
            return 1
            ;;
        *.*.*.*)
            ;;
        *)
            return 1
            ;;
    esac

    read -r -a octets <<<"$candidate"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        case "$octet" in
            ''|*[!0-9]*)
                return 1
                ;;
        esac
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
    return 0
}

detect_local_server_host() {
    local candidate=""
    local hostname_output=""

    if [ -n "${OHOS_DEVICE_SERVER_HOST}" ]; then
        printf '%s\n' "${OHOS_DEVICE_SERVER_HOST}"
        return 0
    fi

    if has_command hostname; then
        hostname_output="$(hostname -I 2>/dev/null || true)"
        for candidate in $hostname_output; do
            if is_non_loopback_ipv4 "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    fi

    if has_command ip; then
        while IFS= read -r candidate; do
            if is_non_loopback_ipv4 "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    fi

    if has_command hostname; then
        candidate="$(hostname -f 2>/dev/null || true)"
        if [ -n "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        candidate="$(hostname 2>/dev/null || true)"
        if [ -n "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    return 1
}

detect_local_server_user() {
    if [ -n "${OHOS_DEVICE_SERVER_USER}" ]; then
        printf '%s\n' "${OHOS_DEVICE_SERVER_USER}"
        return 0
    fi
    if [ -n "${USER:-}" ]; then
        printf '%s\n' "${USER}"
        return 0
    fi
    if has_command id; then
        id -un 2>/dev/null
        return $?
    fi
    if has_command whoami; then
        whoami 2>/dev/null
        return $?
    fi
    return 1
}

run_xts_bridge_tool() {
    if [ ! -f "$OHOS_XTS_BRIDGE_TOOL" ]; then
        err "Missing XTS bridge tool: $OHOS_XTS_BRIDGE_TOOL"
        exit 1
    fi
    device_run_foreground python3 "$OHOS_XTS_BRIDGE_TOOL" "$@"
}

print_help_device() {
    cat <<HELP
device - standalone device access and bridge helper

Supported subcommands:
  help
  init-board         Prepare boards for testing (wake, performance, USB dialog)
  bridge
  flash
  firmware           List available firmware images or download daily builds
  list-targets       Show HDC and Rockchip devices visible on this server
  power              Control APC Rack PDU outlets (on/off/reboot/status)
  xts-run            Run XTS static HAP tests across multiple boards (quick/debug)
  xts-full-run       Run full XTS suite via xdevice framework (recommended)

Roles:
  - Linux test server:
      the Linux machine where you run 'ohos ...', save selector reports,
      and later execute 'ohos xts ...'
  - Device host:
      another Linux or Windows PC physically connected to the USB device
  - Target device:
      the OHOS board or phone itself

What this solves:
  - let the Linux test server use a device attached to another PC
  - package a Windows-side bridge helper
  - keep device access separate from selector/report UX

Linux device host flow:
  Run on the Linux PC with the USB-connected device:
    1. Start a local HDC service:
       hdc -s 127.0.0.1:8710 -m
    2. Confirm that HDC sees the device:
       hdc -s 127.0.0.1:8710 list targets
  Run on the Linux test server:
    3. Forward that HDC port over SSH:
       ssh -NT -L 28710:127.0.0.1:8710 <user>@<linux-device-host>
    4. Run XTS against the forwarded endpoint:
       ohos xts run last --hdc-endpoint 127.0.0.1:28710

Windows device host flow:
  Run on the Linux test server first:
    1. Build the Windows bridge bundle:
       ohos device bridge package-windows --last-report
       The wrapper auto-detects the Linux test server IP and current user.
       Override them with --server-host / --server-user when needed.
  Run on the Windows PC with the USB-connected device:
    2. Unpack the ZIP bundle.
    3. If hdc.exe or an old bridge is already running, stop it first:
       powershell -ExecutionPolicy Bypass -File .\\stop_hdc_bridge.ps1 -StopHdcServer
    4. Start the bridge:
       powershell -ExecutionPolicy Bypass -File .\\start_hdc_bridge.ps1
  Back on the Linux test server:
    5. Run XTS with:
       ohos xts run last --hdc-endpoint 127.0.0.1:28710

  Persistent config:
    - put XTS_HDC_ENDPOINT=127.0.0.1:28710 into $OHOS_CONF to avoid passing it every time
    - if several devices are visible through one HDC server, also pass --device <serial>

Examples:
  ohos device help
  ohos device bridge help
  ohos device bridge package-windows --last-report
  ohos device bridge package-windows --server-host 10.0.0.10 --server-user \$USER --last-report
  ohos device flash --firmware-component dayu200 --firmware-build-tag 20260409_180241 --firmware-date 20260409
HELP
}

print_help_device_bridge() {
    cat <<HELP
device bridge - package Windows helpers for RK3568 over SSH + HDC

What it runs:
  python3 "$OHOS_XTS_BRIDGE_TOOL" package-windows ...

Purpose:
  - prepare a Windows helper for a device connected to another PC
  - let that Windows PC tunnel HDC access back to the Linux test server
  - optionally embed the latest selector report as ready-to-run local aa_test commands

Host roles:
  - Linux test server:
      where you run 'ohos device bridge ...' and later 'ohos xts ...'
  - Windows device host:
      the Windows PC physically connected to the USB device
  - SSH target used by Windows:
      the Linux test server address and user

Supported subcommands:
  package-windows   Build a ZIP bundle with README + PowerShell bridge scripts

Important defaults:
  - Linux-side forwarded HDC port defaults to 28710
  - Windows-side local HDC port defaults to 8710
  - If '--server-host' is omitted, the wrapper auto-detects a preferred
    non-loopback IPv4 address of the current Linux test server
  - If '--server-user' is omitted, the wrapper uses the current Linux user
  - Default bundle output directory:
      $XTS_WINDOWS_BRIDGE_OUTPUT_ROOT
  - If you pass --last-report, the wrapper defaults run-store root to:
      $(xts_default_run_store_root)

Recommended flow:
  1. On the Linux test server, save the selector report:
     ohos xts select https://gitcode.com/openharmony/arkui_ace_engine/pull/83368
  2. On the Linux test server, build the Windows bundle:
     ohos device bridge package-windows --last-report
  3. On the Windows device host:
     - unpack the archive
     - ensure ssh and hdc.exe are available
     - if hdc.exe is already running, first run:
       stop_hdc_bridge.ps1 -StopHdcServer
     - then run start_hdc_bridge.ps1
     - the start script already stops the previously tracked bridge and restarts local HDC by default
  4. Back on the Linux test server:
     ohos xts run last --hdc-endpoint 127.0.0.1:28710

Examples:
  ohos device bridge package-windows --last-report
  ohos device bridge package-windows --server-host your-server --server-user $USER --last-report
  ohos device bridge package-windows --server-host 10.0.0.10 --server-user user --selector-report /tmp/selector_report.json --output /tmp/rk3568_bundle.zip
HELP
}

print_help_device_flash() {
    cat <<HELP
device flash - flash a daily firmware package or a local unpacked image bundle

Flash modes:
  CLI (preferred)  - separate flash_tool -s <LocationID> per command, auto-selected
                     when multiple boards detected on server
  PTY (fallback)   - batch stdin via script, used for single-board servers

Behavior:
  - stops the hdc daemon before flashing (USB lock conflict)
  - acquires per-board lock to prevent concurrent flashing of same board
  - detects current device mode: if already in Loader, skips hdc switch
  - switches the target device into Rockchip Loader mode (if not already)
  - detects multi-device: CLI mode with LocationID if >1 board on server
  - flashes all partitions (UL -> TD -> DI parameter + images -> RD)
  - restores the hdc daemon after flashing
  - updates conf/board-state.json with firmware version info on success

Device selection:
  --device <serial>  HDC serial (from boards.conf). Switches board to Loader,
                     auto-selects LocationID from boards.conf for CLI mode
  --devno <N>        Rockchip DevNo (single-board servers only)
  --locationid <ID>  Rockchip LocationID (auto-selected from boards.conf)
  --server <host>    Remote board server IP. Runs flash via SSH with tmux.
                     Requires --device. Firmware path must be valid on remote.
                     Flash runs in tmux session — survives client disconnect.
                     Logs to ~/flash-logs/<short>-<date>.log on remote server.

Firmware selection (when no firmware path is given):
  - shows a numbered menu of available firmware images
  - scans ${FIRMWARE_DOWNLOAD_ROOT} and cached daily builds

Examples:
  ohos device flash                                    # interactive: pick firmware + device
  ohos device flash /tmp/image_bundle                  # flash specific firmware
  ohos device flash --device <serial> /tmp/fw          # recommended: target by HDC serial
  ohos device flash --devno 2 /tmp/image_bundle        # single-board: target by DevNo
  ohos device flash --device <serial> --server 10.0.0.1 /tmp/fw  # remote board via SSH
HELP
}

print_help_device_firmware() {
    cat <<HELP
device firmware - manage firmware images

Subcommands:
  list               Show available firmware images on this server
  download           Download a daily firmware build (delegates to xts artifacts tool)

Examples:
  ohos device firmware list
  ohos device firmware download --firmware-component dayu200 --firmware-date 20260522
HELP
}

cmd_firmware() {
    local firmware_subcmd="${1:-list}"
    if [ $# -gt 0 ]; then
        shift
    fi
    case "$firmware_subcmd" in
        help|--help|-h|"")
            print_help_device_firmware
            ;;
        list)
            cmd_firmware_list "$@"
            ;;
        download)
            # Delegate to xts artifacts tool
            run_xts_artifacts_tool "" flash --firmware-download-only "$@"
            ;;
        *)
            err "device firmware: unknown subcommand: $firmware_subcmd"
            print_help_device_firmware
            exit 1
            ;;
    esac
}

cmd_firmware_list() {
    local found=0
    local -a entries=()

    echo "=== Available firmware images ==="

    # Scan known firmware directories
    local dirs=(
        "${FIRMWARE_DOWNLOAD_ROOT:-$HOME/ohos_cache/firmware}/dayu200"
        "${HOME}/bin/linux/firmwares"
        "/tmp/arkui_xts_selector_firmware_cache"
    )

    for firmware_root in "${dirs[@]}"; do
        if [ ! -d "$firmware_root" ]; then
            continue
        fi
        for entry in "$firmware_root"/*/ ; do
            if [ -f "${entry}MiniLoaderAll.bin" ]; then
                local name
                name="$(basename "$entry")"
                local mtime
                mtime="$(stat -c '%Y' "$entry" 2>/dev/null || echo 0)"
                local date_str
                date_str="$(date -d "@$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"
                entries+=("$mtime|$date_str|$name|${entry}")
                found=$((found + 1))
            fi
        done
    done

    # Sort by mtime (newest first) and output
    if [ "$found" -gt 0 ]; then
        printf '%s\n' "${entries[@]}" | sort -rn | while IFS='|' read -r mtime date_str name path; do
            echo "  $date_str  $name"
            echo "    Path: $path"
        done
    fi

    if [ "$found" -eq 0 ]; then
        echo "(no firmware images found)"
        echo ""
        echo "Use 'ohos device firmware download' to download a daily build."
    fi
}

pick_device_interactive() {
    local flash_tool="$1"
    local devices_output
    devices_output="$("$flash_tool" LD 2>&1)" || true

    local dev_count
    dev_count="$(echo "$devices_output" | grep -c "^DevNo=")" || true

    if [ "$dev_count" -eq 0 ]; then
        err "No Rockchip devices detected. Connect a device and ensure it is in Loader mode."
        exit 1
    fi

    if [ "$dev_count" -eq 1 ]; then
        # Single device — extract DevNo using parameter expansion (no sed)
        local line
        line="$(echo "$devices_output" | grep "^DevNo=" | head -1)"
        local devno="${line#DevNo=}"
        devno="${devno%%[!0-9]*}"
        if [ -z "$devno" ]; then
            err "Failed to parse device number"
            exit 1
        fi
        echo "$devno"
        return 0
    fi

    # Multiple devices — show menu
    echo "Multiple devices detected:"
    echo ""
    echo "$devices_output" | grep "^DevNo=" | while IFS= read -r line; do
        local devno serial mode
        devno="${line#DevNo=}"
        devno="${devno%%[!0-9]*}"
        serial="${line#*SerialNo=}"
        serial="${serial%%[[:space:]]*}"
        mode="${line#*Mode=}"
        mode="${mode%%[[:space:]]*}"
        # Sanitize: remove non-printable chars
        serial="${serial//[^[:print:]]/?}"
        mode="${mode//[^[:print:]]/?}"
        printf '  [%s] Serial: %s  Mode: %s\n' "$devno" "$serial" "$mode"
    done
    echo ""
    printf "Select device number: "
    local choice
    read -r choice

    if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt 999 ]; then
        err "Invalid selection"
        exit 1
    fi
    echo "$choice"
}

pick_firmware_interactive() {
    local found=0
    local paths=()
    local labels=()

    local dirs=(
        "${FIRMWARE_DOWNLOAD_ROOT:-$HOME/ohos_cache/firmware}/dayu200"
        "${HOME}/bin/linux/firmwares"
        "/tmp/arkui_xts_selector_firmware_cache"
    )

    for firmware_root in "${dirs[@]}"; do
        if [ ! -d "$firmware_root" ]; then
            continue
        fi
        for entry in "$firmware_root"/*/ ; do
            if [ -f "${entry}MiniLoaderAll.bin" ]; then
                local name
                name="$(basename "$entry")"
                local mtime
                mtime="$(stat -c '%Y' "$entry" 2>/dev/null || echo 0)"
                paths+=("${entry%/}")
                labels+=("$name")
                found=$((found + 1))
            fi
        done
    done

    if [ "$found" -eq 0 ]; then
        err "No firmware images found. Use 'ohos device firmware download' first."
        exit 1
    fi

    # Sort by newest first
    echo "Available firmware images:"
    echo ""
    for i in "${!labels[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${labels[$i]}"
    done
    echo ""
    printf "Select firmware (1-%d): " "$found"
    local choice
    read -r choice

    if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "$found" ]; then
        err "Invalid selection"
        exit 1
    fi

    local selected_path="${paths[$((choice-1))]}"
    if [ ! -d "$selected_path" ]; then
        err "Selected firmware directory no longer exists: $selected_path"
        exit 1
    fi
    if [ ! -f "${selected_path}/MiniLoaderAll.bin" ]; then
        err "Selected firmware is not valid (missing MiniLoaderAll.bin): $selected_path"
        exit 1
    fi

    echo "$selected_path"
}

cmd_bridge() {
    local bridge_subcmd="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi
    case "$bridge_subcmd" in
        help|--help|-h|"")
            print_help_device_bridge
            ;;
        package-windows)
            local bridge_args=("$@")
            local detected_server_host=""
            local detected_server_user=""
            if ! has_long_flag "--output" "${bridge_args[@]}" && ! has_long_flag "--output-dir" "${bridge_args[@]}" && [ -n "${XTS_WINDOWS_BRIDGE_OUTPUT_ROOT:-}" ]; then
                bridge_args=(--output-dir "$XTS_WINDOWS_BRIDGE_OUTPUT_ROOT" "${bridge_args[@]}")
            fi
            if ! has_long_flag "--run-store-root" "${bridge_args[@]}"; then
                bridge_args=(--run-store-root "$(xts_default_run_store_root)" "${bridge_args[@]}")
            fi
            if ! has_long_flag "--server-host" "${bridge_args[@]}"; then
                if detected_server_host="$(detect_local_server_host 2>/dev/null)"; then
                    bridge_args=(--server-host "$detected_server_host" "${bridge_args[@]}")
                else
                    err "Could not auto-detect the Linux test server address. Pass --server-host explicitly."
                    exit 1
                fi
            fi
            if ! has_long_flag "--server-user" "${bridge_args[@]}"; then
                if detected_server_user="$(detect_local_server_user 2>/dev/null)"; then
                    bridge_args=(--server-user "$detected_server_user" "${bridge_args[@]}")
                else
                    err "Could not auto-detect the Linux test server user. Pass --server-user explicitly."
                    exit 1
                fi
            fi
            if [ -n "$detected_server_host" ]; then
                info "Auto-detected Linux test server address: $detected_server_host"
            fi
            if [ -n "$detected_server_user" ]; then
                info "Auto-detected Linux test server user: $detected_server_user"
            fi
            info "Run the ZIP on the Windows PC with the USB-connected device, then keep running 'ohos xts ...' on this Linux test server."
            run_xts_bridge_tool package-windows "${bridge_args[@]}"
            ;;
        *)
            err "device bridge: unknown subcommand: $bridge_subcmd"
            print_help_device_bridge
            exit 1
            ;;
    esac
}

cmd_flash() {
    local firmware_path=""
    local devno=""
    local device=""
    local flash_server=""
    local resolved_flash_py=""
    local resolved_hdc_path=""
    local _flash_hdc_argv=""
    local _flash_hdc_restored=false

    _flash_cleanup() {
        if [ -n "$_flash_hdc_argv" ] && [ "$_flash_hdc_restored" = false ]; then
            restore_hdc_daemon "$_flash_hdc_argv"
            _flash_hdc_restored=true
        fi
        if [ -n "$flash_server" ] && [ -n "$resolved_hdc_path" ]; then
            _ssh_run "$flash_server" "nohup ${resolved_hdc_path} -m >/dev/null 2>&1 &" 2>/dev/null || true
        fi
        # Release flash lock on cleanup (success or failure)
        if [ -n "$device" ]; then
            _flash_release_lock "$device" "${flash_server:-}"
        fi
    }
    trap _flash_cleanup RETURN

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            help|--help|-h)
                print_help_device_flash
                return 0
                ;;
            --flash-firmware-path)
                shift; firmware_path="${1:-}"; shift || true
                ;;
            --devno)
                shift; devno="${1:-}"; shift || true
                ;;
            --device)
                shift; device="${1:-}"; shift || true
                ;;
            --server)
                shift; flash_server="${1:-}"; shift || true
                ;;
            --flash-py-path)
                shift; resolved_flash_py="${1:-}"; shift || true
                ;;
            --hdc-path)
                shift; resolved_hdc_path="${1:-}"; shift || true
                ;;
            -*)
                err "flash: unknown option: $1"
                print_help_device_flash
                return 1
                ;;
            *)
                # Positional arg = firmware path
                if [ -z "$firmware_path" ]; then
                    firmware_path="$1"
                    shift
                else
                    err "flash: unexpected argument: $1"
                    return 1
                fi
                ;;
        esac
    done

    # Auto-detect firmware if none given
    if [ -z "$firmware_path" ]; then
        firmware_path="$(pick_firmware_interactive)" || return 1
    fi

    # Resolve flash.py and hdc paths
    local canonical_flash_py="${FLASH_PY_PATH:-}"
    local canonical_hdc="${HDC_PATH:-hdc}"
    local canonical_flash_tool=""

    if [ -z "$resolved_flash_py" ]; then
        if [ -n "$canonical_flash_py" ]; then
            resolved_flash_py="$canonical_flash_py"
        else
            err "flash.py path not set. Set FLASH_PY_PATH in conf/ohos.conf"
            return 1
        fi
    fi
    if [ -z "$resolved_hdc_path" ]; then
        resolved_hdc_path="$canonical_hdc"
        if ! command -v "$resolved_hdc_path" &>/dev/null && [ ! -x "$resolved_hdc_path" ]; then
            err "hdc not found. Set HDC_PATH in conf/ohos.conf or add to \$PATH"
            return 1
        fi
    fi
    canonical_flash_tool="$(dirname "$resolved_flash_py")/bin/flash.$(uname -m)"

    # Validate firmware — remote or local
    if [ -n "$flash_server" ]; then
        if [ -z "$device" ]; then
            err "flash: --device is required with --server for remote flashing"
            return 1
        fi
        info "Remote flash: server=$flash_server device=$device"
        if ! _ssh_run "$flash_server" "test -f '${firmware_path}/MiniLoaderAll.bin'" 2>/dev/null; then
            if _ssh_run "$flash_server" "test -f '${firmware_path}/packages/phone/images/MiniLoaderAll.bin'" 2>/dev/null; then
                firmware_path="${firmware_path}/packages/phone/images"
            else
                err "Invalid firmware on $flash_server: missing MiniLoaderAll.bin in $firmware_path"
                return 1
            fi
        fi
    else
        if [ ! -f "${firmware_path}/MiniLoaderAll.bin" ]; then
            if [ -f "${firmware_path}/packages/phone/images/MiniLoaderAll.bin" ]; then
                firmware_path="${firmware_path}/packages/phone/images"
            else
                err "Invalid firmware: missing MiniLoaderAll.bin in $firmware_path"
                return 1
            fi
        fi
        if [ ! -x "$canonical_flash_tool" ]; then
            err "Flash tool not found: $canonical_flash_tool"
            return 1
        fi
    fi

    info "Firmware: $firmware_path"

    # ── Remote flash path ──────────────────────────────────────────────────
    if [ -n "$flash_server" ]; then
        # Resolve LocationID from boards.conf for CLI mode
        local locationid=""
        local i
        for i in $(seq 1 "$BOARD_COUNT"); do
            local serial_var="BOARD_${i}_SERIAL"
            if [ "${!serial_var}" = "$device" ]; then
                local loc_var="BOARD_${i}_LOCATIONID_LOADER"
                locationid="${!loc_var}"
                break
            fi
        done
        if [ -z "$locationid" ]; then
            warn "LocationID not found in boards.conf for $device, falling back to DevNo auto-detect"
        fi

        local device_short="${device: -6}"
        local tmux_session="flash-${device_short}"
        local log_dir="\${HOME}/flash-logs"
        local log_file="${log_dir}/${device_short}-$(date +%Y%m%d-%H%M%S).log"

        # Kill hdc daemon on remote (USB lock)
        _ssh_run "$flash_server" "pkill -f 'hdc -m' 2>/dev/null" || true
        sleep 1
        if _ssh_run "$flash_server" "pgrep -f 'hdc -m'" >/dev/null 2>&1; then
            err "Failed to kill hdc daemon on $flash_server — flash may fail. Check permissions."
        else
            info "Stopped remote hdc daemon"
        fi

        # Acquire flash lock
        if ! _flash_acquire_lock "$device" "$flash_server"; then
            return 1
        fi

        # Check if device is already in Loader mode (smart recovery)
        local current_mode=""
        current_mode="$(_check_device_mode_remote "$flash_server" "$canonical_flash_tool" "$locationid")" || true
        local loader_found=false

        if [ "$current_mode" = "Loader" ]; then
            info "Board ${device_short} already in Loader mode on $flash_server, skipping hdc switch"
            loader_found=true
        else
            # Switch device to Loader mode
            info "Switching device ${device_short} to Loader mode on $flash_server..."
            local switch_output
            switch_output="$(_ssh_run "$flash_server" "${resolved_hdc_path} -t ${device} target boot -bootloader 2>&1")" || true
            if echo "$switch_output" | grep -qi "fail\|error"; then
                warn "hdc switch returned: $switch_output"
            fi
            sleep 3

            # Wait for Loader mode on remote — use LocationID match
            info "Waiting for Loader mode..."
            local deadline
            deadline="$(($(date +%s) + 30))"
            while [ "$(date +%s)" -lt "$deadline" ]; do
                local ld_out
                ld_out="$(_ssh_run "$flash_server" "${canonical_flash_tool} LD 2>&1")" || true
                if echo "$ld_out" | grep -q "Mode=Loader"; then
                    if [ -n "$locationid" ] && echo "$ld_out" | grep -q "LocationID=${locationid}"; then
                        loader_found=true
                        break
                    elif [ -z "$locationid" ] && echo "$ld_out" | grep -q "Mode=Loader"; then
                        loader_found=true
                        break
                    fi
                fi
                sleep 2
            done
            if [ "$loader_found" = false ]; then
                err "Device ${device_short} did not enter Loader mode within 30s on $flash_server"
                return 1
            fi
            info "Device in Loader mode"
        fi

        # Build flash command for tmux
        local flash_cmd
        if [ -n "$locationid" ]; then
            flash_cmd="python3 ${resolved_flash_py} -a -i '${firmware_path}' -L ${locationid}"
        else
            flash_cmd="python3 ${resolved_flash_py} -a -i '${firmware_path}' -D \$(${canonical_flash_tool} LD 2>&1 | grep 'Mode=Loader' | head -1 | sed 's/DevNo=\\([0-9]*\\).*/\\1/')"
        fi

        # Kill existing tmux session if any
        _ssh_run "$flash_server" "tmux kill-session -t ${tmux_session} 2>/dev/null" || true

        # Create log directory and launch flash in tmux
        info "Launching flash in tmux session '${tmux_session}' on $flash_server..."
        _ssh_run "$flash_server" "mkdir -p ${log_dir}" || true
        _ssh_run "$flash_server" "tmux new-session -d -s ${tmux_session} \"${flash_cmd} 2>&1 | tee ${log_file}; echo 'EXIT_CODE='\$? >> ${log_file}; rm -f /tmp/ohos-flash-${device_short}.lock; nohup ${resolved_hdc_path} -m >/dev/null 2>&1 &\"" || {
            err "Failed to start tmux session on $flash_server"
            return 1
        }

        info "Flash running in tmux '${tmux_session}' on $flash_server"
        info "  Log: ${log_file}"
        info "  Attach: ssh $flash_server tmux attach -t ${tmux_session}"
        info "  Tail log: ssh $flash_server tail -f ${log_file}"

        # Wait for flash to complete (stream log to local console)
        info "--- Streaming flash log (Ctrl+C to detach, flash continues on server) ---"
        local ssh_user="${OHOS_SSH_USER:-${USER}}"
        ssh -o ConnectTimeout=5 -o BatchMode=yes \
            "${ssh_user}@${flash_server}" \
            "tail -f ${log_file} 2>/dev/null" &
        local tail_pid=$!

        # Wait for tmux session to end
        while _ssh_run "$flash_server" "tmux has-session -t ${tmux_session} 2>/dev/null"; do
            sleep 2
        done
        kill "$tail_pid" 2>/dev/null || true
        wait "$tail_pid" 2>/dev/null || true

        # Check result from log
        local exit_line
        exit_line="$(_ssh_run "$flash_server" "grep '^EXIT_CODE=' ${log_file} 2>/dev/null")" || true
        local flash_rc="${exit_line#EXIT_CODE=}"
        if [ -z "$flash_rc" ]; then
            flash_rc="-1"
        fi

        if [ "$flash_rc" -ne 0 ]; then
            err "Flashing ${device_short} failed (exit code $flash_rc)"
            err "Log: ssh $flash_server cat ${log_file}"
            return 1
        fi

        info "Flashing ${device: -6} completed successfully"
        _board_state_update "$device" "$firmware_path" "$flash_server" || true
        return 0
    fi

    # ── Local flash path ───────────────────────────────────────────────────
    local flash_tool="$canonical_flash_tool"

    # Resolve LocationID from boards.conf for local mode detection
    local expected_locationid=""
    if [ -n "$device" ]; then
        local _li
        for _li in $(seq 1 "${BOARD_COUNT:-0}"); do
            local sv="BOARD_${_li}_SERIAL"
            if [ "${!sv}" = "$device" ]; then
                local lv="BOARD_${_li}_LOCATIONID_LOADER"
                expected_locationid="${!lv}"
                break
            fi
        done
    fi

    # Kill hdc daemon (USB lock)
    _flash_hdc_argv="$(kill_hdc_daemon)" && info "Stopped hdc daemon" || true

    # Acquire flash lock if device specified
    if [ -n "$device" ]; then
        if ! _flash_acquire_lock "$device"; then
            return 1
        fi
    fi

    # If --device specified, check mode and switch if needed
    if [ -n "$device" ] && [ -n "$resolved_hdc_path" ]; then
        # Check if device is already in Loader mode (smart recovery)
        local local_mode=""
        if [ -n "$expected_locationid" ] && [ -x "$flash_tool" ]; then
            local_mode="$(_check_device_mode "$flash_tool" "$expected_locationid")" || true
        fi

        if [ "$local_mode" = "Loader" ]; then
            info "Board ${device: -6} already in Loader mode locally, skipping hdc switch"
            # Extract DevNo from flash_tool LD for this LocationID
            local ld_out
            ld_out="$("$flash_tool" LD 2>&1)" || true
            local match_line
            match_line="$(echo "$ld_out" | grep "LocationID=${expected_locationid}" | grep 'Mode=Loader' | head -1)" || true
            if [ -n "$match_line" ]; then
                devno="${match_line#DevNo=}"
                devno="${devno%%[!0-9]*}"
            fi
            if [ -z "$devno" ]; then
                # Fallback: pick first Loader device
                devno="$(wait_for_loader "$flash_tool" 5)" || {
                    err "Device $device in Loader mode but could not determine DevNo"
                    return 1
                }
            fi
            info "Device appeared as Loader DevNo=$devno"
        else
            # Normal path: switch device to Loader via hdc
            _flash_cleanup
            info "Switching device $device to Loader mode..."
            local switch_output
            switch_output="$("$resolved_hdc_path" -t "$device" target boot -bootloader 2>&1)" || true
            if echo "$switch_output" | grep -qi "fail\|error"; then
                warn "hdc switch to Loader returned: $switch_output"
            fi
            sleep 3
            # Kill hdc again (USB lock)
            _flash_hdc_argv="$(kill_hdc_daemon)" || true
            _flash_hdc_restored=false
            info "Waiting for device $device to enter Loader mode..."
            local loader_devno
            loader_devno="$(wait_for_loader "$flash_tool" 30)" || {
                err "Device $device did not appear in Loader mode within 30s"
                return 1
            }
            info "Device appeared as Loader DevNo=$loader_devno"
            devno="$loader_devno"
        fi
    elif [ -z "$devno" ]; then
        local existing_devno
        existing_devno="$(wait_for_loader "$flash_tool" 5)" || true
        if [ -z "$existing_devno" ]; then
            if [ -n "$resolved_hdc_path" ]; then
                _flash_cleanup
                local hdc_targets
                hdc_targets="$("$resolved_hdc_path" list targets 2>&1)" || hdc_targets=""
                device="$(echo "$hdc_targets" | head -1 | awk '{print $1}')"
                if [ -z "$device" ]; then
                    err "No devices found. Connect a device or specify --device <serial>"
                    return 1
                fi
                info "Switching device $device to Loader mode..."
                local switch_output
                switch_output="$("$resolved_hdc_path" -t "$device" target boot -bootloader 2>&1)" || true
                if echo "$switch_output" | grep -qi "fail\|error"; then
                    warn "hdc switch to Loader returned: $switch_output"
                fi
                sleep 3
                _flash_hdc_argv="$(kill_hdc_daemon)" || true
                _flash_hdc_restored=false
                info "Waiting for device to enter Loader mode..."
                local loader_devno
                loader_devno="$(wait_for_loader "$flash_tool" 30)" || {
                    err "Device did not appear in Loader mode within 30s"
                    return 1
                }
                devno="$loader_devno"
                info "Device appeared as Loader DevNo=$devno"
            else
                err "No device in Loader mode and no hdc available"
                return 1
            fi
        fi
    fi

    # Device selection
    if [ -n "$devno" ]; then
        info "Using specified DevNo=$devno"
    else
        devno="$(pick_device_interactive "$flash_tool")" || return 1
    fi

    info "Flashing device DevNo=$devno..."

    # Run flash.py with PTY support
    local flash_rc=0
    python3 "$resolved_flash_py" -a -i "$firmware_path" -D "$devno" || flash_rc=$?

    # Restore hdc daemon (via trap, but explicit for clearer log ordering)
    _flash_cleanup

    if [ "$flash_rc" -ne 0 ]; then
        err "Flashing failed (exit code $flash_rc)"
        return 1
    fi

    info "Flashing completed successfully"
    if [ -n "$device" ]; then
        _board_state_update "$device" "$firmware_path" || true
    fi
    return 0
}

cmd_list_targets() {
    local flash_py=""
    local flash_tool=""
    local hdc_path=""

    # Resolve flash.py — from config or error
    local canonical_flash_py="${FLASH_PY_PATH:-}"
    if [ -n "$canonical_flash_py" ] && [ -f "$canonical_flash_py" ]; then
        flash_py="$canonical_flash_py"
    fi
    if [ -n "$flash_py" ]; then
        flash_tool="$(dirname "$flash_py")/bin/flash.$(uname -m)"
    fi

    # Resolve hdc — from config or $PATH
    local canonical_hdc="${HDC_PATH:-hdc}"
    if command -v "$canonical_hdc" &>/dev/null || [ -x "$canonical_hdc" ]; then
        hdc_path="$canonical_hdc"
    fi

    echo "=== HDC targets ==="
    if [ -n "$hdc_path" ]; then
        if command -v detect_hdc_library_path &>/dev/null; then
            local hdc_lib_dir
            hdc_lib_dir="$(detect_hdc_library_path "$hdc_path" 2>/dev/null || true)"
            if [ -n "$hdc_lib_dir" ]; then
                LD_LIBRARY_PATH="$hdc_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$hdc_path" list targets -v 2>&1 || echo "(no devices)"
            else
                "$hdc_path" list targets -v 2>&1 || echo "(no devices)"
            fi
        else
            "$hdc_path" list targets -v 2>&1 || echo "(no devices)"
        fi
    else
        echo "(hdc not found)"
    fi

    echo ""
    echo "=== Rockchip devices ==="
    if [ -n "$flash_tool" ] && [ -x "$flash_tool" ]; then
        "$flash_tool" LD 2>&1 || echo "(no devices)"
    else
        echo "(flash tool not found)"
    fi
}

# ---------------------------------------------------------------------------
# _hdc_cmd — legacy inline HDC helper (deprecated, prefer _remote_exec)
#   Runs an HDC command on a remote server where the device is attached.
#   Usage: _hdc_cmd <server> <serial> <hdc_path> [args...]
#
#   DEPRECATED: New code should use _remote_exec + templates instead.
#   Kept for backward compatibility with ad-hoc diagnostic use.
# ---------------------------------------------------------------------------
_hdc_cmd() {
    local server="$1"
    local serial="$2"
    local hdc_path="$3"
    shift 3

    if [ -z "$server" ] || [ -z "$serial" ] || [ -z "$hdc_path" ]; then
        err "_hdc_cmd: missing required args (server, serial, hdc_path)"
        return 1
    fi

    if [ "$server" = "local" ]; then
        "$hdc_path" -t "$serial" "$@"
    else
        local ssh_user="${OHOS_SSH_USER:-${USER:-$(whoami 2>/dev/null)}}"
        ssh -o ConnectTimeout=5 -o BatchMode=yes \
            "${ssh_user}@${server}" \
            "$hdc_path" -t "$serial" "$@"
    fi
}

# ---------------------------------------------------------------------------
# print_help_device_init_board
# ---------------------------------------------------------------------------
print_help_device_init_board() {
    cat <<HELP
device init-board - prepare boards for testing

Prepares boards by waking the screen, disabling screen timeout,
setting performance mode, dismissing the USB dialog, and killing
the USB right manager.

Commands execute via scripts/remote/init-board.sh.template —
one SSH round-trip per board.

Options:
  --device <serial>    Target specific board (default: all OK boards)
  --timeout <ms>       Screen timeout in ms (default: 86400000 = 24h)
  --restore            Restore default power settings (timeout + normal mode)

Examples:
  ohos device init-board                         # prepare all boards
  ohos device init-board --device \$(serial)      # prepare one
  ohos device init-board --restore               # restore defaults
HELP
}

# ---------------------------------------------------------------------------
# print_help_device_power
# ---------------------------------------------------------------------------
print_help_device_power() {
    cat <<HELP
device power - control APC Rack PDU outlets

Subcommands:
  list                          Show all outlets status
  on <outlet|--board <name>>    Power on
  off <outlet|--board <name>>   Power off
  reboot|cycle <outlet|--board <name>>  Power cycle

Outlet numbers and board-to-outlet mapping defined in boards.conf.

Examples:
  ohos device power list
  ohos device power on 3
  ohos device power off --board feb8800
  ohos device power reboot --board a2eba00
  ohos device power status 4
HELP
}

# ---------------------------------------------------------------------------
# print_help_device_xts_run
# ---------------------------------------------------------------------------
print_help_device_xts_run() {
    cat <<HELP
device xts-run - run XTS static tests across multiple boards

Runs HAP-based XTS static regression tests in parallel across all
available boards. Tests are split round-robin; each board runs its
assigned tests serially via scripts/remote/xts-test-hap.sh.template.

Required:
  --tsv <file>       TSV with columns: hap_file, bundle_name, module_name
  --hap-dir <dir>    Directory containing the .hap files

Options:
  --output-dir <dir> Output directory (default: ./xts-results)
  --boards <list>    Comma-separated serials (default: auto from boards.conf)
  --ssh-user <user>  SSH user for remote servers (default: \$USER)
  --no-init          Skip board initialization before test run
  --continue         Skip tests already completed in output-dir

Output: per-group TSV results + merged summary.tsv with pass/fail counts.

Examples:
  ohos device xts-run --tsv tests.tsv --hap-dir /path/to/haps
  ohos device xts-run --tsv tests.tsv --hap-dir ./haps --continue
HELP
}

# ---------------------------------------------------------------------------
# print_help_device_xts_full_run
# ---------------------------------------------------------------------------
print_help_device_xts_full_run() {
    cat <<HELP
device xts-full-run - run XTS tests via xdevice framework

Runs XTS tests across multiple boards using the official xdevice test runner.
Supports full suite, pattern filtering, or specific modules by name.

Required:
  --acts-root <dir>  Path to ACTS suite root directory containing:
                     testcases/   - HAP files and test descriptors (.json)
                     config/      - xdevice config (acts.json, validator.json)
                     tools/       - xdevice Python packages (xdevice, xdevicecore)

                     Typically at: .../suites/acts/acts/
                     (the innermost 'acts' dir, not the outer suite wrapper)

Filtering (mutually exclusive):
  --pattern <glob>   Module glob pattern (default: ActsAce*)
  --modules <list>   Comma-separated exact module names (bypasses discovery)
  --variant <type>   Test variant: static, dynamic, any (default: any)

Board selection:
  --boards <list>    Comma-separated board short serials from boards.conf
  --devices <list>   Comma-separated device serials (overrides boards.conf)

Options:
  --conf-dir <dir>   Config directory (default: conf/)
  --shards <N>       Number of shards (default: one per device)
  --label <str>      Run label (default: full-run-YYYYMMDD-HHMMSS)
  --output-dir <dir> Output directory (default: xts_full_runs/<label>)
  --hdc <path>       Path to HDC binary
  --parallel <N>     Max parallel shards (default: one per shard)
  --timeout <secs>   Per-shard timeout (default: 7200)
  --dry-run          Print plan without executing
  --skip-connect     Skip HDC connectivity checks
  --skip-init        Skip board initialization (screen wake, USB dialog)

Examples:
  # Full ACE static run on all boards (typical daily run)
  ohos device xts-full-run \\
    --acts-root ~/xts/suites/acts/acts --variant static

  # Single module on one board (quick regression check after fix)
  ohos device xts-full-run \\
    --acts-root ~/xts/suites/acts/acts \\
    --modules ActsAceEtsComponentCommonAttrsDefaultFlex1StaticTest \\
    --boards myboard1

  # Multiple specific modules on 2 boards (split work)
  ohos device xts-full-run \\
    --acts-root ~/xts/suites/acts/acts \\
    --modules ActsAceEtsComponentCommonAttrsDefaultFlex1StaticTest,ActsAceEtsComponentCommonAttrsDefaultFlex2StaticTest \\
    --boards myboard1,myboard2

  # Pattern-filtered run (all DefaultFlex modules, static only)
  ohos device xts-full-run \\
    --acts-root ~/xts/suites/acts/acts \\
    --pattern "ActsAceEts*DefaultFlex*" --variant static

  # Dry run (show discovered modules and plan, no execution)
  ohos device xts-full-run \\
    --acts-root ~/xts/suites/acts/acts --dry-run

Module names: look inside acts-root/testcases/ — each HAP has a matching
.json descriptor. Module name = JSON filename minus .json extension.
Use --dry-run to list all discovered modules for a given --pattern.
HELP
}

# ---------------------------------------------------------------------------
# cmd_xts_full_run — run full XTS via xdevice framework
# ---------------------------------------------------------------------------
cmd_xts_full_run() {
    local python_script="${SCRIPT_DIR}/ohos_xts_full_run.py"
    if [ ! -f "$python_script" ]; then
        err "xts-full-run: ${python_script} not found"
        return 1
    fi
    python3 "$python_script" "$@"
}

# ---------------------------------------------------------------------------
# cmd_init_board — prepare boards for testing
# ---------------------------------------------------------------------------
cmd_init_board() {
    local device=""
    local timeout_ms="86400000"
    local mode="init"

    while [ $# -gt 0 ]; do
        case "$1" in
            help|--help|-h)
                print_help_device_init_board
                return 0
                ;;
            --device|-d)
                shift; device="${1:-}"; shift || true
                ;;
            --timeout|-t)
                shift; timeout_ms="${1:-86400000}"; shift || true
                ;;
            --restore|-r)
                mode="restore"; shift
                ;;
            *)
                err "init-board: unknown option: $1"
                return 1
                ;;
        esac
    done

    local resolved_hdc_path="${HDC_PATH:-hdc}"
    if ! command -v "$resolved_hdc_path" &>/dev/null && [ ! -x "$resolved_hdc_path" ]; then
        err "hdc not found. Set HDC_PATH in conf/ohos.conf or add to \$PATH"
        return 1
    fi

    if [ -n "$device" ]; then
        local found=false
        local i
        for i in $(seq 1 "$BOARD_COUNT"); do
            local serial_var="BOARD_${i}_SERIAL"
            local server_var="BOARD_${i}_SERVER"
            local status_var="BOARD_${i}_STATUS"
            if [ "${!serial_var}" = "$device" ]; then
                if [ "${!status_var}" != "OK" ]; then
                    err "Board $device status is ${!status_var}, skipping"
                    return 1
                fi
                info "Initializing $device on ${!server_var}..."
                _remote_exec "${!server_var}" init-board \
                    HDC_PATH="$resolved_hdc_path" \
                    SERIAL="$device" \
                    TIMEOUT_MS="$timeout_ms" \
                    MODE="$mode" || true
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            err "Board $device not found in boards.conf"
            return 1
        fi
    else
        local i
        for i in $(seq 1 "$BOARD_COUNT"); do
            local serial_var="BOARD_${i}_SERIAL"
            local server_var="BOARD_${i}_SERVER"
            local status_var="BOARD_${i}_STATUS"
            if [ "${!status_var}" != "OK" ]; then
                info "Skipping board ${!serial_var} (status: ${!status_var})"
                continue
            fi
            info "Initializing ${!serial_var} on ${!server_var}..."
            _remote_exec "${!server_var}" init-board \
                HDC_PATH="$resolved_hdc_path" \
                SERIAL="${!serial_var}" \
                TIMEOUT_MS="$timeout_ms" \
                MODE="$mode" || true
        done
    fi
    info "Board initialization complete"
}

# ---------------------------------------------------------------------------
# _pdu_cmd — send a command to APC Rack PDU via telnet
# ---------------------------------------------------------------------------
_pdu_cmd() {
    local action="$1"
    local outlet="$2"

    local pdu_host="${PDU_HOST:-}"
    local pdu_user="${PDU_USER:-device}"
    local pdu_pass="${PDU_PASS:-}"

    if [ -z "$pdu_host" ]; then
        err "PDU host not configured in boards.conf (PDU_HOST)"
        return 1
    fi
    if [ -z "$pdu_pass" ]; then
        err "PDU password not configured in boards.conf (PDU_PASS)"
        return 1
    fi

    local apc_cmd=""
    case "$action" in
        on)     apc_cmd="olOn $outlet" ;;
        off)    apc_cmd="olOff $outlet" ;;
        reboot|cycle) apc_cmd="olReboot $outlet" ;;
        status) apc_cmd="olStatus $outlet" ;;
        list)   apc_cmd="olStatus" ;;
        *)
            err "_pdu_cmd: unknown action: $action"
            return 1
            ;;
    esac

    info "PDU $action outlet $outlet on $pdu_host..."

    python3 - "$pdu_host" "$pdu_user" "$pdu_pass" "$apc_cmd" <<'PYEOF'
import sys, telnetlib, time
host, user, passwd, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    tn = telnetlib.Telnet(host, 23, timeout=10)
    tn.read_until(b"User Name :", timeout=5)
    tn.write(user.encode() + b"\r\n")
    tn.read_until(b"Password :", timeout=5)
    tn.write(passwd.encode() + b"\r\n")
    data = tn.read_until(b">", timeout=10)
    if b"User Name" in data:
        print("ERROR: PDU login failed — check PDU_USER/PDU_PASS", file=sys.stderr)
        sys.exit(1)
    tn.write(cmd.encode() + b"\r\n")
    time.sleep(1)
    output = tn.read_very_eager().decode("utf-8", errors="replace")
    print(output.strip())
    tn.write(b"exit\r\n")
    tn.close()
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    if [ "$action" = "reboot" ] || [ "$action" = "cycle" ]; then
        info "Power cycle initiated for outlet $outlet; waiting 15s for board..."
        sleep 15
    fi
}

# ---------------------------------------------------------------------------
# _pdu_list — list outlets from APC PDU and annotate with board names
# ---------------------------------------------------------------------------
_pdu_list() {
    local pdu_host="${PDU_HOST:-}"
    local pdu_user="${PDU_USER:-device}"
    local pdu_pass="${PDU_PASS:-}"

    if [ -z "$pdu_host" ]; then
        err "PDU host not configured (PDU_HOST)"
        return 1
    fi
    if [ -z "$pdu_pass" ]; then
        err "PDU password not configured (PDU_PASS)"
        return 1
    fi

    info "PDU outlets on $pdu_host:"
    echo ""

    local raw_out
    raw_out="$(python3 - "$pdu_host" "$pdu_user" "$pdu_pass" "olStatus all" <<'PYEOF'
import sys, telnetlib, time
host, user, passwd, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    tn = telnetlib.Telnet(host, 23, timeout=10)
    tn.read_until(b"User Name :", timeout=5)
    tn.write(user.encode() + b"\r\n")
    tn.read_until(b"Password :", timeout=5)
    tn.write(passwd.encode() + b"\r\n")
    data = tn.read_until(b">", timeout=10)
    if b"User Name" in data:
        print("ERROR: PDU login failed", file=sys.stderr)
        sys.exit(1)
    tn.write(cmd.encode() + b"\r\n")
    time.sleep(1)
    output = tn.read_very_eager().decode("utf-8", errors="replace")
    print(output.strip())
    tn.write(b"exit\r\n")
    tn.close()
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)" || {
        err "PDU list failed (telnet to $pdu_host)"
        return 1
    }

    # Build outlet→board mapping
    local -A outlet_board
    local i
    for i in $(seq 1 "${BOARD_COUNT:-0}"); do
        local outlet_var="BOARD_${i}_OUTLET"
        local short_var="BOARD_${i}_SHORT"
        local label_var="BOARD_${i}_LABEL"
        local o="${!outlet_var}"
        [ -n "$o" ] && outlet_board[$o]="${!label_var} (${!short_var})"
    done

    echo "$raw_out" | while IFS= read -r line; do
        local outlet_num
        outlet_num="$(echo "$line" | grep -oE '^[0-9]+' | head -1)" || true
        if [ -n "$outlet_num" ] && [ -n "${outlet_board[$outlet_num]:-}" ]; then
            echo "  $line  [${outlet_board[$outlet_num]}]"
        else
            echo "  $line"
        fi
    done
}

# ---------------------------------------------------------------------------
# cmd_power — PDU power control entry point
# ---------------------------------------------------------------------------
cmd_power() {
    local subcmd="${1:-help}"
    [ $# -gt 0 ] && shift

    case "$subcmd" in
        help|--help|-h|"")
            print_help_device_power
            ;;
        list)
            _pdu_list
            ;;
        on|off|reboot|cycle|status)
            local outlet=""
            local target=""

            while [ $# -gt 0 ]; do
                case "$1" in
                    --board|-b)
                        shift; target="${1:-}"; shift || true
                        ;;
                    --outlet|-o)
                        shift; outlet="${1:-}"; shift || true
                        ;;
                    -*)
                        err "power $subcmd: unknown option: $1"
                        return 1
                        ;;
                    *)
                        [ -z "$outlet" ] && [[ "$1" =~ ^[0-9]+$ ]] && outlet="$1" && shift && continue
                        err "power $subcmd: unexpected argument: $1"
                        return 1
                        ;;
                esac
            done

            # Resolve --board to outlet number
            if [ -n "$target" ] && [ -z "$outlet" ]; then
                local i
                for i in $(seq 1 "$BOARD_COUNT"); do
                    local serial_var="BOARD_${i}_SERIAL"
                    local short_var="BOARD_${i}_SHORT"
                    if [[ "${!serial_var}" = *"$target"* ]] || [ "${!short_var}" = "$target" ]; then
                        local outlet_var="BOARD_${i}_OUTLET"
                        outlet="${!outlet_var}"
                        break
                    fi
                done
                if [ -z "$outlet" ]; then
                    err "Board matching '$target' not found in boards.conf"
                    return 1
                fi
            fi

            if [ -z "$outlet" ]; then
                err "power $subcmd requires an outlet number or --board <name>"
                return 1
            fi

            _pdu_cmd "$subcmd" "$outlet"
            ;;
        *)
            err "device power: unknown subcommand: $subcmd"
            print_help_device_power
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# cmd_xts_run — run XTS static HAPs across all boards
# ---------------------------------------------------------------------------
cmd_xts_run() {
    local tsv_file=""
    local hap_dir=""
    local output_dir="./xts-results"
    local board_list=""
    local ssh_user=""
    local no_init=false
    local do_continue=false

    while [ $# -gt 0 ]; do
        case "$1" in
            help|--help|-h)
                print_help_device_xts_run
                return 0
                ;;
            --tsv)           shift; tsv_file="${1:-}"; shift || true ;;
            --hap-dir)       shift; hap_dir="${1:-}"; shift || true ;;
            --output-dir)    shift; output_dir="${1:-}"; shift || true ;;
            --boards)        shift; board_list="${1:-}"; shift || true ;;
            --ssh-user)      shift; ssh_user="${1:-}"; shift || true ;;
            --no-init)       no_init=true; shift ;;
            --continue|-c)   do_continue=true; shift ;;
            *)
                err "xts-run: unknown option: $1"
                return 1
                ;;
        esac
    done

    if [ -z "$tsv_file" ]; then
        err "xts-run: --tsv is required"
        return 1
    fi
    if [ -z "$hap_dir" ]; then
        err "xts-run: --hap-dir is required"
        return 1
    fi
    [ -f "$tsv_file" ] || { err "TSV file not found: $tsv_file"; return 1; }
    [ -d "$hap_dir" ]  || { err "HAP directory not found: $hap_dir"; return 1; }

    mkdir -p "$output_dir"

    local resolved_hdc_path="${HDC_PATH:-hdc}"
    if ! command -v "$resolved_hdc_path" &>/dev/null && [ ! -x "$resolved_hdc_path" ]; then
        err "hdc not found. Set HDC_PATH in conf/ohos.conf or add to \$PATH"
        return 1
    fi

    # Build list of board serials
    local -a boards=()
    if [ -n "$board_list" ]; then
        IFS=',' read -ra boards <<< "$board_list"
    else
        local i
        for i in $(seq 1 "$BOARD_COUNT"); do
            local status_var="BOARD_${i}_STATUS"
            local serial_var="BOARD_${i}_SERIAL"
            [ "${!status_var}" = "OK" ] && boards+=("${!serial_var}")
        done
    fi
    [ ${#boards[@]} -gt 0 ] || { err "No boards available"; return 1; }

    [ -n "$ssh_user" ] && OHOS_SSH_USER="$ssh_user"

    if [ "$no_init" = false ]; then
        info "Initializing boards..."
        cmd_init_board || true
    fi

    # Read TSV — columns: hap_file, bundle_name, module_name
    local -a hap_files=()
    local -a bundle_names=()
    local -a module_names=()
    local line_num=0

    while IFS=$'\t' read -r hap bundle module rest; do
        line_num=$((line_num + 1))
        [ "$line_num" -eq 1 ] && continue
        [ -z "$hap" ] && continue
        hap_files+=("$hap")
        bundle_names+=("$bundle")
        module_names+=("$module")
    done < "$tsv_file"

    local total_tests=${#hap_files[@]}
    [ "$total_tests" -gt 0 ] || { err "No test entries in $tsv_file"; return 1; }
    info "Found $total_tests tests, ${#boards[@]} board(s)"

    local num_groups=${#boards[@]}

    # Launch per-board groups in parallel (round-robin via line_num filter)
    local -a group_pids=()
    local group_num=0
    local b
    for b in "${!boards[@]}"; do
        local serial="${boards[$b]}"
        (
            cmd_xts_run_group \
                "$serial" \
                "$tsv_file" \
                "$hap_dir" \
                "$output_dir" \
                "$group_num" \
                "$num_groups" \
                "$resolved_hdc_path" \
                "$do_continue"
        ) &
        group_pids[$b]=$!
        group_num=$((group_num + 1))
    done

    info "Waiting for ${#group_pids[@]} group(s) to finish..."
    local rc=0
    for b in "${!group_pids[@]}"; do
        wait "${group_pids[$b]}" || rc=$?
    done

    # Merge results
    info "Merging results..."
    local summary_file="${output_dir}/summary.tsv"
    {
        echo -e "hap_file\tbundle_name\tmodule_name\tgroup\tstatus\tdetails"
        local g
        for ((g=0; g<group_num; g++)); do
            local grp_res="${output_dir}/group_${g}_results.tsv"
            [ -f "$grp_res" ] && tail -n +2 "$grp_res" | while IFS=$'\t' read -r hap bundle module status details; do
                echo -e "${hap}\t${bundle}\t${module}\t${g}\t${status}\t${details}"
            done
        done
    } > "$summary_file"

    local pass_count
    local fail_count
    local crash_count
    local timeout_count
    pass_count="$(grep -c $'\tPASS\t' "$summary_file" 2>/dev/null || echo 0)"
    fail_count="$(grep -c $'\tPARTIAL\t' "$summary_file" 2>/dev/null || echo 0)"
    crash_count="$(grep -c $'\tCRASH\t' "$summary_file" 2>/dev/null || echo 0)"
    timeout_count="$(grep -c $'\tTIMEOUT\t' "$summary_file" 2>/dev/null || echo 0)"

    info "=== XTS Run Summary ==="
    info "Total: $total_tests | Pass: $pass_count | Fail: $fail_count | Crash: $crash_count | Timeout: $timeout_count"
    info "Summary: $summary_file"
    info "Logs:"
    for ((g=0; g<group_num; g++)); do
        local grp_dir="${output_dir}/group_${g}"
        [ -d "$grp_dir" ] && info "  Group $g: ${grp_dir}/"
    done
    info "Method: aa test (HDC direct)"
}

# ---------------------------------------------------------------------------
# cmd_xts_run_group — run a batch of tests on one board serially
# ---------------------------------------------------------------------------
cmd_xts_run_group() {
    local serial="$1"; shift
    local tsv_file="$1"; shift
    local hap_dir="$1"; shift
    local output_dir="$1"; shift
    local group_num="$1"; shift
    local num_groups="$1"; shift
    local hdc_path="$1"; shift
    local do_continue="${1:-false}"; shift || true

    local group_results="${output_dir}/group_${group_num}_results.tsv"
    local group_log="${output_dir}/group_${group_num}.log"
    local group_log_dir="${output_dir}/group_${group_num}"

    mkdir -p "$group_log_dir"
    # NFS: remote servers may have different uid; ensure writable via 'other'
    chmod 777 "$group_log_dir" 2>/dev/null || true

    # Find which server this board is on
    local server=""
    local i
    for i in $(seq 1 "$BOARD_COUNT"); do
        local serial_var="BOARD_${i}_SERIAL"
        if [ "${!serial_var}" = "$serial" ]; then
            local server_var="BOARD_${i}_SERVER"
            server="${!server_var}"
            break
        fi
    done
    if [ -z "$server" ]; then
        err "Group $group_num: board $serial not in boards.conf"
        return 1
    fi

    {
        echo -e "hap_file\tbundle_name\tmodule_name\tstatus\tdetails"
    } > "$group_results"

    local line_num=0
    while IFS=$'\t' read -r hap bundle module rest; do
        line_num=$((line_num + 1))
        [ "$line_num" -eq 1 ] && continue
        [ -z "$hap" ] && continue
        # Round-robin: skip lines not assigned to this group
        (( (line_num - 2) % num_groups != group_num )) && continue

        # Check if already completed
        if [ "$do_continue" = true ] && grep -q "$hap" "$group_results" 2>/dev/null; then
            continue
        fi

        local hap_path="${hap_dir}/${hap}"
        if [ ! -f "$hap_path" ]; then
            echo -e "${hap}\t${bundle}\t${module}\tSKIP\tFile not found" >> "$group_results"
            continue
        fi

        info "Group $group_num: $hap on $serial..."

        local result_file="$group_log_dir/${hap%.hap}.result.txt"
        _remote_exec_nfs "$server" xts-test-hap "$result_file" \
            HDC_PATH="$hdc_path" \
            SERIAL="$serial" \
            HAP_PATH="$hap_path" \
            BUNDLE="$bundle" \
            MODULE="$module" \
            DEVICE_TMP="/data/local/tmp/${hap}" \
            TEST_WINDOW="600" \
            INSTALL_METHOD="direct" \
            LOG_DIR="$group_log_dir" \
            RESULT_FILE="$result_file" || true

        local result
        result="$(cat "$result_file" 2>/dev/null || echo "")"
        rm -f "$result_file"

        local code="UNKNOWN"
        local msg="no result from template"
        case "$result" in
            PASS*|PARTIAL*|INSTALL_FAIL*|CRASH*|TIMEOUT*|NOT_INSTALLED*|EXEC_FAIL*|SKIP*)
                # Extract first word as code, rest as message
                code="${result%% *}"
                msg="${result#* }"
                ;;
        esac
        echo -e "${hap}\t${bundle}\t${module}\t${code}\t${msg}" >> "$group_results"

        echo "=== $hap ===" >> "$group_log"
        echo "$result" >> "$group_log"
    done < "$tsv_file"

    info "Group $group_num ($serial) done"
}

subcmd="${1:-help}"
if [ $# -gt 0 ]; then
    shift
fi

case "$subcmd" in
    help|--help|-h|"")
        print_help_device
        ;;
    init-board)
        cmd_init_board "$@"
        ;;
    bridge)
        cmd_bridge "$@"
        ;;
    flash)
        cmd_flash "$@"
        ;;
    firmware)
        cmd_firmware "$@"
        ;;
    list-targets)
        cmd_list_targets "$@"
        ;;
    power)
        cmd_power "$@"
        ;;
    xts-run)
        cmd_xts_run "$@"
        ;;
    xts-full-run)
        cmd_xts_full_run "$@"
        ;;
    __test-internal)
        # Internal test dispatch — not documented, not for production use
        # At this point $1=test_cmd $2+=args (outer shift already consumed __test-internal)
        case "${1:-}" in
            extract-firmware-version) shift; _extract_firmware_version "$@" ;;
            board-state-update) shift; _board_state_update "$@" ;;
            check-device-mode) shift; _check_device_mode "$@" ;;
            flash-lock-path) shift; _flash_lock_path "$@" ;;
            flash-acquire-lock) shift; _flash_acquire_lock "$@" ;;
            flash-release-lock) shift; _flash_release_lock "$@" ;;
            board-state-file) _board_state_file ;;
            board-state-read) _board_state_read ;;
            *) echo "Unknown test command: ${1:-}" >&2; exit 1 ;;
        esac
        ;;
    *)
        err "device: unknown subcommand: $subcmd"
        print_help_device
        exit 1
        ;;
esac
