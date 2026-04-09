#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OHOS_SH="${OHOS_SH:-${SCRIPT_DIR}/ohos.sh}"

BUILD_TAG=""
BUILD_DATE=""
COMPONENT="dayu200"
BRANCH="master"
DEVICE=""
LOG_FILE=""
SKIP_DOWNLOAD=0
RUN_FULL_FLASHPY=0

print_usage() {
    cat <<'EOF'
Usage:
  ohos_flash_diag.sh --build-tag <YYYYMMDD_HHMMSS> --date <YYYYMMDD> [options]

Options:
  --build-tag <tag>       Daily build tag, for example 20260409_180241.
  --date <date>           Daily build date, for example 20260409.
  --component <name>      Firmware component. Default: dayu200.
  --branch <name>         Daily branch. Default: master.
  --device <serial>       Explicit HDC device serial for bootloader switch.
  --log-file <path>       Write logs to this file. Default: <cwd>/logs/flash_diag_<component>_<tag>_<utc>.log
  --skip-download         Reuse the existing extracted image bundle under /tmp.
  --full-flashpy          After UL + DI -p, also run flash.py -a -i <image_root>.
  -h, --help              Show this help.

What it does:
  1. Logs env and tool resolution.
  2. Checks ~/.config/upgrade_tool/config.ini.
  3. Optionally downloads the requested daily image package via ohos.sh.
  4. Switches the device into bootloader mode through hdc.
  5. Runs flash.x86_64 steps separately: LD, UL, DI -p.
  6. Optionally runs the full flash.py flow.

Warning:
  This script reboots the device into bootloader and writes loader / GPT metadata.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build-tag)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            BUILD_TAG="$2"
            shift 2
            ;;
        --build-tag=*)
            BUILD_TAG="${1#*=}"
            shift
            ;;
        --date)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            BUILD_DATE="$2"
            shift 2
            ;;
        --date=*)
            BUILD_DATE="${1#*=}"
            shift
            ;;
        --component)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            COMPONENT="$2"
            shift 2
            ;;
        --component=*)
            COMPONENT="${1#*=}"
            shift
            ;;
        --branch)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            BRANCH="$2"
            shift 2
            ;;
        --branch=*)
            BRANCH="${1#*=}"
            shift
            ;;
        --device)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            DEVICE="$2"
            shift 2
            ;;
        --device=*)
            DEVICE="${1#*=}"
            shift
            ;;
        --log-file)
            [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            LOG_FILE="$2"
            shift 2
            ;;
        --log-file=*)
            LOG_FILE="${1#*=}"
            shift
            ;;
        --skip-download)
            SKIP_DOWNLOAD=1
            shift
            ;;
        --full-flashpy)
            RUN_FULL_FLASHPY=1
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            print_usage >&2
            exit 2
            ;;
    esac
done

[ -n "$BUILD_TAG" ] || { echo "--build-tag is required" >&2; print_usage >&2; exit 2; }
[ -n "$BUILD_DATE" ] || { echo "--date is required" >&2; print_usage >&2; exit 2; }

timestamp_utc="$(date -u +%Y%m%dT%H%M%SZ)"
DEFAULT_LOG_ROOT="$(pwd)/logs"
if [ -z "$LOG_FILE" ]; then
    LOG_FILE="${DEFAULT_LOG_ROOT}/flash_diag_${COMPONENT}_${BUILD_TAG}_${timestamp_utc}.log"
fi

if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
    fallback_log_root="${HOME}/ohos-logs"
    mkdir -p "${fallback_log_root}"
    LOG_FILE="${fallback_log_root}/flash_diag_${COMPONENT}_${BUILD_TAG}_${timestamp_utc}.log"
fi

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    printf '[diag] %s\n' "$*"
}

render_cmd() {
    local rendered=""
    local arg
    for arg in "$@"; do
        rendered+=" $(printf '%q' "$arg")"
    done
    printf '%s\n' "${rendered# }"
}

run_step() {
    local label="$1"
    shift
    local rc=0
    printf '\n===== %s =====\n' "$label"
    printf '+ %s\n' "$(render_cmd "$@")"
    "$@"
    rc=$?
    printf '[rc=%s] %s\n' "$rc" "$label"
    return "$rc"
}

run_maybe_fail() {
    local label="$1"
    local rc=0
    shift
    run_step "$label" "$@"
    rc=$?
    return "$rc"
}

FLASH_PY_PATH="${FLASH_PY_PATH:-$HOME/bin/linux/flash.py}"
FLASH_TOOL_PATH="${FLASH_TOOL_PATH:-${FLASH_PY_PATH%/*}/bin/flash.$(uname -m)}"
HDC_PATH="${HDC_PATH:-$(command -v hdc 2>/dev/null || true)}"
UPGRADE_CONFIG_PATH="${UPGRADE_CONFIG_PATH:-$HOME/.config/upgrade_tool/config.ini}"
IMAGE_ROOT="/tmp/arkui_xts_selector_daily_cache/${COMPONENT}/${BUILD_TAG}/image_bundle"

failures=()

record_failure() {
    failures+=("$1")
}

ensure_upgrade_config() {
    local config_dir
    config_dir="$(dirname "$UPGRADE_CONFIG_PATH")"
    mkdir -p "$config_dir"
    if [ -f "$UPGRADE_CONFIG_PATH" ]; then
        return 0
    fi
    cat >"$UPGRADE_CONFIG_PATH" <<'EOF'
firmware=
loader=
parameter=
misc=
boot=
kernel=
system=
recovery=
rockusb_id=
msc_id=
rb_check_off=true
EOF
}

trap 'printf "\n[diag] Log file: %s\n" "$LOG_FILE"' EXIT

log "Starting flash diagnostics"
log "Log file: $LOG_FILE"
log "SCRIPT_DIR=$SCRIPT_DIR"
log "HOME=$HOME"
log "USER=${USER:-}"
log "PWD=$(pwd)"

run_maybe_fail "ensure_upgrade_config" ensure_upgrade_config || record_failure "ensure_upgrade_config"
run_maybe_fail "system_info" uname -a || record_failure "system_info"
run_maybe_fail "user_identity" id || record_failure "user_identity"
run_maybe_fail "resolve_ohos_sh" bash -lc "command -v '$OHOS_SH' >/dev/null 2>&1 || true; ls -l '$OHOS_SH'" || record_failure "resolve_ohos_sh"
run_maybe_fail "resolve_hdc" bash -lc "command -v hdc || true; type -a hdc || true; ls -l '$HDC_PATH' || true" || record_failure "resolve_hdc"
run_maybe_fail "resolve_flash_tools" bash -lc "ls -l '$FLASH_PY_PATH' '$FLASH_TOOL_PATH'" || record_failure "resolve_flash_tools"
run_maybe_fail "flash_tool_ldd" ldd "$FLASH_TOOL_PATH" || record_failure "flash_tool_ldd"
run_maybe_fail "hdc_version" "$HDC_PATH" -v || record_failure "hdc_version"
run_maybe_fail "upgrade_config_stat" bash -lc "stat '$UPGRADE_CONFIG_PATH' && printf '\\n'; sed -n '1,120p' '$UPGRADE_CONFIG_PATH'" || record_failure "upgrade_config_stat"
run_maybe_fail "python_home_check" python3 - <<'PY' || record_failure "python_home_check"
import os
import pathlib
config = pathlib.Path.home() / ".config" / "upgrade_tool" / "config.ini"
print("python HOME =", os.environ.get("HOME"))
print("Path.home()  =", pathlib.Path.home())
print("config path  =", config)
print("exists       =", config.exists())
if config.exists():
    print(config.read_text(encoding="utf-8"))
PY

if command -v strace >/dev/null 2>&1; then
    run_maybe_fail "flash_ld_openat_trace" strace -f -e openat "$FLASH_TOOL_PATH" LD || record_failure "flash_ld_openat_trace"
fi

if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
    run_maybe_fail \
        "download_daily_firmware" \
        "$OHOS_SH" xts --download-daily-firmware \
        --firmware-component "$COMPONENT" \
        --firmware-branch "$BRANCH" \
        --firmware-build-tag "$BUILD_TAG" \
        --firmware-date "$BUILD_DATE" || record_failure "download_daily_firmware"
fi

if [ ! -f "$IMAGE_ROOT/parameter.txt" ]; then
    discovered_root="$(find "/tmp/arkui_xts_selector_daily_cache/${COMPONENT}/${BUILD_TAG}" -type f -name parameter.txt -printf '%h\n' 2>/dev/null | sort | head -n 1)"
    if [ -n "${discovered_root:-}" ]; then
        IMAGE_ROOT="$discovered_root"
    fi
fi

if [ ! -f "$IMAGE_ROOT/parameter.txt" ]; then
    log "Image bundle not found under $IMAGE_ROOT"
    record_failure "locate_image_bundle"
else
    run_maybe_fail "image_bundle_listing" bash -lc "ls -la '$IMAGE_ROOT' | sed -n '1,120p'" || record_failure "image_bundle_listing"
    run_maybe_fail "parameter_preview" sed -n '1,120p' "$IMAGE_ROOT/parameter.txt" || record_failure "parameter_preview"
fi

run_maybe_fail "hdc_list_targets" "$HDC_PATH" list targets || record_failure "hdc_list_targets"

if [ -n "$DEVICE" ]; then
    run_maybe_fail "hdc_bootloader_switch" "$HDC_PATH" -t "$DEVICE" target boot -bootloader || record_failure "hdc_bootloader_switch"
else
    run_maybe_fail "hdc_bootloader_switch" "$HDC_PATH" target boot -bootloader || record_failure "hdc_bootloader_switch"
fi

run_maybe_fail "wait_after_bootloader_switch" sleep 3 || record_failure "wait_after_bootloader_switch"
run_maybe_fail "flash_ld" env HOME="$HOME" "$FLASH_TOOL_PATH" LD || record_failure "flash_ld"

if [ -f "$IMAGE_ROOT/MiniLoaderAll.bin" ]; then
    run_maybe_fail "flash_ul_loader" env HOME="$HOME" "$FLASH_TOOL_PATH" UL "$IMAGE_ROOT/MiniLoaderAll.bin" || record_failure "flash_ul_loader"
else
    log "MiniLoaderAll.bin not found: $IMAGE_ROOT/MiniLoaderAll.bin"
    record_failure "flash_ul_loader_missing"
fi

if [ -f "$IMAGE_ROOT/parameter.txt" ]; then
    run_maybe_fail "flash_di_parameter" env HOME="$HOME" "$FLASH_TOOL_PATH" DI -p "$IMAGE_ROOT/parameter.txt" || record_failure "flash_di_parameter"
else
    log "parameter.txt not found: $IMAGE_ROOT/parameter.txt"
    record_failure "flash_di_parameter_missing"
fi

if [ "$RUN_FULL_FLASHPY" -eq 1 ]; then
    run_maybe_fail "flash_py_all" env HOME="$HOME" python3 "$FLASH_PY_PATH" -a -i "$IMAGE_ROOT" || record_failure "flash_py_all"
fi

printf '\n===== summary =====\n'
if [ "${#failures[@]}" -eq 0 ]; then
    log "No failing diagnostic steps."
    exit 0
fi

printf '[diag] Failing steps:\n'
for item in "${failures[@]}"; do
    printf '  - %s\n' "$item"
done
exit 1
