#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
    case "$0" in
        */ohos_download.sh|ohos_download.sh)
            exec bash "$0" "$@"
            ;;
    esac
    printf '%s\n' "ohos_download.sh requires bash. Run it with: bash $0 ..." >&2
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
OHOS_CONF="${OHOS_CONF:-${SCRIPT_DIR}/ohos.conf}"
OHOS_USER_CONF="${OHOS_USER_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/ohos/local.conf}"
OHOS_XTS_RUNTIME_LIB="${OHOS_XTS_RUNTIME_LIB:-${SCRIPT_DIR}/ohos_xts_runtime.sh}"
OHOS_XTS_ARTIFACTS_TOOL="${OHOS_XTS_ARTIFACTS_TOOL:-${SCRIPT_DIR}/ohos_xts_artifacts.py}"
ARKUI_XTS_SELECTOR_DIR="${ARKUI_XTS_SELECTOR_DIR:-${SCRIPT_DIR}/arkui-xts-selector}"
OHOS_DOWNLOAD_ACTIVE_CHILD_PID=""
OHOS_DOWNLOAD_SIGNAL_MESSAGE_EMITTED=0

if [ -f "$OHOS_CONF" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_CONF"
fi

OHOS_SHARED_ENV="${SCRIPT_DIR}/ohos-shared-env.sh"
if [ -f "$OHOS_SHARED_ENV" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_SHARED_ENV"
fi

if [ -f "$OHOS_USER_CONF" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_USER_CONF"
fi

if [ -z "${OHOS_SHARED_DOWNLOAD_ROOT:-}" ]; then
    if [ -d "/data/shared/common" ]; then
        OHOS_SHARED_DOWNLOAD_ROOT="/data/shared/common"
    elif [ -d "/data/shared" ]; then
        OHOS_SHARED_DOWNLOAD_ROOT="/data/shared/ohos-downloads/${USER:-$(id -un 2>/dev/null || echo user)}"
    else
        OHOS_SHARED_DOWNLOAD_ROOT="$HOME/.cache/ohos-downloads"
    fi
fi
if [ -z "${XTS_DOWNLOAD_ROOT:-}" ]; then
    if [ "$OHOS_SHARED_DOWNLOAD_ROOT" = "/data/shared/common" ]; then
        XTS_DOWNLOAD_ROOT="/data/shared/common/xts_tests"
    else
        XTS_DOWNLOAD_ROOT="$OHOS_SHARED_DOWNLOAD_ROOT/tests"
    fi
fi
if [ -z "${SDK_DOWNLOAD_ROOT:-}" ]; then
    if [ "$OHOS_SHARED_DOWNLOAD_ROOT" = "/data/shared/common" ]; then
        SDK_DOWNLOAD_ROOT="/data/shared/common/sdk"
    else
        SDK_DOWNLOAD_ROOT="$OHOS_SHARED_DOWNLOAD_ROOT/sdk"
    fi
fi
if [ -z "${FIRMWARE_DOWNLOAD_ROOT:-}" ]; then
    if [ "$OHOS_SHARED_DOWNLOAD_ROOT" = "/data/shared/common" ]; then
        FIRMWARE_DOWNLOAD_ROOT="/data/shared/common/firmwares"
    else
        FIRMWARE_DOWNLOAD_ROOT="$OHOS_SHARED_DOWNLOAD_ROOT/firmware"
    fi
fi

if [ -f "$OHOS_XTS_RUNTIME_LIB" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_XTS_RUNTIME_LIB"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[ohos-download]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ohos-download]${NC} $*"; }
err()   { echo -e "${RED}[ohos-download]${NC} $*" >&2; }

require_tool_repo() {
    local tool_name="$1"
    local tool_path="$2"
    if [ -d "$tool_path" ]; then
        return 0
    fi
    err "Missing required tool repo '$tool_name' at: $tool_path"
    exit 1
}

download_wait_active_child() {
    local rc=0

    if [ -z "${OHOS_DOWNLOAD_ACTIVE_CHILD_PID:-}" ]; then
        return 0
    fi

    if wait "$OHOS_DOWNLOAD_ACTIVE_CHILD_PID"; then
        rc=0
    else
        rc=$?
    fi
    OHOS_DOWNLOAD_ACTIVE_CHILD_PID=""
    return "$rc"
}

download_run_foreground() {
    "$@" &
    OHOS_DOWNLOAD_ACTIVE_CHILD_PID=$!
    download_wait_active_child
}

download_forward_signal() {
    local signal_name="$1"
    local pid="${OHOS_DOWNLOAD_ACTIVE_CHILD_PID:-}"
    local _attempt=0

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -s "$signal_name" "$pid" 2>/dev/null || true
        for _attempt in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                OHOS_DOWNLOAD_ACTIVE_CHILD_PID=""
                return 0
            fi
            sleep 0.1
        done
        kill -TERM "$pid" 2>/dev/null || true
        for _attempt in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                OHOS_DOWNLOAD_ACTIVE_CHILD_PID=""
                return 0
            fi
            sleep 0.1
        done
        kill -KILL "$pid" 2>/dev/null || true
        OHOS_DOWNLOAD_ACTIVE_CHILD_PID=""
    fi
}

download_handle_signal() {
    local signal_name="$1"
    local exit_code="$2"
    local message="$3"

    if [ "${OHOS_DOWNLOAD_SIGNAL_MESSAGE_EMITTED:-0}" -eq 0 ]; then
        err "$message"
        OHOS_DOWNLOAD_SIGNAL_MESSAGE_EMITTED=1
    fi
    download_forward_signal "$signal_name"
    exit "$exit_code"
}

trap 'download_handle_signal INT 130 "Script stopped by Ctrl+C."' INT
trap 'download_handle_signal TERM 143 "Script stopped by SIGTERM."' TERM

run_xts_artifacts_tool() {
    require_tool_repo "arkui-xts-selector" "$ARKUI_XTS_SELECTOR_DIR"
    if [ ! -f "$OHOS_XTS_ARTIFACTS_TOOL" ]; then
        err "Missing XTS artifacts tool: $OHOS_XTS_ARTIFACTS_TOOL"
        exit 1
    fi
    local extra_args=()

    if [ -n "${SDK_DOWNLOAD_ROOT:-}" ]; then
        extra_args+=(--sdk-cache-root "$SDK_DOWNLOAD_ROOT")
    fi
    if [ -n "${FIRMWARE_DOWNLOAD_ROOT:-}" ]; then
        extra_args+=(--firmware-cache-root "$FIRMWARE_DOWNLOAD_ROOT")
    fi
    if [ -n "${XTS_DOWNLOAD_ROOT:-}" ]; then
        extra_args+=(--daily-cache-root "$XTS_DOWNLOAD_ROOT")
    fi

    download_run_foreground env \
        PYTHONPATH="${ARKUI_XTS_SELECTOR_DIR}/src" \
        ARKUI_XTS_SELECTOR_DIR="${ARKUI_XTS_SELECTOR_DIR}" \
        python3 "$OHOS_XTS_ARTIFACTS_TOOL" "$@" "${extra_args[@]}"
}

download_tag_flag_for_subcmd() {
    case "$1" in
        tests) printf '%s\n' "--daily-build-tag" ;;
        sdk) printf '%s\n' "--sdk-build-tag" ;;
        firmware) printf '%s\n' "--firmware-build-tag" ;;
        *) return 1 ;;
    esac
}

download_tag_label_for_subcmd() {
    case "$1" in
        tests) printf '%s\n' "daily test suite" ;;
        sdk) printf '%s\n' "SDK" ;;
        firmware) printf '%s\n' "firmware" ;;
        *) return 1 ;;
    esac
}

download_has_tag_arg() {
    local tag_flag="$1"
    shift
    local arg=""
    for arg in "$@"; do
        if [ "$arg" = "$tag_flag" ] || [[ "$arg" == "$tag_flag="* ]]; then
            return 0
        fi
    done
    return 1
}

print_download_tag_hint() {
    local subcmd="$1"
    local label=""
    label="$(download_tag_label_for_subcmd "$subcmd")" || return 0
    echo ""
    info "Choose one of the tags above, then download ${label} with either form:"
    echo "  ohos download ${subcmd} <tag>"
    echo "  ohos download ${subcmd} $(download_tag_flag_for_subcmd "$subcmd") <tag>"
    echo ""
    info "To inspect more tags or narrow the list:"
    echo "  ohos download list-tags ${subcmd} --list-tags-count 20"
    echo "  ohos download list-tags ${subcmd} --list-tags-after 20260401 --list-tags-before 20260430"
}

DOWNLOAD_MENU_RESULT=""
DOWNLOAD_MENU_FILTERED_ARGS=()
DOWNLOAD_MENU_TAGS=()

download_menu_enabled() {
    if [ "${OHOS_DOWNLOAD_MENU_FORCE:-0}" = "1" ]; then
        return 0
    fi
    [ -t 0 ] && [ -t 1 ]
}

download_menu_select() {
    local title="$1"
    local -n options_ref="$2"
    local selected=0
    local key=""
    local second=""
    local third=""
    local index=0

    DOWNLOAD_MENU_RESULT=""
    [ "${#options_ref[@]}" -gt 0 ] || return 1

    while true; do
        printf '\033[2J\033[H'
        printf '%s\n\n' "$title"
        for index in "${!options_ref[@]}"; do
            if [ "$index" -eq "$selected" ]; then
                printf '  > %s\n' "${options_ref[$index]}"
            else
                printf '    %s\n' "${options_ref[$index]}"
            fi
        done
        printf '\nUse ↑/↓ to move, Enter to select, Esc to cancel.\n'

        IFS= read -rsn1 key || return 1
        case "$key" in
            ""|$'\n'|$'\r')
                DOWNLOAD_MENU_RESULT="${options_ref[$selected]}"
                printf '\033[2J\033[H'
                return 0
                ;;
            $'\x1b')
                if IFS= read -rsn1 -t 0.05 second; then
                    if [ "$second" = "[" ] && IFS= read -rsn1 -t 0.05 third; then
                        case "$third" in
                            A)
                                if [ "$selected" -le 0 ]; then
                                    selected=$((${#options_ref[@]} - 1))
                                else
                                    selected=$((selected - 1))
                                fi
                                ;;
                            B)
                                selected=$((selected + 1))
                                if [ "$selected" -ge "${#options_ref[@]}" ]; then
                                    selected=0
                                fi
                                ;;
                            *)
                                ;;
                        esac
                    else
                        printf '\033[2J\033[H'
                        return 130
                    fi
                else
                    printf '\033[2J\033[H'
                    return 130
                fi
                ;;
            *)
                ;;
        esac
    done
}

download_strip_list_args() {
    DOWNLOAD_MENU_FILTERED_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --list-tags-count|--list-tags-after|--list-tags-before|--list-tags-lookback)
                shift
                [ $# -gt 0 ] && shift
                ;;
            --list-tags-count=*|--list-tags-after=*|--list-tags-before=*|--list-tags-lookback=*)
                shift
                ;;
            *)
                DOWNLOAD_MENU_FILTERED_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

download_collect_recent_tags() {
    local subcmd="$1"
    shift
    local output=""
    local trimmed=""
    local candidate=""
    local line=""
    local label=""
    case "$subcmd" in
        tests) label="XTS tests" ;;
        sdk)   label="SDK" ;;
        firmware) label="firmware" ;;
        *)    label="$subcmd" ;;
    esac

    DOWNLOAD_MENU_TAGS=()
    info "Fetching recent ${label} build tags..."
    if ! output="$(run_xts_artifacts_tool list-tags "$subcmd" "$@" 2>&1)"; then
        printf '%s\n' "$output" >&2
        return 1
    fi

    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        candidate="${trimmed%%[[:space:]]*}"
        if [[ "$candidate" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
            DOWNLOAD_MENU_TAGS+=("$candidate")
        fi
    done <<< "$output"

    if [ "${#DOWNLOAD_MENU_TAGS[@]}" -eq 0 ]; then
        printf '%s\n' "$output"
        return 1
    fi
    return 0
}

download_choose_artifact_type() {
    local options=("tests" "sdk" "firmware")
    download_menu_select "Select artifact type to download" options
}

download_choose_tag() {
    local subcmd="$1"
    shift
    local label=""
    label="$(download_tag_label_for_subcmd "$subcmd")" || label="$subcmd"
    if ! download_collect_recent_tags "$subcmd" "$@"; then
        return 1
    fi
    download_menu_select "Select ${label} tag to download" DOWNLOAD_MENU_TAGS
}

print_help_download() {
    cat <<HELP
download - download daily prebuilt SDK, firmware or XTS test packages

Subcommands:
  tests [tag]    Download daily XTS test suite (full package → extracts ACTS)
  sdk   [tag]    Download daily SDK package
  firmware [tag] Download daily firmware image package
  list-tags [tests|sdk|firmware]
                 List the most recent available build tags (default: tests)

Download roots (configured in ${OHOS_CONF} and ${OHOS_USER_CONF}):
  Shared   → $OHOS_SHARED_DOWNLOAD_ROOT
  SDK      → $SDK_DOWNLOAD_ROOT
  Firmware → $FIRMWARE_DOWNLOAD_ROOT
  XTS      → $XTS_DOWNLOAD_ROOT

Behavior:
  - In an interactive terminal, plain 'ohos download' opens an arrow-key menu for tests / sdk / firmware.
  - In an interactive terminal, 'ohos download tests|sdk|firmware' without a tag opens an arrow-key menu with recent tags.
  - Press Enter to start the selected download, or Esc to cancel the menu.
  - 'ohos download tests' / 'ohos download sdk' / 'ohos download firmware' without a tag lists recent tags and prints the next command to run.
  - A plain positional tag is accepted, e.g. 'ohos download firmware 20260404_120244'.
  - Interrupted downloads are resumed automatically (HTTP Range).
  - Archive filenames include the build tag for easy identification.
  - If a cached archive or extracted package is already present, the tool prints that it was found and skips re-downloading.
  - Already-downloaded archives are not re-fetched unless the .part file exists.
  - Set OHOS_DOWNLOAD_MENU_FORCE=1 to force the menu in tests or other non-TTY environments.

Options for tests/sdk/firmware:
  --daily-build-tag TAG     (or --sdk-build-tag / --firmware-build-tag)
  --daily-branch BRANCH     default: master
  --json                    print machine-readable JSON to stdout

Options for list-tags:
  --list-tags-count N       how many tags to show (default: 10)
  --list-tags-after DATE    only show tags on/after DATE (YYYYMMDD)
  --list-tags-before DATE   only show tags on/before DATE (YYYYMMDD)
  --list-tags-lookback N    days back to search (default: 30)

Examples:
  ohos download list-tags
  ohos download list-tags sdk
  ohos download list-tags firmware --list-tags-count 20
  ohos download list-tags tests --list-tags-after 20260401
  ohos download tests 20260404_120510
  ohos download sdk 20260404_120537
  ohos download firmware 20260404_120244
  ohos download firmware --firmware-build-tag 20260404_120244
HELP
}

cmd_download() {
    local subcmd="${1:-}"
    local tests_tag_flag="--daily-build-tag"
    local sdk_tag_flag="--sdk-build-tag"
    local firmware_tag_flag="--firmware-build-tag"
    if [ $# -gt 0 ]; then
        shift
    fi

    if [ -z "$subcmd" ]; then
        if ! download_menu_enabled; then
            print_help_download
            return 0
        fi
        if download_choose_artifact_type; then
            subcmd="$DOWNLOAD_MENU_RESULT"
        else
            local menu_rc=$?
            if [ "$menu_rc" -eq 130 ]; then
                info "Download cancelled."
                return 0
            fi
            return "$menu_rc"
        fi
    fi

    case "$subcmd" in
        help|--help|-h|"")
            print_help_download
            ;;
        tests)
            local tests_args=("$@")
            if [ ${#tests_args[@]} -gt 0 ] && [[ "${tests_args[0]}" != -* ]] && ! download_has_tag_arg "$tests_tag_flag" "${tests_args[@]}"; then
                tests_args=("$tests_tag_flag" "${tests_args[0]}" "${tests_args[@]:1}")
            fi
            if ! download_has_tag_arg "$tests_tag_flag" "${tests_args[@]}"; then
                if download_menu_enabled; then
                    if download_choose_tag tests "${tests_args[@]}"; then
                        download_strip_list_args "${tests_args[@]}"
                        tests_args=("$tests_tag_flag" "$DOWNLOAD_MENU_RESULT" "${DOWNLOAD_MENU_FILTERED_ARGS[@]}")
                    else
                        local menu_rc=$?
                        if [ "$menu_rc" -eq 130 ]; then
                            info "Download cancelled."
                            return 0
                        fi
                        return "$menu_rc"
                    fi
                else
                    run_xts_artifacts_tool list-tags tests "${tests_args[@]}"
                    print_download_tag_hint tests
                    return 0
                fi
            fi
            run_xts_artifacts_tool download tests "${tests_args[@]}"
            ;;
        sdk)
            local sdk_args=("$@")
            if [ ${#sdk_args[@]} -gt 0 ] && [[ "${sdk_args[0]}" != -* ]] && ! download_has_tag_arg "$sdk_tag_flag" "${sdk_args[@]}"; then
                sdk_args=("$sdk_tag_flag" "${sdk_args[0]}" "${sdk_args[@]:1}")
            fi
            if ! download_has_tag_arg "$sdk_tag_flag" "${sdk_args[@]}"; then
                if download_menu_enabled; then
                    if download_choose_tag sdk "${sdk_args[@]}"; then
                        download_strip_list_args "${sdk_args[@]}"
                        sdk_args=("$sdk_tag_flag" "$DOWNLOAD_MENU_RESULT" "${DOWNLOAD_MENU_FILTERED_ARGS[@]}")
                    else
                        local menu_rc=$?
                        if [ "$menu_rc" -eq 130 ]; then
                            info "Download cancelled."
                            return 0
                        fi
                        return "$menu_rc"
                    fi
                else
                    run_xts_artifacts_tool list-tags sdk "${sdk_args[@]}"
                    print_download_tag_hint sdk
                    return 0
                fi
            fi
            run_xts_artifacts_tool download sdk "${sdk_args[@]}"
            ;;
        firmware)
            local firmware_args=("$@")
            if [ ${#firmware_args[@]} -gt 0 ] && [[ "${firmware_args[0]}" != -* ]] && ! download_has_tag_arg "$firmware_tag_flag" "${firmware_args[@]}"; then
                firmware_args=("$firmware_tag_flag" "${firmware_args[0]}" "${firmware_args[@]:1}")
            fi
            if ! download_has_tag_arg "$firmware_tag_flag" "${firmware_args[@]}"; then
                if download_menu_enabled; then
                    if download_choose_tag firmware "${firmware_args[@]}"; then
                        download_strip_list_args "${firmware_args[@]}"
                        firmware_args=("$firmware_tag_flag" "$DOWNLOAD_MENU_RESULT" "${DOWNLOAD_MENU_FILTERED_ARGS[@]}")
                    else
                        local menu_rc=$?
                        if [ "$menu_rc" -eq 130 ]; then
                            info "Download cancelled."
                            return 0
                        fi
                        return "$menu_rc"
                    fi
                else
                    run_xts_artifacts_tool list-tags firmware "${firmware_args[@]}"
                    print_download_tag_hint firmware
                    return 0
                fi
            fi
            run_xts_artifacts_tool download firmware "${firmware_args[@]}"
            ;;
        list-tags)
            local list_type="${1:-tests}"
            if [ $# -gt 0 ]; then
                shift
            fi
            run_xts_artifacts_tool list-tags "$list_type" "$@"
            ;;
        *)
            err "download: unknown subcommand: $subcmd"
            print_help_download
            exit 1
            ;;
    esac
}

cmd_download "$@"
