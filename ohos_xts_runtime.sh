#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

has_long_flag() {
    local wanted="$1"
    shift || true
    local item=""
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
    if [ -n "${ARKUI_XTS_SELECTOR_DIR:-}" ]; then
        printf '%s\n' "${ARKUI_XTS_SELECTOR_DIR}/.runs"
        return 0
    fi
    if [ -n "${SCRIPT_DIR:-}" ]; then
        printf '%s\n' "${SCRIPT_DIR}/arkui-xts-selector/.runs"
        return 0
    fi
    return 1
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
