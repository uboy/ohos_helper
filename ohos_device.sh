#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
    case "$0" in
        */ohos_device.sh|ohos_device.sh)
            exec bash "$0" "$@"
            ;;
    esac
    printf '%s\n' "ohos_device.sh requires bash. Run it with: bash /data/shared/common/scripts/ohos_device.sh ..." >&2
    return 1 2>/dev/null || exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OHOS_CONF="${OHOS_CONF:-${SCRIPT_DIR}/ohos.conf}"
OHOS_XTS_BRIDGE_TOOL="${OHOS_XTS_BRIDGE_TOOL:-${SCRIPT_DIR}/ohos_xts_bridge.py}"
ARKUI_XTS_SELECTOR_DIR="${ARKUI_XTS_SELECTOR_DIR:-${SCRIPT_DIR}/arkui-xts-selector}"
XTS_WINDOWS_BRIDGE_OUTPUT_ROOT="${XTS_WINDOWS_BRIDGE_OUTPUT_ROOT:-$HOME/ohos-xts-bridge}"
OHOS_DEVICE_SERVER_HOST="${OHOS_DEVICE_SERVER_HOST:-}"
OHOS_DEVICE_SERVER_USER="${OHOS_DEVICE_SERVER_USER:-}"
OHOS_REPO_ROOT="${OHOS_REPO_ROOT:-}"
OHOS_DEVICE_ACTIVE_CHILD_PID=""
OHOS_DEVICE_SIGNAL_MESSAGE_EMITTED=0

if [ -f "$OHOS_CONF" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_CONF"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${GREEN}[ohos-device]${NC} $*"; }
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
    return "$rc"
}

device_run_foreground() {
    "$@" &
    OHOS_DEVICE_ACTIVE_CHILD_PID=$!
    device_wait_active_child
}

device_forward_signal() {
    local signal_name="$1"
    local pid="${OHOS_DEVICE_ACTIVE_CHILD_PID:-}"
    local _attempt=0

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -s "$signal_name" "$pid" 2>/dev/null || true
        for _attempt in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                OHOS_DEVICE_ACTIVE_CHILD_PID=""
                return 0
            fi
            sleep 0.1
        done
        kill -TERM "$pid" 2>/dev/null || true
        for _attempt in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                OHOS_DEVICE_ACTIVE_CHILD_PID=""
                return 0
            fi
            sleep 0.1
        done
        kill -KILL "$pid" 2>/dev/null || true
        OHOS_DEVICE_ACTIVE_CHILD_PID=""
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

has_long_flag() {
    local wanted="$1"
    shift
    local item
    for item in "$@"; do
        if [ "$item" = "$wanted" ]; then
            return 0
        fi
        case "$item" in
            "${wanted}"=*)
                return 0
                ;;
        esac
    done
    return 1
}

get_long_flag_value() {
    local wanted="$1"
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            "${wanted}")
                shift || true
                if [ $# -gt 0 ]; then
                    printf '%s\n' "$1"
                    return 0
                fi
                return 1
                ;;
            "${wanted}"=*)
                printf '%s\n' "${1#*=}"
                return 0
                ;;
        esac
        shift || true
    done
    return 1
}

xts_default_run_store_root() {
    printf '%s\n' "${SCRIPT_DIR}/arkui-xts-selector/.runs"
}

looks_like_ohos_repo_root() {
    local candidate="${1:-}"
    [ -n "$candidate" ] || return 1
    [[ -d "$candidate/.repo" ]] && [[ -f "$candidate/build/prebuilts_download.sh" ]]
}

detect_hdc_library_path() {
    local hdc_path="${1:-${HDC_PATH:-}}"
    local hdc_dir=""
    local candidate=""

    if [ -n "${HDC_LIBRARY_PATH:-}" ] && [ -d "${HDC_LIBRARY_PATH}" ]; then
        printf '%s\n' "${HDC_LIBRARY_PATH}"
        return 0
    fi

    if [ -z "${hdc_path}" ] || [ ! -f "${hdc_path}" ]; then
        return 1
    fi

    hdc_dir="$(cd "$(dirname "${hdc_path}")" && pwd)"
    for candidate in \
        "${hdc_dir}" \
        "${hdc_dir}/lib" \
        "${hdc_dir}/../lib" \
        "${hdc_dir}/lib64" \
        "${hdc_dir}/../lib64" \
        "$HOME/proj/command-line-tools/sdk"/*/openharmony/toolchains \
        "$HOME/command-line-tools/sdk"/*/openharmony/toolchains
    do
        if [ -d "$candidate" ] && [ -f "$candidate/libusb_shared.so" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

hdc_help_command_works() {
    local hdc_path="${1:-}"
    local hdc_lib_dir=""

    [ -n "${hdc_path}" ] || return 1
    [ -f "${hdc_path}" ] || return 1

    if timeout 5s "${hdc_path}" -h >/dev/null 2>&1; then
        return 0
    fi

    if hdc_lib_dir="$(detect_hdc_library_path "${hdc_path}" 2>/dev/null)"; then
        timeout 5s env \
            LD_LIBRARY_PATH="${hdc_lib_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
            "${hdc_path}" -h >/dev/null 2>&1
        return $?
    fi

    return 1
}

resolve_preferred_hdc_path() {
    local configured_hdc="${HDC_PATH:-}"
    local path_hdc=""

    if [ -n "${configured_hdc}" ] && [ -f "${configured_hdc}" ] && hdc_help_command_works "${configured_hdc}"; then
        printf '%s\n' "${configured_hdc}"
        return 0
    fi

    path_hdc="$(command -v hdc 2>/dev/null || true)"
    if [ -n "${path_hdc}" ] && [ -f "${path_hdc}" ] && hdc_help_command_works "${path_hdc}"; then
        printf '%s\n' "${path_hdc}"
        return 0
    fi

    if [ -n "${configured_hdc}" ] && [ -f "${configured_hdc}" ]; then
        printf '%s\n' "${configured_hdc}"
        return 0
    fi

    if [ -n "${path_hdc}" ] && [ -f "${path_hdc}" ]; then
        printf '%s\n' "${path_hdc}"
        return 0
    fi

    return 1
}

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
    local configured_flash="${FLASH_PY_PATH:-}"
    local path_flash=""
    local home_flash="${HOME}/bin/linux/flash.py"

    if [ -n "${configured_flash}" ] && [ -f "${configured_flash}" ] && flash_py_has_neighbor_tool "${configured_flash}"; then
        printf '%s\n' "${configured_flash}"
        return 0
    fi

    path_flash="$(command -v flash.py 2>/dev/null || true)"
    if [ -n "${path_flash}" ] && [ -f "${path_flash}" ] && flash_py_has_neighbor_tool "${path_flash}"; then
        printf '%s\n' "${path_flash}"
        return 0
    fi

    if [ -f "${home_flash}" ] && flash_py_has_neighbor_tool "${home_flash}"; then
        printf '%s\n' "${home_flash}"
        return 0
    fi

    if [ -n "${configured_flash}" ] && [ -f "${configured_flash}" ]; then
        printf '%s\n' "${configured_flash}"
        return 0
    fi

    if [ -n "${path_flash}" ] && [ -f "${path_flash}" ]; then
        printf '%s\n' "${path_flash}"
        return 0
    fi

    if [ -f "${home_flash}" ]; then
        printf '%s\n' "${home_flash}"
        return 0
    fi

    return 1
}

run_xts_selector() {
    if [ ! -d "$ARKUI_XTS_SELECTOR_DIR" ]; then
        err "Missing XTS selector repo: $ARKUI_XTS_SELECTOR_DIR"
        exit 1
    fi

    local xts_extra=()
    local xts_env=()
    local xts_repo_root=""
    local explicit_hdc_path=""
    local resolved_hdc_path=""
    local hdc_lib_dir=""
    local gitcode_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/gitee_util/config.ini"

    if ! has_long_flag "--repo-root" "$@"; then
        for xts_repo_root in \
            "${OHOS_REPO_ROOT:-}" \
            "$(pwd)" \
            "$HOME/proj/ohos_master" \
            "$HOME/ohos_master"
        do
            if looks_like_ohos_repo_root "$xts_repo_root"; then
                xts_extra+=(--repo-root "$xts_repo_root")
                break
            fi
        done
    fi

    if [ -f "$gitcode_cfg" ]; then
        xts_extra+=(--git-host-config "$gitcode_cfg")
    fi
    if explicit_hdc_path="$(get_long_flag_value "--hdc-path" "$@" 2>/dev/null)"; then
        resolved_hdc_path="$explicit_hdc_path"
    else
        if resolved_hdc_path="$(resolve_preferred_hdc_path 2>/dev/null)"; then
            xts_extra+=(--hdc-path "$resolved_hdc_path")
        fi
    fi
    if [ -n "${XTS_HDC_ENDPOINT:-}" ]; then
        xts_extra+=(--hdc-endpoint "$XTS_HDC_ENDPOINT")
    fi
    xts_env+=(PYTHONPATH="${ARKUI_XTS_SELECTOR_DIR}/src")
    xts_env+=(ARKUI_XTS_SELECTOR_COMMAND_PREFIX="ohos device")
    xts_env+=(ARKUI_XTS_SELECTOR_COMMAND_MODE="wrapper")
    if hdc_lib_dir="$(detect_hdc_library_path "${resolved_hdc_path:-${HDC_PATH:-}}" 2>/dev/null)"; then
        xts_env+=(ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH="$hdc_lib_dir")
        xts_env+=(LD_LIBRARY_PATH="$hdc_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
    fi
    device_run_foreground env "${xts_env[@]}" python3 -m arkui_xts_selector "${xts_extra[@]}" "$@"
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
  bridge
  flash

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
  ohos device bridge package-windows --server-host tsnnlx12bs01 --server-user dmazur --last-report
  ohos device bridge package-windows --server-host 10.0.0.10 --server-user user --selector-report /tmp/selector_report.json --output /tmp/rk3568_bundle.zip
HELP
}

print_help_device_flash() {
    cat <<HELP
device flash - flash a daily firmware package or a local unpacked image bundle

What it runs:
  python3 -m arkui_xts_selector --flash-daily-firmware ...

Behavior:
  - prefers a runnable `flash.py` with a matching neighboring `bin/flash.<arch>`
  - prefers a runnable `hdc` and propagates its library path when needed
  - auto-detects the OHOS repo root if you run the command inside a checkout
  - accepts either daily firmware flags or a local image bundle path

Examples:
  ohos device flash --firmware-component dayu200 --firmware-build-tag 20260409_180241 --firmware-date 20260409
  ohos device flash --flash-firmware-path /tmp/image_bundle
  ohos device flash /tmp/image_bundle

Compatibility:
  - `ohos xts flash ...` is kept as a compatibility alias and routes here
HELP
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
    local flash_args=("$@")
    local selector_args=()
    local resolved_flash_py=""
    local resolved_hdc_path=""

    case "${flash_args[0]:-}" in
        help|--help|-h|"")
            print_help_device_flash
            return 0
            ;;
    esac

    if [ ${#flash_args[@]} -gt 0 ] && [[ "${flash_args[0]}" != -* ]] \
        && [ -e "${flash_args[0]}" ] && ! has_long_flag "--flash-firmware-path" "${flash_args[@]}"; then
        flash_args=(--flash-firmware-path "${flash_args[0]}" "${flash_args[@]:1}")
    fi

    if ! has_long_flag "--flash-py-path" "${flash_args[@]}"; then
        if resolved_flash_py="$(resolve_preferred_flash_py_path 2>/dev/null)"; then
            selector_args+=(--flash-py-path "$resolved_flash_py")
        fi
    fi
    if ! has_long_flag "--hdc-path" "${flash_args[@]}"; then
        if resolved_hdc_path="$(resolve_preferred_hdc_path 2>/dev/null)"; then
            selector_args+=(--hdc-path "$resolved_hdc_path")
        fi
    fi

    run_xts_selector --flash-daily-firmware "${selector_args[@]}" "${flash_args[@]}"
}

subcmd="${1:-help}"
if [ $# -gt 0 ]; then
    shift
fi

case "$subcmd" in
    help|--help|-h|"")
        print_help_device
        ;;
    bridge)
        cmd_bridge "$@"
        ;;
    flash)
        cmd_flash "$@"
        ;;
    *)
        err "device: unknown subcommand: $subcmd"
        print_help_device
        exit 1
        ;;
esac
