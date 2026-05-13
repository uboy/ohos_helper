#!/bin/bash
# Allow accidental `sh ./ohos.sh` launches by restarting under bash early,
# before the shell reaches bash-specific syntax later in the file.
if [ -z "${BASH_VERSION:-}" ]; then
    case "$0" in
        */ohos.sh|ohos.sh)
            exec bash "$0" "$@"
            ;;
    esac
    printf '%s\n' "ohos.sh requires bash. Run it with: bash $0 ..." >&2
    return 1 2>/dev/null || exit 1
fi

# =============================================================================
# ohos.sh - unified OpenHarmony repo management tool
# =============================================================================
set -Eeuo pipefail

CURRENT_CHAIN_STEP="${CURRENT_CHAIN_STEP:-}"
CHAIN_ABORT_ANNOUNCED="${CHAIN_ABORT_ANNOUNCED:-false}"

handle_script_error() {
    local rc="${1:-1}"
    if [ -n "${CURRENT_CHAIN_STEP:-}" ] && [ "${CHAIN_ABORT_ANNOUNCED:-false}" != "true" ]; then
        CHAIN_ABORT_ANNOUNCED=true
        err "Aborting command chain after failed step: ${CURRENT_CHAIN_STEP}"
    fi
    exit "$rc"
}

trap 'handle_script_error "$?"' ERR

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

resolve_absolute_path() {
    local input_path="$1"
    python3 - "$input_path" <<'PY'
import sys
from pathlib import Path

value = Path(sys.argv[1]).expanduser()
if value.is_absolute():
    print(str(value))
else:
    print(str((Path.cwd() / value).resolve(strict=False)))
PY
}

OHOS_LAUNCH_PATH="$(resolve_launch_script_path "$0")"
OHOS_LAUNCH_DIR="$(cd -L "$(dirname "$OHOS_LAUNCH_PATH")" && pwd)"
OHOS_REAL_PATH="$(resolve_real_script_path "$OHOS_LAUNCH_PATH")"
OHOS_REAL_DIR="$(cd -P "$(dirname "$OHOS_REAL_PATH")" && pwd)"
SCRIPT_DIR="$OHOS_REAL_DIR"
OHOS_HELPER="${OHOS_HELPER:-${SCRIPT_DIR}/ohos-helper.py}"
OHOS_CONF="${OHOS_CONF:-${SCRIPT_DIR}/ohos.conf}"
OHOS_USER_CONF="${OHOS_USER_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/ohos/local.conf}"
OHOS_XTS_RUNTIME_LIB="${OHOS_XTS_RUNTIME_LIB:-${SCRIPT_DIR}/ohos_xts_runtime.sh}"
CURL_WRAPPER="${SCRIPT_DIR}/ohos-curl-fallback"
GITEE_UTIL_RUNNER="${GITEE_UTIL_RUNNER:-${SCRIPT_DIR}/gitee-util-runner.py}"
GITEE_UTIL_DIR="${GITEE_UTIL_DIR:-${SCRIPT_DIR}/gitee_util}"
ARKUI_XTS_SELECTOR_DIR="${ARKUI_XTS_SELECTOR_DIR:-${SCRIPT_DIR}/arkui-xts-selector}"
OHOS_XTS_BRIDGE_TOOL="${OHOS_XTS_BRIDGE_TOOL:-${SCRIPT_DIR}/ohos_xts_bridge.py}"
OHOS_DEVICE_TOOL="${OHOS_DEVICE_TOOL:-${SCRIPT_DIR}/ohos_device.sh}"
OHOS_DOWNLOAD_TOOL="${OHOS_DOWNLOAD_TOOL:-${SCRIPT_DIR}/ohos_download.sh}"
OHOS_ACE_UNITTEST_RUNNER="${OHOS_ACE_UNITTEST_RUNNER:-foundation/arkui/ace_engine/test/unittest/scripts/run.py}"
OHOS_DEVELOPER_TEST_DIR="${OHOS_DEVELOPER_TEST_DIR:-test/testfwk/developer_test}"
OHOS_DEVELOPER_TEST_RUNNER="${OHOS_DEVELOPER_TEST_RUNNER:-}"
OHOS_DEVELOPER_TEST_PRODUCTFORM="${OHOS_DEVELOPER_TEST_PRODUCTFORM:-phone}"
OHOS_TDD_RUNNER_TOOL="${OHOS_TDD_RUNNER_TOOL:-${SCRIPT_DIR}/ohos_tdd_runner.py}"
OHOS_PR_COMMENTS_VIEWER="${OHOS_PR_COMMENTS_VIEWER:-${SCRIPT_DIR}/ohos_pr_comments_view.py}"
OHOS_FEEDBACK_DIR="${OHOS_FEEDBACK_DIR:-${SCRIPT_DIR}/feedback}"

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

if [ -f "$OHOS_XTS_RUNTIME_LIB" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_XTS_RUNTIME_LIB"
fi

NPM_REGISTRY="${NPM_REGISTRY:-http://tsnnlx12bs02.ad.telmast.com:8081/repository/huaweicloud}"
OHOS_NPM_REGISTRY="${OHOS_NPM_REGISTRY:-http://tsnnlx12bs02.ad.telmast.com:8081/harmonyos/}"
OHPM_REGISTRY="${OHPM_REGISTRY:-http://tsnnlx12bs02.ad.telmast.com:8081/repository/ohpm/}"
PYPI_URL="${PYPI_URL:-http://tsnnlx12bs02.ad.telmast.com:8081/repository/pypi/simple/}"
TRUSTED_HOST="${TRUSTED_HOST:-tsnnlx12bs02.ad.telmast.com}"
KOALA_NPM_REGISTRY="${KOALA_NPM_REGISTRY:-http://tsnnlx12bs02.ad.telmast.com:8081/repository/koala-npm/}"
ORIGINAL_NPM_REGISTRY="${ORIGINAL_NPM_REGISTRY:-https://repo.huaweicloud.com/repository/npm/}"
ORIGINAL_OHOS_NPM_REGISTRY="${ORIGINAL_OHOS_NPM_REGISTRY:-https://repo.harmonyos.com/npm/}"
ORIGINAL_OHPM_REGISTRY="${ORIGINAL_OHPM_REGISTRY:-https://repo.harmonyos.com/ohpm/}"
OHPM_PUBLISH_REGISTRY="${OHPM_PUBLISH_REGISTRY:-https://ohpm.openharmony.cn/ohpm/}"
ORIGINAL_KOALA_NPM_REGISTRY="${ORIGINAL_KOALA_NPM_REGISTRY:-${KOALA_NPM_REGISTRY}}"
OHOS_SYNC_NPMRC_PROFILE="${OHOS_SYNC_NPMRC_PROFILE:-mirror}"

REPO_MANIFEST_URL="${REPO_MANIFEST_URL:-https://gitcode.com/openharmony/manifest.git}"
REPO_REFERENCE="${REPO_REFERENCE:-/data/shared/ohos_mirror}"
LFS_MIRROR="${LFS_MIRROR:-/data/shared/ohos_mirror}"

OHOS_PROXY="${OHOS_PROXY:-}"
OHOS_PROXY_CONNECT_TIMEOUT="${OHOS_PROXY_CONNECT_TIMEOUT:-15}"
OHOS_NO_PROXY="${OHOS_NO_PROXY:-tsnnlx12bs02.ad.telmast.com,localhost,127.0.0.1}"

REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-8}"
LFS_JOBS="${LFS_JOBS:-64}"
RESET_JOBS="${RESET_JOBS:-64}"
SYNC_FORCE_MAX_RETRIES="${SYNC_FORCE_MAX_RETRIES:-5}"

RESET_LFS_PRUNE="${RESET_LFS_PRUNE:-false}"
RESET_GC="${RESET_GC:-false}"
RESET_RM_DIRS="${RESET_RM_DIRS:-out prebuilts}"

GC_LFS_PRUNE="${GC_LFS_PRUNE:-true}"
GC_GIT_GC="${GC_GIT_GC:-true}"
GC_JOBS="${GC_JOBS:-32}"

INIT_BRANCH="${INIT_BRANCH:-master}"
INIT_EXTRA_ARGS="${INIT_EXTRA_ARGS:---no-repo-verify}"

BUILD_SDK="${BUILD_SDK:---product-name ohos-sdk --ccache}"
BUILD_SDK_LINUX="${BUILD_SDK_LINUX:---product-name ohos-sdk --gn-args sdk_platform=linux --ccache}"
BUILD_SDK_WIN="${BUILD_SDK_WIN:---product-name ohos-sdk --gn-args sdk_platform=win --ccache}"
BUILD_RK3568="${BUILD_RK3568:---product-name rk3568 --ccache}"
CCACHE_DIR="${CCACHE_DIR:-/data/shared/CCACHE/.ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-200G}"

REPO_INSTALL_URL="${REPO_INSTALL_URL:-https://gitee.com/oschina/repo/raw/fork_flow/repo-py3}"
NVM_INSTALL_URL="${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh}"
SHARED_PREBUILTS_DIR="${SHARED_PREBUILTS_DIR:-/data/shared/openharmony_prebuilts}"
PREBUILTS_SYMLINK_NAME="${PREBUILTS_SYMLINK_NAME:-openharmony_prebuilts}"

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
export OHOS_CONF OHOS_USER_CONF
export OHOS_SHARED_DOWNLOAD_ROOT XTS_DOWNLOAD_ROOT SDK_DOWNLOAD_ROOT FIRMWARE_DOWNLOAD_ROOT
XTS_HDC_ENDPOINT="${XTS_HDC_ENDPOINT:-}"
XTS_WINDOWS_BRIDGE_OUTPUT_ROOT="${XTS_WINDOWS_BRIDGE_OUTPUT_ROOT:-$HOME/ohos-xts-bridge}"
OHOS_REPO_ROOT="${OHOS_REPO_ROOT:-}"
HDC_LIBRARY_PATH="${HDC_LIBRARY_PATH:-}"
OHOS_DEVICE_SERVER_HOST="${OHOS_DEVICE_SERVER_HOST:-}"
OHOS_DEVICE_SERVER_USER="${OHOS_DEVICE_SERVER_USER:-}"
OHOS_XTS_REMOTE_EXEC="${OHOS_XTS_REMOTE_EXEC:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SYNC_FORCE_ENABLED=false
SYNC_RAW_OUTPUT=false
LAST_STEP_LOG=""
OHOS_ACTIVE_CHILD_PID=""
OHOS_ACTIVE_CHILD_PGID=""
OHOS_SIGNAL_MESSAGE_EMITTED=0
OHOS_EXIT_CLEANUP_RAN=0

info()  { echo -e "${GREEN}[ohos]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ohos]${NC} $*"; }
err()   { echo -e "${RED}[ohos]${NC} $*" >&2; }

has_command() {
    command -v "$1" >/dev/null 2>&1
}

ohos_cleanup_once() {
    if [ "${OHOS_EXIT_CLEANUP_RAN:-0}" -eq 1 ]; then
        return 0
    fi
    OHOS_EXIT_CLEANUP_RAN=1
    if declare -F restore_npmrc >/dev/null 2>&1; then
        restore_npmrc || true
    fi
    if declare -F cleanup_proxy_fallback >/dev/null 2>&1; then
        cleanup_proxy_fallback || true
    fi
}

ohos_wait_active_child() {
    local rc=0

    if [ -z "${OHOS_ACTIVE_CHILD_PID:-}" ]; then
        return 0
    fi

    if wait "$OHOS_ACTIVE_CHILD_PID"; then
        rc=0
    else
        rc=$?
    fi
    OHOS_ACTIVE_CHILD_PID=""
    OHOS_ACTIVE_CHILD_PGID=""
    return "$rc"
}

ohos_run_foreground() {
    local detected_pgid=""
    if has_command setsid; then
        setsid "$@" &
    else
        "$@" &
    fi
    OHOS_ACTIVE_CHILD_PID=$!
    detected_pgid="$(ps -o pgid= -p "${OHOS_ACTIVE_CHILD_PID}" 2>/dev/null || true)"
    OHOS_ACTIVE_CHILD_PGID="$(printf '%s' "$detected_pgid" | tr -d '[:space:]')"
    if [ -z "${OHOS_ACTIVE_CHILD_PGID:-}" ]; then
        OHOS_ACTIVE_CHILD_PGID="${OHOS_ACTIVE_CHILD_PID}"
    fi
    ohos_wait_active_child
}

ohos_forward_signal() {
    local signal_name="$1"
    local pid="${OHOS_ACTIVE_CHILD_PID:-}"
    local pgid="${OHOS_ACTIVE_CHILD_PGID:-}"
    local _attempt=0

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        if [ -n "$pgid" ] && [[ "$pgid" =~ ^[0-9]+$ ]]; then
            kill -s "$signal_name" "-$pgid" 2>/dev/null || kill -s "$signal_name" "$pid" 2>/dev/null || true
        else
            kill -s "$signal_name" "$pid" 2>/dev/null || true
        fi
        for _attempt in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                OHOS_ACTIVE_CHILD_PID=""
                OHOS_ACTIVE_CHILD_PGID=""
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
                OHOS_ACTIVE_CHILD_PID=""
                OHOS_ACTIVE_CHILD_PGID=""
                return 0
            fi
            sleep 0.1
        done
        if [ -n "$pgid" ] && [[ "$pgid" =~ ^[0-9]+$ ]]; then
            kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        else
            kill -KILL "$pid" 2>/dev/null || true
        fi
        OHOS_ACTIVE_CHILD_PID=""
        OHOS_ACTIVE_CHILD_PGID=""
    fi
}

ohos_handle_signal() {
    local signal_name="$1"
    local exit_code="$2"
    local message="$3"

    if [ "${OHOS_SIGNAL_MESSAGE_EMITTED:-0}" -eq 0 ]; then
        err "$message"
        OHOS_SIGNAL_MESSAGE_EMITTED=1
    fi
    ohos_cleanup_once
    ohos_forward_signal "$signal_name"
    exit "$exit_code"
}

trap 'ohos_cleanup_once' EXIT
trap 'ohos_handle_signal INT 130 "Script stopped by Ctrl+C."' INT
trap 'ohos_handle_signal TERM 143 "Script stopped by SIGTERM."' TERM
trap 'ohos_handle_signal HUP 129 "Script stopped by SIGHUP."' HUP

confirm_default_yes() {
    local prompt="$1"
    local answer
    read -r -p "$prompt" answer
    case "$answer" in
        [nN][oO]|[nN]) return 1 ;;
        *) return 0 ;;
    esac
}

confirm_default_no() {
    local prompt="$1"
    local answer
    read -r -p "$prompt" answer
    case "$answer" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

run_step() {
    local label="$1"
    local rc
    local start_ts
    local end_ts
    local elapsed
    shift

    LAST_STEP_LOG=""
    start_ts="$(date +%s)"
    info "======== ${label} ========"
    if "$@"; then
        end_ts="$(date +%s)"
        elapsed=$((end_ts - start_ts))
        info "Stage completed: ${label} (elapsed=$(format_duration_compact "$elapsed"))"
        return 0
    else
        rc=$?
    fi

    err "Stage failed: ${label}"
    if [ -n "$LAST_STEP_LOG" ]; then
        err "Stage log: $LAST_STEP_LOG"
    fi
    return "$rc"
}

run_chain_command() {
    local step_name="$1"
    shift
    CURRENT_CHAIN_STEP="$step_name"
    CHAIN_ABORT_ANNOUNCED=false
    "$@"
    CURRENT_CHAIN_STEP=""
    CHAIN_ABORT_ANNOUNCED=false
}

is_repo_initialized() {
    [[ -d ".repo" ]]
}

is_ohos_repo() {
    [[ -d ".repo" ]] && [[ -f "build/prebuilts_download.sh" ]]
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

require_repo_initialized() {
    if ! is_repo_initialized; then
        err "Current directory has not been initialized."
        err "Expected .repo/ in $(pwd)"
        err "Run 'ohos init' first, or cd into an existing OH repo."
        exit 1
    fi
}

require_ohos_repo() {
    if ! is_ohos_repo; then
        err "Current directory is not an OpenHarmony repository."
        err "Expected .repo/ and build/prebuilts_download.sh in $(pwd)"
        err "Run 'ohos init' first, or cd into an existing OH repo."
        exit 1
    fi
}

require_tool_repo() {
    local label="$1"
    local path="$2"
    if [ ! -d "$path" ] || [ ! -e "$path/.git" ]; then
        err "${label} repository is not available at: $path"
        err "Expected a vendored Git checkout or submodule in this scripts workspace."
        err "Run 'git submodule update --init --recursive' from $SCRIPT_DIR."
        exit 1
    fi
}

python_has_modules() {
    local python_bin="$1"
    shift
    "$python_bin" - "$@" <<'PY'
import importlib.util
import sys

missing = [name for name in sys.argv[1:] if importlib.util.find_spec(name) is None]
sys.exit(0 if not missing else 1)
PY
}

install_gitee_util_user_deps() {
    python3 -m pip install --user \
        requests \
        tqdm \
        prompt_toolkit \
        beautifulsoup4 \
        python-dateutil
}

ensure_gitee_util_runtime() {
    if python_has_modules python3 requests tqdm prompt_toolkit bs4 dateutil; then
        GITEE_UTIL_PYTHON="python3"
        return 0
    fi

    warn "gitee_util Python dependencies are missing for this shell."
    warn "Expected modules: requests, tqdm, prompt_toolkit, bs4, dateutil"
    warn "Recommended install:"
    warn "  python3 -m pip install --user requests tqdm prompt_toolkit beautifulsoup4 python-dateutil"
    if confirm_default_yes "Install missing gitee_util Python deps into ~/.local now? [Y/n] "; then
        run_step "[preflight] install gitee_util Python dependencies" install_gitee_util_user_deps
        if python_has_modules python3 requests tqdm prompt_toolkit bs4 dateutil; then
            GITEE_UTIL_PYTHON="python3"
            return 0
        fi
        err "gitee_util dependencies are still unavailable after pip install."
        exit 1
    fi

    err "gitee_util dependencies are required for PR commands."
    exit 1
}

NPMRC="$HOME/.npmrc"
NPMRC_BAK=""
NPMRC_PROTECTED=0

normalize_npmrc_profile() {
    case "${1:-mirror}" in
        mirror|"")
            printf '%s\n' "mirror"
            ;;
        original|default|public)
            printf '%s\n' "original"
            ;;
        *)
            return 1
            ;;
    esac
}

sync_npmrc_profile() {
    local profile=""
    if ! profile="$(normalize_npmrc_profile "${OHOS_SYNC_NPMRC_PROFILE:-mirror}" 2>/dev/null)"; then
        err "Invalid OHOS_SYNC_NPMRC_PROFILE: ${OHOS_SYNC_NPMRC_PROFILE:-}"
        err "Supported values: mirror, original"
        return 1
    fi
    printf '%s\n' "$profile"
}

registry_for_npmrc_profile() {
    local profile="$1"
    local kind="$2"
    case "$profile:$kind" in
        mirror:npm) printf '%s\n' "$NPM_REGISTRY" ;;
        mirror:ohos) printf '%s\n' "$OHOS_NPM_REGISTRY" ;;
        mirror:ohpm) printf '%s\n' "$OHPM_REGISTRY" ;;
        mirror:koala) printf '%s\n' "$KOALA_NPM_REGISTRY" ;;
        original:npm) printf '%s\n' "$ORIGINAL_NPM_REGISTRY" ;;
        original:ohos) printf '%s\n' "$ORIGINAL_OHOS_NPM_REGISTRY" ;;
        original:ohpm) printf '%s\n' "$ORIGINAL_OHPM_REGISTRY" ;;
        original:koala) printf '%s\n' "$ORIGINAL_KOALA_NPM_REGISTRY" ;;
        *)
            return 1
            ;;
    esac
}

generate_npmrc() {
    local requested_profile="${1:-mirror}"
    local profile=""
    if ! profile="$(normalize_npmrc_profile "$requested_profile" 2>/dev/null)"; then
        err "Unsupported npmrc profile: $requested_profile"
        return 1
    fi
    local npm_registry=""
    local ohos_registry=""
    local koala_registry=""
    npm_registry="$(registry_for_npmrc_profile "$profile" npm)"
    ohos_registry="$(registry_for_npmrc_profile "$profile" ohos)"
    koala_registry="$(registry_for_npmrc_profile "$profile" koala)"
    cat <<EOF
fund=false
package-lock=true
strict-ssl=false
lockfile=false
registry=${npm_registry}
@ohos:registry=${ohos_registry}
@azanat:registry=${koala_registry}
@koalaui:registry=${koala_registry}
@arkoala:registry=${koala_registry}
@panda:registry=${koala_registry}
@idlizer:registry=${koala_registry}
EOF
}

print_help_npmrc() {
    cat <<HELP
npmrc - show generated npm registry profiles used by ohos.sh

Usage:
  ohos npmrc [mirror|original]

Profiles:
  mirror
      Internal mirror profile. This remains the default for sync/build.
  original
      Public/default registries for manual npm/ohpm work without the internal mirror.

Notes:
  - The active sync/build profile is controlled by OHOS_SYNC_NPMRC_PROFILE in ${OHOS_CONF}.
  - Public original defaults currently resolve to:
      npm   -> ${ORIGINAL_NPM_REGISTRY}
      @ohos -> ${ORIGINAL_OHOS_NPM_REGISTRY}
      ohpm  -> ${ORIGINAL_OHPM_REGISTRY}
  - Private koala scopes in the original profile use ORIGINAL_KOALA_NPM_REGISTRY.
    If that variable is not set, they fall back to the current KOALA_NPM_REGISTRY value.

Examples:
  ohos npmrc
  ohos npmrc mirror
  ohos npmrc original
HELP
}

check_stale_backup() {
    local stale
    stale=$(ls "$HOME"/.npmrc.ohos_backup_* 2>/dev/null | head -1 || true)
    if [ -n "$stale" ]; then
        warn "Found stale .npmrc backup from a previous crashed run:"
        warn "  $stale"
        warn "Your current ~/.npmrc may have been replaced by the script."
        if confirm_default_yes "Restore from backup? [Y/n] "; then
            cp -a "$stale" "$NPMRC"
            rm -f "$stale"
            info "~/.npmrc restored from stale backup."
        else
            warn "Keeping current ~/.npmrc. Removing stale backup."
            rm -f "$stale"
        fi
    fi
}

protect_npmrc() {
    local profile=""
    check_stale_backup
    profile="$(sync_npmrc_profile)" || return 1

    NPMRC_BAK="$HOME/.npmrc.ohos_backup_$$"
    if [ -f "$NPMRC" ]; then
        cp -a "$NPMRC" "$NPMRC_BAK"
    else
        touch "$NPMRC_BAK.empty"
        NPMRC_BAK="${NPMRC_BAK}.empty"
    fi

    generate_npmrc "$profile" > "$NPMRC"
    NPMRC_PROTECTED=1
    info "~/.npmrc replaced with script config profile '${profile}' (backup: ${NPMRC_BAK})"
}

restore_npmrc() {
    if [ "$NPMRC_PROTECTED" -ne 1 ]; then
        return
    fi

    if [ -n "$NPMRC_BAK" ] && [ -f "$NPMRC_BAK" ]; then
        if [[ "$NPMRC_BAK" == *.empty ]]; then
            rm -f "$NPMRC"
            info "~/.npmrc removed (did not exist before)"
        else
            if cp -a "$NPMRC_BAK" "$NPMRC"; then
                info "~/.npmrc restored from backup"
            else
                err "FAILED to restore ~/.npmrc!"
                err "Your backup is at: ${NPMRC_BAK}"
                err "Restore manually: cp '${NPMRC_BAK}' ~/.npmrc"
                NPMRC_PROTECTED=0
                return 1
            fi
        fi
        rm -f "$NPMRC_BAK"
        NPMRC_PROTECTED=0
    else
        err "FAILED to restore ~/.npmrc - backup file not found!"
        err "Expected backup at: ${NPMRC_BAK}"
        err "The script's .npmrc may still be in place."
        err "Run 'ohos npmrc' to see what the script wrote and restore ~/.npmrc manually."
        NPMRC_PROTECTED=0
        return 1
    fi
}

setup_proxy_fallback() {
    if [ -n "$OHOS_PROXY" ] && [ -x "$CURL_WRAPPER" ]; then
        CURL_WRAPPER_DIR=$(mktemp -d /tmp/ohos_curl_XXXXXX)
        ln -sf "$CURL_WRAPPER" "$CURL_WRAPPER_DIR/curl"
        export PATH="${CURL_WRAPPER_DIR}:${PATH}"
        export OHOS_CURL_PROXY="$OHOS_PROXY"
        export OHOS_CURL_CONNECT_TIMEOUT="$OHOS_PROXY_CONNECT_TIMEOUT"
        export no_proxy="$OHOS_NO_PROXY"
        export NO_PROXY="$OHOS_NO_PROXY"
        info "Proxy fallback enabled: direct first, then $OHOS_PROXY (timeout=${OHOS_PROXY_CONNECT_TIMEOUT}s)"
    fi
}

cleanup_proxy_fallback() {
    if [ -n "${CURL_WRAPPER_DIR:-}" ] && [ -d "${CURL_WRAPPER_DIR:-}" ]; then
        rm -rf "$CURL_WRAPPER_DIR"
    fi
}

ensure_home_bin() {
    mkdir -p "$HOME/bin"
    case ":$PATH:" in
        *":$HOME/bin:"*) ;;
        *) export PATH="$HOME/bin:$PATH" ;;
    esac
}

install_repo_tool() {
    ensure_home_bin
    curl -L "$REPO_INSTALL_URL" -o "$HOME/bin/repo"
    chmod a+x "$HOME/bin/repo"
}

load_nvm_if_present() {
    local nvm_dir
    if has_command nvm; then
        return 0
    fi

    nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$nvm_dir/nvm.sh" ]; then
        # shellcheck disable=SC1090
        . "$nvm_dir/nvm.sh" >/dev/null 2>&1
    fi

    has_command nvm
}

install_nvm() {
    curl -fsSL "$NVM_INSTALL_URL" | bash
    load_nvm_if_present
}

install_node_lts() {
    if ! load_nvm_if_present; then
        err "nvm is still unavailable after installation."
        return 1
    fi

    nvm install --lts
    nvm alias default 'lts/*' >/dev/null 2>&1 || true
    nvm use --lts >/dev/null
}

ensure_repo_available() {
    if has_command repo; then
        return 0
    fi

    warn "The 'repo' tool is not installed."
    warn "Expected install command: curl -L ${REPO_INSTALL_URL} -o ~/bin/repo && chmod a+x ~/bin/repo"
    if confirm_default_yes "Install repo to ~/bin/repo now? [Y/n] "; then
        run_step "[preflight] install repo tool" install_repo_tool
    else
        err "The 'repo' tool is required for this command."
        exit 1
    fi
}

ensure_node_tooling() {
    if has_command npm; then
        return 0
    fi

    load_nvm_if_present || true
    if has_command npm; then
        return 0
    fi

    if ! has_command nvm; then
        warn "nvm is not installed."
        warn "Expected install command: curl -fsSL ${NVM_INSTALL_URL} | bash"
        if confirm_default_yes "Install nvm now? [Y/n] "; then
            run_step "[preflight] install nvm" install_nvm
        else
            err "nvm/npm is required for prebuilts and build flows."
            exit 1
        fi
    fi

    if ! load_nvm_if_present; then
        err "Failed to load nvm from \$NVM_DIR or ~/.nvm."
        exit 1
    fi

    if has_command npm; then
        return 0
    fi

    warn "npm is not installed for the current shell."
    if confirm_default_yes "Install Node.js LTS with npm via nvm now? [Y/n] "; then
        run_step "[preflight] install Node.js LTS" install_node_lts
    else
        err "npm is required for prebuilts and build flows."
        exit 1
    fi

    if ! has_command npm; then
        err "npm is still unavailable after Node.js installation."
        exit 1
    fi
}

current_repo_parent_dir() {
    dirname "$(pwd)"
}

prebuilts_link_path() {
    printf '%s/%s\n' "$(current_repo_parent_dir)" "$PREBUILTS_SYMLINK_NAME"
}

make_timestamped_backup_path() {
    local path="$1"
    local stamp
    local candidate
    local suffix=1

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    candidate="${path}.bak.${stamp}"
    while [ -e "$candidate" ] || [ -L "$candidate" ]; do
        candidate="${path}.bak.${stamp}.${suffix}"
        suffix=$((suffix + 1))
    done
    printf '%s\n' "$candidate"
}

backup_existing_path() {
    local path="$1"
    local backup_path

    backup_path="$(make_timestamped_backup_path "$path")"
    if ! mv "$path" "$backup_path"; then
        err "Failed to move existing path out of the way: $path"
        exit 1
    fi
    info "Existing path backed up: $path -> $backup_path"
}

run_logged_command() {
    local log_path="$1"
    local rc
    shift

    "$@" 2>&1 | tee "$log_path"
    rc=${PIPESTATUS[0]}
    return "$rc"
}

run_logged_command_via_pty() {
    local log_path="$1"
    local rc
    shift
    local rendered=""

    rendered="$(shell_join_command "$@")"
    script -qefc "$rendered" /dev/null 2>&1 | tee "$log_path"
    rc=${PIPESTATUS[0]}
    return "$rc"
}

format_duration_compact() {
    local total="${1:-0}"
    if [ "$total" -lt 0 ]; then
        total=0
    fi
    local h=$((total / 3600))
    local m=$(((total % 3600) / 60))
    local s=$((total % 60))
    if [ "$h" -gt 0 ]; then
        printf '%dh %02dm %02ds' "$h" "$m" "$s"
    elif [ "$m" -gt 0 ]; then
        printf '%dm %02ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

render_progress_bar() {
    local label="$1"
    local done="$2"
    local total="$3"
    local start_ts="$4"
    local width=30
    local now elapsed pct filled eta total_estimate

    now="$(date +%s)"
    elapsed=$((now - start_ts))
    if [ "$total" -le 0 ]; then
        printf '\r[ohos] %s: %s elapsed' "$label" "$(format_duration_compact "$elapsed")"
        return 0
    fi

    if [ "$done" -lt 0 ]; then done=0; fi
    if [ "$done" -gt "$total" ]; then done="$total"; fi
    pct=$((done * 100 / total))
    filled=$((done * width / total))
    eta="-"
    if [ "$done" -gt 0 ] && [ "$elapsed" -gt 0 ]; then
        total_estimate=$((elapsed * total / done))
        eta="$(format_duration_compact "$((total_estimate - elapsed))")"
    fi

    printf '\r[ohos] %s: [' "$label"
    printf '%*s' "$filled" '' | tr ' ' '='
    printf '>'
    printf '%*s' "$((width - filled))" '' | tr ' ' '.'
    printf '] %3d%% (%d/%d) elapsed=%s eta=%s' \
        "$pct" "$done" "$total" "$(format_duration_compact "$elapsed")" "$eta"
}

repo_project_count() {
    local count
    count="$(repo list 2>/dev/null | wc -l | tr -d ' ')"
    case "$count" in
        ''|*[!0-9]*) count=0 ;;
    esac
    local manifest_count=0
    manifest_count="$(repo_manifest_project_count)"
    case "$manifest_count" in
        ''|*[!0-9]*) manifest_count=0 ;;
    esac
    if [ "$manifest_count" -gt "$count" ]; then
        count="$manifest_count"
    fi
    printf '%s\n' "$count"
}

repo_manifest_project_count() {
    local manifest_path=".repo/manifest.xml"
    if [ ! -f "$manifest_path" ]; then
        printf '0\n'
        return 0
    fi
    if ! has_command python3; then
        printf '0\n'
        return 0
    fi

    python3 - "$manifest_path" <<'PY' 2>/dev/null || printf '0\n'
import os
import sys
import xml.etree.ElementTree as ET

seen = set()


def count_projects(path: str) -> int:
    real_path = os.path.abspath(path)
    if real_path in seen or not os.path.exists(real_path):
        return 0
    seen.add(real_path)

    try:
        root = ET.parse(real_path).getroot()
    except Exception:
        return 0

    total = sum(1 for node in root.iter() if node.tag == "project")
    base_dir = os.path.dirname(real_path)
    for node in root.iter():
        if node.tag != "include":
            continue
        name = (node.get("name") or "").strip()
        if not name:
            continue
        include_path = name if os.path.isabs(name) else os.path.join(base_dir, name)
        total += count_projects(include_path)
    return total


print(count_projects(sys.argv[1]))
PY
}

# Resolve project name(s) to repo checkout path(s).
# If arg is already a valid directory, pass through.
# Otherwise, look up via "repo list" to map project name -> path.
resolve_repo_paths() {
    local -a result=()
    local arg path
    for arg in "$@"; do
        if [ -d "$arg" ]; then
            result+=("$arg")
        else
            path="$(repo list -p "$arg" 2>/dev/null | head -1)" || true
            if [ -n "$path" ] && [ -d "$path" ]; then
                result+=("$path")
            else
                err "unknown project or path: $arg"
                return 1
            fi
        fi
    done
    printf '%s\n' "${result[@]}"
}

repo_sync_progress_count() {
    local log_path="$1"
    local ratio_done=0
    local ratio_max=0
    local fallback_done=0
    if [ ! -s "$log_path" ]; then
        printf '0\n'
        return 0
    fi
    ratio_done="$(grep -Eo '\([0-9]+/[0-9]+\)' "$log_path" 2>/dev/null \
        | sed -E 's/[()]//g; s#/.*$##' \
        | sort -n \
        | tail -n 1 \
        | tr -d ' ')"
    case "$ratio_done" in
        ''|*[!0-9]*) ratio_done=0 ;;
    esac
    fallback_done="$(grep -E '^(Fetching project|Checking out|project )' "$log_path" 2>/dev/null \
        | sed -E 's/^Fetching project[[:space:]]+//; s/^Checking out[[:space:]]+//; s/^project[[:space:]]+//; s/[[:space:]]+.*$//; s#/$##; s#:$##' \
        | sed '/^$/d' \
        | sort -u \
        | wc -l \
        | tr -d ' ')"
    case "$fallback_done" in
        ''|*[!0-9]*) fallback_done=0 ;;
    esac
    if [ "$ratio_done" -gt "$fallback_done" ]; then
        ratio_max="$ratio_done"
    else
        ratio_max="$fallback_done"
    fi
    printf '%s\n' "$ratio_max"
}

repo_sync_progress_snapshot() {
    local log_path="$1"
    local fallback_done=0

    if [ ! -s "$log_path" ]; then
        printf 'sync|0|0\n'
        return 0
    fi

    if has_command python3; then
        python3 - "$log_path" <<'PY' 2>/dev/null && return 0
import re
import sys

fetch = None
checkout = None

with open(sys.argv[1], "r", encoding="utf-8", errors="ignore") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        match = re.search(r"^Fetching projects:.*?\((\d+)/(\d+)\)", line)
        if match:
            fetch = (int(match.group(1)), int(match.group(2)))
            continue
        match = re.search(r"^Checking out projects:.*?\((\d+)/(\d+)\)", line)
        if match:
            checkout = (int(match.group(1)), int(match.group(2)))

if checkout and fetch:
    print(f"checkout|{checkout[0]}|{checkout[1]}")
elif fetch:
    print(f"fetch|{fetch[0]}|{fetch[1]}")
else:
    print("sync|0|0")
PY
    fi

    fallback_done="$(repo_sync_progress_count "$log_path")"
    case "$fallback_done" in
        ''|*[!0-9]*) fallback_done=0 ;;
    esac
    printf 'sync|%s|0\n' "$fallback_done"
}

lfs_progress_count() {
    local log_path="$1"
    if [ ! -s "$log_path" ]; then
        printf '0\n'
        return 0
    fi
    grep -E '^project[[:space:]]+' "$log_path" 2>/dev/null \
        | awk '{print $2}' \
        | sed -E 's#/$##' \
        | sed '/^$/d' \
        | sort -u \
        | wc -l \
        | tr -d ' '
}

is_git_lfs_pointer_file() {
    local file_path="$1"
    local first_line=""

    if [ ! -f "$file_path" ]; then
        return 1
    fi

    IFS= read -r first_line < "$file_path" || true
    [ "$first_line" = "version https://git-lfs.github.com/spec/v1" ]
}

check_critical_lfs_archives() {
    local -a patterns=(
        "foundation/arkui/ace_engine/frameworks/bridge/arkts_frontend/arkui_idlize/*.tgz"
    )
    local -a bad_files=()
    local pattern
    local file_path

    shopt -s nullglob
    for pattern in "${patterns[@]}"; do
        for file_path in $pattern; do
            if is_git_lfs_pointer_file "$file_path"; then
                bad_files+=("$file_path")
            fi
        done
    done
    shopt -u nullglob

    if [ ${#bad_files[@]} -eq 0 ]; then
        return 0
    fi

    err "Detected unresolved Git LFS pointer files after sync:"
    printf '%s\n' "${bad_files[@]}" | sed 's/^/[ohos]   /' >&2
    err "These files must be real archives before build; otherwise npm/tar may fail with TAR_BAD_ARCHIVE."
    err "Remediation: cd foundation/arkui/ace_engine && env -u LocalMediaDir -u LocalReferenceDirs -u TempDir -u LfsStorageDir GIT_LFS_STORAGE=.git/lfs git lfs pull --include=\"frameworks/bridge/arkts_frontend/arkui_idlize/*.tgz\""
    return 1
}

# ---------------------------------------------------------------------------
# git-lfs 3.0.2 (Ubuntu 22.04, cannot upgrade) has a path-resolution bug:
# when lfs.storage ends with "/lfs/objects", git-lfs appends another
# "objects/" internally, resolving to ".../lfs/objects/objects" instead of
# ".../lfs/objects".  This causes mkdir permission failures during checkout
# when the double-objects path is owned by another user.
#
# The fix is to strip the trailing "/objects" so git-lfs resolves correctly
# to ".../lfs/objects".  Safe to remove when git-lfs >= 3.1 is available.
# ---------------------------------------------------------------------------
fix_lfs_storage() {
    local config fixed=0 total=0
    local storage

    for config in .repo/projects/*/config; do
        [ -f "$config" ] || continue
        total=$((total + 1))
        storage="$(git config -f "$config" --get lfs.storage 2>/dev/null)" || continue
        if [ -z "$storage" ]; then
            continue
        fi
        case "$storage" in
            */lfs/objects)
                git config -f "$config" lfs.storage "${storage%/objects}"
                fixed=$((fixed + 1))
                ;;
        esac
    done

    if [ "$fixed" -gt 0 ]; then
        info "Fixed lfs.storage in ${fixed}/${total} project configs (stripped trailing /objects for git-lfs 3.0.2 compat)."
    fi
}

run_logged_command_with_progress() {
    local log_path="$1"
    local label="$2"
    local progress_kind="$3"
    local total_hint="$4"
    shift 4
    local rc=0
    local pid=0
    local start_ts done total current_total current_label snapshot phase

    total="$total_hint"
    case "$total" in
        ''|*[!0-9]*) total=0 ;;
    esac
    if [ "$total" -le 0 ]; then
        total="$(repo_project_count)"
    fi
    start_ts="$(date +%s)"

    if [ "${SYNC_RAW_OUTPUT:-false}" = "true" ]; then
        if has_command script; then
            run_logged_command_via_pty "$log_path" "$@"
        else
            run_logged_command "$log_path" "$@"
        fi
        return $?
    fi

    if has_command script; then
        local rendered=""
        rendered="$(shell_join_command "$@")"
        script -qefc "$rendered" /dev/null >"$log_path" 2>&1 &
        pid=$!
    else
        "$@" >"$log_path" 2>&1 &
        pid=$!
    fi

    while kill -0 "$pid" 2>/dev/null; do
        current_label="$label"
        current_total="$total"
        case "$progress_kind" in
            repo_sync)
                snapshot="$(repo_sync_progress_snapshot "$log_path")"
                phase="${snapshot%%|*}"
                snapshot="${snapshot#*|}"
                done="${snapshot%%|*}"
                current_total="${snapshot##*|}"
                case "$phase" in
                    fetch) current_label="${label} (fetch)" ;;
                    checkout) current_label="${label} (checkout)" ;;
                    *) current_label="$label" ;;
                esac
                ;;
            lfs_sync) done="$(lfs_progress_count "$log_path")" ;;
            *) done=0 ;;
        esac
        case "$done" in
            ''|*[!0-9]*) done=0 ;;
        esac
        case "$current_total" in
            ''|*[!0-9]*) current_total="$total" ;;
        esac
        if [ "$current_total" -le 0 ]; then
            current_total="$total"
        fi
        render_progress_bar "$current_label" "$done" "$current_total" "$start_ts"
        sleep 1
    done

    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi

    current_label="$label"
    current_total="$total"
    case "$progress_kind" in
        repo_sync)
            snapshot="$(repo_sync_progress_snapshot "$log_path")"
            phase="${snapshot%%|*}"
            snapshot="${snapshot#*|}"
            done="${snapshot%%|*}"
            current_total="${snapshot##*|}"
            case "$phase" in
                fetch) current_label="${label} (fetch)" ;;
                checkout) current_label="${label} (checkout)" ;;
                *) current_label="$label" ;;
            esac
            if [ "$rc" -eq 0 ]; then
                current_label="$label"
                current_total="$total"
                if [ "$current_total" -le 0 ] && [ "$done" -gt 0 ]; then
                    current_total="$done"
                fi
                done="$current_total"
            fi
            ;;
        lfs_sync) done="$(lfs_progress_count "$log_path")" ;;
        *) done=0 ;;
    esac
    case "$done" in
        ''|*[!0-9]*) done=0 ;;
    esac
    case "$current_total" in
        ''|*[!0-9]*) current_total="$total" ;;
    esac
    if [ "$current_total" -le 0 ]; then
        current_total="$total"
    fi
    render_progress_bar "$current_label" "$done" "$current_total" "$start_ts"
    printf '\n'

    if [ "$rc" -ne 0 ]; then
        err "${label} failed; tail of output:"
        while IFS= read -r line; do
            err "$line"
        done < <(tail -n 60 "$log_path")
    fi
    return "$rc"
}

run_repo_sync_logged() {
    local log_path="$1"
    local jobs="$2"
    local fail_fast="$3"
    shift 3
    local -a cmd=(repo sync -j "$jobs" --optimized-fetch --current-branch --retry-fetches=5)

    if [ "$fail_fast" = "true" ]; then
        cmd+=(--fail-fast)
    fi
    if [ "$SYNC_FORCE_ENABLED" = "true" ]; then
        cmd+=(--force-sync)
    fi
    if [ $# -gt 0 ]; then
        cmd+=("$@")
    fi

    local total_hint=0
    if [ $# -gt 0 ]; then
        total_hint=$#
    fi
    run_logged_command_with_progress "$log_path" "repo sync" "repo_sync" "$total_hint" "${cmd[@]}"
}

collect_repo_sync_failures() {
    local log_path="$1"
    local line
    local path
    local capture=0
    local -a ordered_paths=()
    local -A seen=()

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$capture" -eq 1 ]; then
            case "$line" in
                "Try re-running"*)
                    capture=0
                    ;;
                error:*)
                    capture=0
                    ;;
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
            "Failing repos:")
                capture=1
                continue
                ;;
        esac

        if [[ "$line" =~ ^error:\ ([^:]+)\/:\  ]]; then
            path="${BASH_REMATCH[1]}"
            if [ -n "$path" ] && [ -z "${seen[$path]+x}" ]; then
                ordered_paths+=("$path")
                seen["$path"]=1
            fi
        fi
    done < "$log_path"

    if [ ${#ordered_paths[@]} -gt 0 ]; then
        printf '%s\n' "${ordered_paths[@]}"
    fi
}

force_clean_repo_path() {
    local repo_path="$1"

    if [ ! -d "$repo_path" ]; then
        err "Failing repo path not found: $repo_path"
        return 1
    fi
    if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
        err "Failing repo path is not a git checkout: $repo_path"
        return 1
    fi

    info "Force-cleaning repo worktree: $repo_path"
    git -C "$repo_path" rebase --abort >/dev/null 2>&1 || true
    git -C "$repo_path" merge --abort >/dev/null 2>&1 || true
    git -C "$repo_path" am --abort >/dev/null 2>&1 || true
    # Skip LFS smudge during reset to avoid "filter-process died of signal" errors.
    # LFS checkout will be handled separately by sync_stage_lfs or LFS recovery.
    git -C "$repo_path" -c lfs.fetchexclude="*" reset --hard HEAD
    git -C "$repo_path" clean -ffdx
}

force_clean_repo_paths() {
    local repo_path
    for repo_path in "$@"; do
        force_clean_repo_path "$repo_path"
    done
}

ensure_prebuilts_link() {
    local link_path
    local actual_target

    link_path="$(prebuilts_link_path)"
    if [ ! -d "$SHARED_PREBUILTS_DIR" ]; then
        err "Shared prebuilts directory not found: $SHARED_PREBUILTS_DIR"
        exit 1
    fi

    if [ -L "$link_path" ]; then
        actual_target="$(readlink -f "$link_path" 2>/dev/null || true)"
        if [ "$actual_target" = "$SHARED_PREBUILTS_DIR" ]; then
            info "Sibling prebuilts link is ready: $link_path -> $SHARED_PREBUILTS_DIR"
            return 0
        fi

        warn "Sibling prebuilts link points elsewhere:"
        warn "  $link_path -> ${actual_target:-unknown}"
        if [ "$SYNC_FORCE_ENABLED" = "true" ]; then
            backup_existing_path "$link_path"
            ln -s "$SHARED_PREBUILTS_DIR" "$link_path"
            info "Sibling prebuilts link replaced in force mode: $link_path -> $SHARED_PREBUILTS_DIR"
        elif confirm_default_no "Replace it with $SHARED_PREBUILTS_DIR? [y/N] "; then
            rm -f "$link_path"
            ln -s "$SHARED_PREBUILTS_DIR" "$link_path"
            info "Sibling prebuilts link updated: $link_path -> $SHARED_PREBUILTS_DIR"
        else
            err "Cannot continue with an unexpected sibling prebuilts link."
            exit 1
        fi
        return 0
    fi

    if [ -e "$link_path" ]; then
        if [ "$SYNC_FORCE_ENABLED" = "true" ]; then
            backup_existing_path "$link_path"
        else
            err "Expected sibling prebuilts link path already exists and is not a symlink:"
            err "  $link_path"
            err "Move it away or replace it manually, then rerun the command."
            exit 1
        fi
    fi

    ln -s "$SHARED_PREBUILTS_DIR" "$link_path"
    info "Sibling prebuilts link created: $link_path -> $SHARED_PREBUILTS_DIR"
}

ensure_sync_prereqs() {
    local needs_prebuilts="${1:-true}"
    ensure_repo_available
    if [ "$needs_prebuilts" = "true" ]; then
        ensure_node_tooling
        ensure_prebuilts_link
    fi
}

ensure_build_prereqs() {
    ensure_node_tooling
    ensure_prebuilts_link
    configure_ccache
}

repo_root_temp_venv_path() {
    printf '%s\n' "$(pwd)/oh_venv"
}

cleanup_repo_root_temp_venv() {
    local venv_path="oh_venv"
    local display_path=""
    local looks_like_venv=false

    if [ ! -e "$venv_path" ] && [ ! -L "$venv_path" ]; then
        return 0
    fi

    display_path="$(repo_root_temp_venv_path)"
    if [ -f "$venv_path/pyvenv.cfg" ] || [ -f "$venv_path/bin/activate" ]; then
        looks_like_venv=true
    fi
    if [ -e "$venv_path/bin/python3" ] || [ -L "$venv_path/bin/python3" ]; then
        looks_like_venv=true
    fi

    if [ "$looks_like_venv" != "true" ]; then
        warn "Repo root contains an unexpected path named oh_venv; leaving it untouched: $display_path"
        return 0
    fi

    warn "Removing stale temporary Python venv left by OHOS prebuilts scripts: $display_path"
    if ! rm -rf -- "$venv_path"; then
        err "Failed to remove stale temporary Python venv: $display_path"
        exit 1
    fi
}

configure_ccache() {
    export CCACHE_DIR
    export CCACHE_MAXSIZE

    mkdir -p "$CCACHE_DIR"

    if has_command ccache; then
        ccache -M "$CCACHE_MAXSIZE" >/dev/null
        info "ccache ready: dir=$CCACHE_DIR max_size=$CCACHE_MAXSIZE"
    else
        warn "ccache binary not found in PATH. build.sh --ccache may not use compiler cache."
    fi
}

sync_stage_repo() {
    local rc
    local attempt=1
    local jobs="$REPO_SYNC_JOBS"
    local fail_fast=false
    local -a target_paths=()
    local -a parsed_paths=()

    fix_lfs_storage

    while true; do
        LAST_STEP_LOG="$(mktemp /tmp/ohos_repo_sync_XXXXXX.log)"
        if run_repo_sync_logged "$LAST_STEP_LOG" "$jobs" "$fail_fast" "${target_paths[@]}"; then
            if [ ${#target_paths[@]} -gt 0 ]; then
                info "repo sync recovery succeeded for the failing repos."
            fi
            return 0
        else
            rc=$?
        fi

        # Detect LFS smudge filter failures in the sync log and attempt
        # targeted recovery before falling through to force-mode retry.
        # The common pattern is "git-lfs filter-process --skip died of
        # signal 15" which leaves .tgz files as pointer stubs and causes
        # checkout to fail.  Running "git lfs checkout" for those repos
        # resolves the pointers from the local LFS mirror without
        # re-downloading.
        if grep -q 'git-lfs filter-process.*died of signal\|smudge filter lfs failed\|lfs.*failed' "$LAST_STEP_LOG" 2>/dev/null; then
            mapfile -t _lfs_failed_paths < <(collect_repo_sync_failures "$LAST_STEP_LOG")
            if [ ${#_lfs_failed_paths[@]} -gt 0 ]; then
                local _lfs_repo
                info "Detected Git LFS smudge failures; attempting targeted LFS checkout for ${#_lfs_failed_paths[@]} repo(s):"
                printf '%s\n' "${_lfs_failed_paths[@]}" | sed 's/^/[ohos]   /' >&2
                for _lfs_repo in "${_lfs_failed_paths[@]}"; do
                    if [ -d "$_lfs_repo" ] && git -C "$_lfs_repo" rev-parse --git-dir >/dev/null 2>&1; then
                        info "  LFS checkout: $_lfs_repo"
                        local _lfs_env='env -u LocalMediaDir -u LocalReferenceDirs -u TempDir -u LfsStorageDir GIT_LFS_STORAGE=.git/lfs'
                        # First try to fetch from mirror, then checkout
                        (cd "$_lfs_repo" && eval "${_lfs_env}" git lfs fetch --all 2>&1 && eval "${_lfs_env}" git lfs checkout 2>&1) || true
                    fi
                done

                # Re-run repo sync only for the recovered repos
                info "Re-running repo sync for LFS-recovered repos..."
                LAST_STEP_LOG="$(mktemp /tmp/ohos_repo_sync_XXXXXX.log)"
                if run_repo_sync_logged "$LAST_STEP_LOG" 1 true "${_lfs_failed_paths[@]}"; then
                    info "repo sync recovery after LFS fix succeeded."
                    return 0
                fi
                rc=$?
            fi
        fi

        if [ "$SYNC_FORCE_ENABLED" != "true" ]; then
            mapfile -t _hint_paths < <(collect_repo_sync_failures "$LAST_STEP_LOG")
            if [ ${#_hint_paths[@]} -gt 0 ]; then
                err "To retry specific projects:"
                for _hp in "${_hint_paths[@]}"; do
                    err "  ohos sync $_hp"
                done
            else
                err "To retry: ohos sync <project>"
            fi
            return "$rc"
        fi

        mapfile -t parsed_paths < <(collect_repo_sync_failures "$LAST_STEP_LOG")
        if [ ${#parsed_paths[@]} -eq 0 ]; then
            err "repo sync failed in force mode, but failing repos could not be identified automatically."
            return "$rc"
        fi

        err "repo sync failed. Force mode will discard local changes in the failing repos and retry:"
        printf '%s\n' "${parsed_paths[@]}" | sed 's/^/[ohos]   /' >&2
        force_clean_repo_paths "${parsed_paths[@]}"

        target_paths=("${parsed_paths[@]}")
        jobs=1
        fail_fast=true
        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$SYNC_FORCE_MAX_RETRIES" ]; then
            err "repo sync force retry limit reached (${SYNC_FORCE_MAX_RETRIES})."
            return "$rc"
        fi
    done
}

sync_stage_lfs() {
    local rc
    local lfs_env_prefix='env -u LocalMediaDir -u LocalReferenceDirs -u TempDir -u LfsStorageDir GIT_LFS_STORAGE=.git/lfs'

    LAST_STEP_LOG="$(mktemp /tmp/ohos_lfs_sync_XXXXXX.log)"
    if run_logged_command_with_progress "$LAST_STEP_LOG" "git lfs" "lfs_sync" 0 \
        repo forall -j "$LFS_JOBS" -c \
        "echo project \$REPO_PATH && ${lfs_env_prefix} git lfs fetch && ${lfs_env_prefix} git lfs checkout"; then
        if check_critical_lfs_archives; then
            return 0
        fi
        return 1
    fi

    rc=$?
    return "$rc"
}

sync_stage_prebuilts() {
    local download_sdk="${1:-false}"
    local rc
    local npm_registry_for_sync=""
    local -a prebuilts_args=(
        --npm-registry "$NPM_REGISTRY"
        --pypi-url "$PYPI_URL"
        --trusted-host "$TRUSTED_HOST"
        --skip-ssl
    )

    if [ "$download_sdk" = "true" ]; then
        prebuilts_args+=(--download-sdk)
    fi

    cleanup_repo_root_temp_venv
    protect_npmrc
    setup_proxy_fallback
    npm_registry_for_sync="$(registry_for_npmrc_profile "$(sync_npmrc_profile)" npm)"
    prebuilts_args[1]="$npm_registry_for_sync"

    LAST_STEP_LOG="$(mktemp /tmp/ohos_prebuilts_XXXXXX.log)"
    if run_logged_command "$LAST_STEP_LOG" \
        bash build/prebuilts_download.sh \
        "${prebuilts_args[@]}"; then
        rc=0
    else
        rc=$?
    fi

    restore_npmrc || true   # failure is already reported inside restore_npmrc; don't abort the chain
    cleanup_proxy_fallback
    return "$rc"
}

cmd_init() {
    local branch="$INIT_BRANCH"
    local manifest=""
    local depth=""
    local auto_sync="${OHOS_INIT_AUTOSYNC:-1}"

    while [ $# -gt 0 ]; do
        case "$1" in
            --branch|-b)
                [ $# -ge 2 ] || { err "init: missing value for $1"; exit 1; }
                branch="$2"
                shift 2
                ;;
            --manifest|-m)
                [ $# -ge 2 ] || { err "init: missing value for $1"; exit 1; }
                manifest="$2"
                shift 2
                ;;
            --depth)
                [ $# -ge 2 ] || { err "init: missing value for $1"; exit 1; }
                depth="--depth $2"
                shift 2
                ;;
            --no-sync)
                auto_sync=0
                shift
                ;;
            *)
                err "init: unknown option $1"
                exit 1
                ;;
        esac
    done

    ensure_repo_available
    if [ -d ".repo" ]; then
        warn "Directory already contains .repo/ - re-initializing."
    fi

    local manifest_arg=""
    if [ -n "$manifest" ]; then
        manifest_arg="-m $manifest"
    fi

    info "Initializing OpenHarmony repo (branch=$branch)..."
    repo init \
        -u "$REPO_MANIFEST_URL" \
        -b "$branch" \
        --reference="$REPO_REFERENCE" \
        $INIT_EXTRA_ARGS \
        $manifest_arg \
        $depth

    info "Init complete."
    if [ "$auto_sync" = "1" ]; then
        info "Init finished. Auto-running sync..."
        cmd_sync
    fi
}

cmd_sync() {
    require_repo_initialized

    local run_lfs=true
    local run_prebuilts=true
    local sync_download_sdk=false
    local -a sync_projects=()

    SYNC_FORCE_ENABLED=false
    SYNC_RAW_OUTPUT=false

    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--force) SYNC_FORCE_ENABLED=true ;;
            --raw-output) SYNC_RAW_OUTPUT=true ;;
            --download-sdk) sync_download_sdk=true ;;
            --skip-lfs) run_lfs=false ;;
            --skip-prebuilts) run_prebuilts=false ;;
            --repo-only)
                run_lfs=false
                run_prebuilts=false
                ;;
            -*)
                err "sync: unknown option $1"
                exit 1
                ;;
            *)
                sync_projects+=("$1")
                ;;
        esac
        shift
    done

    # Single/multi-project sync: repo sync only those projects
    if [ ${#sync_projects[@]} -gt 0 ]; then
        local -a resolved_paths
        mapfile -t resolved_paths < <(resolve_repo_paths "${sync_projects[@]}") || return 1
        info "repo sync for ${#resolved_paths[@]} project(s): ${resolved_paths[*]}"
        repo sync -j "$REPO_SYNC_JOBS" --optimized-fetch --current-branch --retry-fetches=5 "${resolved_paths[@]}"
        local sync_rc=$?
        if [ "$sync_rc" -ne 0 ]; then
            err "repo sync failed for: ${resolved_paths[*]}"
            return "$sync_rc"
        fi
        local _lfs_env='env -u LocalMediaDir -u LocalReferenceDirs -u TempDir -u LfsStorageDir GIT_LFS_STORAGE=.git/lfs'
        for _sp in "${resolved_paths[@]}"; do
            if [ -d "$_sp" ]; then
                info "LFS checkout: $_sp"
                local _lfs_rc=0
                (cd "$_sp" && eval "${_lfs_env}" git lfs checkout 2>&1) || _lfs_rc=$?
                if [ "$_lfs_rc" -ne 0 ]; then
                    warn "LFS checkout failed for $_sp (exit $_lfs_rc), retrying..."
                    (cd "$_sp" && eval "${_lfs_env}" git lfs fetch --all 2>&1 && eval "${_lfs_env}" git lfs checkout 2>&1) || {
                        err "LFS checkout still failing for $_sp after retry"
                        return 1
                    }
                fi
            fi
        done
        info "Sync complete."
        return 0
    fi

    ensure_sync_prereqs "$run_prebuilts"

    local total=1
    local step=1
    [ "$run_lfs" = "true" ] && total=$((total + 1))
    [ "$run_prebuilts" = "true" ] && total=$((total + 1))

    run_step "[$step/$total] repo sync (jobs=$REPO_SYNC_JOBS)" sync_stage_repo

    if [ "$run_lfs" = "true" ]; then
        step=$((step + 1))
        run_step "[$step/$total] git lfs fetch + checkout (jobs=$LFS_JOBS)" sync_stage_lfs
    fi

    if [ "$run_prebuilts" = "true" ]; then
        step=$((step + 1))
        run_step "[$step/$total] prebuilts_download.sh" sync_stage_prebuilts "$sync_download_sdk"
    fi

    info "Sync complete."
}

cmd_reset() {
    require_ohos_repo
    local skip_sync=false
    local -a reset_projects=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --no-sync) skip_sync=true ;;
            -*)
                err "reset: unknown option $1"
                exit 1
                ;;
            *)
                reset_projects+=("$1")
                ;;
        esac
        shift
    done

    # Single-project reset mode
    if [ ${#reset_projects[@]} -eq 1 ]; then
        local -a resolved_paths
        mapfile -t resolved_paths < <(resolve_repo_paths "${reset_projects[0]}") || exit 1
        local project="${resolved_paths[0]}"

        info "Resetting single project: $project"
        info "  [1/3] removing $project"
        rm -rf "$project"

        info "  [2/3] repo sync $project"
        repo sync -j "$REPO_SYNC_JOBS" --optimized-fetch --current-branch "$project"
        local sync_rc=$?
        if [ "$sync_rc" -ne 0 ]; then
            err "repo sync failed for $project (exit $sync_rc)"
            err "  retry with: ohos sync $project"
            exit "$sync_rc"
        fi

        if [ -d "$project" ]; then
            info "  [3/3] LFS checkout $project"
            local _lfs_env='env -u LocalMediaDir -u LocalReferenceDirs -u TempDir -u LfsStorageDir GIT_LFS_STORAGE=.git/lfs'
            local _lfs_rc=0
            (cd "$project" && eval "${_lfs_env}" git lfs checkout 2>&1) || _lfs_rc=$?
            if [ "$_lfs_rc" -ne 0 ]; then
                warn "LFS checkout failed for $project (exit $_lfs_rc), retrying..."
                (cd "$project" && eval "${_lfs_env}" git lfs fetch --all 2>&1 && eval "${_lfs_env}" git lfs checkout 2>&1) || {
                    err "LFS checkout still failing for $project after retry"
                    exit 1
                }
            fi
        fi

        info "Reset complete: $project"
        return 0
    fi

    if [ ${#reset_projects[@]} -gt 1 ]; then
        err "reset: only one project at a time is supported (got ${#reset_projects[@]}: ${reset_projects[*]})"
        exit 1
    fi

    # Full reset (no project specified)
    warn "This will hard-reset ALL sub-repos and delete: ${RESET_RM_DIRS}"
    if [ "$RESET_LFS_PRUNE" = "true" ]; then
        warn "  + git lfs prune (slow)"
    fi
    if [ "$RESET_GC" = "true" ]; then
        warn "  + git gc (slow)"
    fi
    if ! confirm_default_no "Continue? [y/N] "; then
        info "Aborted."
        exit 0
    fi

    local step=1
    local total=3
    if [ "$RESET_LFS_PRUNE" = "true" ]; then total=$((total + 1)); fi
    if [ "$RESET_GC" = "true" ]; then total=$((total + 1)); fi
    if [ "$skip_sync" = "false" ]; then total=$((total + 1)); fi

    run_step "[$step/$total] clean all sub-repos (git clean -fxd)" \
        repo forall -j "$RESET_JOBS" -c 'git clean -fxd'
    step=$((step + 1))

    run_step "[$step/$total] hard-reset all sub-repos (git reset --hard HEAD)" \
        repo forall -j "$RESET_JOBS" -c 'git reset --hard HEAD'
    step=$((step + 1))

    if [ "$RESET_LFS_PRUNE" = "true" ]; then
        run_step "[$step/$total] prune LFS objects" repo forall -j "$GC_JOBS" -c 'git lfs prune'
        step=$((step + 1))
    fi

    if [ "$RESET_GC" = "true" ]; then
        run_step "[$step/$total] run git gc" repo forall -j "$GC_JOBS" -c 'git gc'
        step=$((step + 1))
    fi

    info "======== [$step/$total] remove ${RESET_RM_DIRS} ========"
    rm -rf $RESET_RM_DIRS
    step=$((step + 1))

    if [ "$skip_sync" = "false" ]; then
        info "======== [$step/$total] sync ========"
        cmd_sync
    fi

    info "Reset complete."
}

cmd_gc() {
    require_ohos_repo

    local do_prune="$GC_LFS_PRUNE"
    local do_gc="$GC_GIT_GC"

    while [ $# -gt 0 ]; do
        case "$1" in
            --no-prune) do_prune=false ;;
            --no-gc) do_gc=false ;;
            --prune) do_prune=true ;;
            --gc) do_gc=true ;;
            *)
                err "gc: unknown option $1"
                exit 1
                ;;
        esac
        shift
    done

    local step=0
    local total=0
    [ "$do_prune" = "true" ] && total=$((total + 1))
    [ "$do_gc" = "true" ] && total=$((total + 1))

    if [ "$total" -eq 0 ]; then
        warn "Nothing to do (both prune and gc disabled)."
        return
    fi

    info "Maintenance: prune=$do_prune, gc=$do_gc (jobs=$GC_JOBS)"

    if [ "$do_prune" = "true" ]; then
        step=$((step + 1))
        run_step "[$step/$total] prune LFS objects" repo forall -j "$GC_JOBS" -c 'git lfs prune'
    fi

    if [ "$do_gc" = "true" ]; then
        step=$((step + 1))
        run_step "[$step/$total] run git gc" repo forall -j "$GC_JOBS" -c 'git gc'
    fi

    info "Maintenance complete."
}

resolve_build_args() {
    local target="${1:-sdk}"
    local build_args=""
    case "$target" in
        sdk) build_args="$BUILD_SDK" ;;
        sdk-linux|sdklin) build_args="$BUILD_SDK_LINUX" ;;
        sdk-win|sdkwin) build_args="$BUILD_SDK_WIN" ;;
        rk3568|rk) build_args="$BUILD_RK3568" ;;
        *)
            local var_name="BUILD_$(echo "$target" | tr '[:lower:]-' '[:upper:]_')"
            build_args="${!var_name:-}"
            if [ -z "$build_args" ]; then
                build_args="--product-name $target --ccache"
            fi
            ;;
    esac

    printf '%s\n' "$build_args"
}

cmd_build_impl() {
    local fast_rebuild="${1:-false}"
    shift || true

    require_ohos_repo
    ensure_build_prereqs

    local target="sdk"
    if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
        target="$1"
        shift
    fi

    local build_args
    build_args="$(resolve_build_args "$target")"

    local build_mode_args=()
    local build_mode_prefix=""
    if [ "$fast_rebuild" = "true" ]; then
        build_mode_args+=(--fast-rebuild)
        build_mode_prefix="--fast-rebuild "
    fi

    cleanup_repo_root_temp_venv
    info "Building: ./build.sh ${build_mode_prefix}${build_args} $*"
    time ./build.sh "${build_mode_args[@]}" $build_args "$@"
}

cmd_build() {
    cmd_build_impl false "$@"
}

cmd_fast_rebuild() {
    cmd_build_impl true "$@"
}

resolve_ace_unittest_runner() {
    local runner="${OHOS_ACE_UNITTEST_RUNNER:-foundation/arkui/ace_engine/test/unittest/scripts/run.py}"

    if [ -f "$runner" ]; then
        printf '%s\n' "$runner"
        return 0
    fi

    return 1
}

require_ace_unittest_runner() {
    local runner=""

    if ! runner="$(resolve_ace_unittest_runner)"; then
        err "Missing ace_engine Linux unittest runner: ${OHOS_ACE_UNITTEST_RUNNER:-foundation/arkui/ace_engine/test/unittest/scripts/run.py}"
        exit 1
    fi

    printf '%s\n' "$runner"
}

resolve_developer_test_runner() {
    local runner="${OHOS_DEVELOPER_TEST_RUNNER:-}"
    local framework_dir="${OHOS_DEVELOPER_TEST_DIR:-test/testfwk/developer_test}"
    local candidate=""

    if [ -n "$runner" ] && [ -f "$runner" ]; then
        printf '%s\n' "$runner"
        return 0
    fi

    if [ -d "$framework_dir" ] && [ -f "$framework_dir/start.sh" ]; then
        candidate="$(cd "$framework_dir" && pwd)/start.sh"
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

require_developer_test_runner() {
    local runner=""

    if ! runner="$(resolve_developer_test_runner)"; then
        err "Missing developer_test runner: ${OHOS_DEVELOPER_TEST_RUNNER:-${OHOS_DEVELOPER_TEST_DIR}/start.sh}"
        exit 1
    fi

    printf '%s\n' "$runner"
}

developer_test_latest_summary_xml() {
    local runner_path="${1:-}"
    local framework_root=""

    if [ -n "${OHOS_DEVELOPER_TEST_LATEST_SUMMARY:-}" ]; then
        printf '%s\n' "${OHOS_DEVELOPER_TEST_LATEST_SUMMARY}"
        return 0
    fi

    [ -n "$runner_path" ] || return 1
    framework_root="$(cd "$(dirname "$runner_path")" && pwd)"
    printf '%s\n' "${framework_root}/reports/latest/summary_report.xml"
}

print_developer_test_summary() {
    local summary_xml="${1:-}"
    [ -n "$summary_xml" ] || return 1
    [ -f "$summary_xml" ] || return 1

    python3 - "$summary_xml" <<'PY'
import sys
from pathlib import Path
from xml.etree import ElementTree

summary_path = Path(sys.argv[1])
try:
    root = ElementTree.parse(summary_path).getroot()
except Exception:
    raise SystemExit(1)

tests = int(root.attrib.get("tests", 0) or 0)
failures = int(root.attrib.get("failures", 0) or 0)
errors = int(root.attrib.get("errors", 0) or 0)
skipped = int(root.attrib.get("skipped", 0) or 0)
passed = max(tests - failures - errors - skipped, 0)

print("Framework Summary")
print(f"  tests={tests}")
print(f"  passed={passed}")
print(f"  failures={failures}")
print(f"  errors={errors}")
print(f"  skipped={skipped}")
print(f"  summary_xml={summary_path}")
PY
}

cmd_run_ut() {
    require_ohos_repo

    local target="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$target" in
        help|--help|-h|"")
            print_help_run
            return 0
            ;;
    esac

    local runner=""
    runner="$(require_ace_unittest_runner)"

    case "$target" in
        ace_engine_capi)
            info "Running ace_engine Linux CAPI unit tests via ${runner} --path C-API-Main $*"
            ohos_run_foreground python3 "$runner" --path C-API-Main "$@"
            ;;
        ace_engine_linux_unittest)
            info "Running all ace_engine Linux-host unit tests via ${runner} $*"
            ohos_run_foreground python3 "$runner" "$@"
            ;;
        *)
            err "run ut: unknown test alias: $target"
            print_help_run
            exit 1
            ;;
    esac
}

cmd_run() {
    local subcmd="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$subcmd" in
        help|--help|-h|"")
            print_help_run
            ;;
        ut)
            cmd_run_ut "$@"
            ;;
        *)
            err "run: unknown subcommand: $subcmd"
            print_help_run
            exit 1
            ;;
    esac
}

shell_join_command() {
    local rendered=""
    local arg=""
    for arg in "$@"; do
        printf -v rendered '%s%q ' "$rendered" "$arg"
    done
    printf '%s\n' "${rendered% }"
}

discover_self_test_component_json() {
    local query="${1:-.}"

    python3 - "$(pwd)" "$query" <<'PY'
import json
import os
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
query = sys.argv[2]
cwd = Path.cwd().resolve()
skip_dirs = {
    ".git",
    ".repo",
    ".scratchpad",
    ".runtime",
    ".qwen",
    "__pycache__",
    "arkui-xts-selector",
    "gitee_util",
    "node_modules",
    "out",
    "prebuilts",
}


def read_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(repo_root))
    except Exception:
        return str(path)


def iter_bundle_paths():
    for dirpath, dirnames, filenames in os.walk(repo_root):
        dirnames[:] = [name for name in dirnames if name not in skip_dirs]
        if "bundle.json" in filenames:
            yield Path(dirpath) / "bundle.json"


def collect_summary(bundle_path: Path) -> dict:
    data = read_json(bundle_path)
    component = data.get("component") or {}
    build = component.get("build") or {}
    raw_tests = build.get("test") or []
    tests = []
    for item in raw_tests:
        if isinstance(item, str):
            tests.append(item)
            continue
        if not isinstance(item, dict):
            continue
        for key in ("name", "target", "label"):
            value = item.get(key)
            if isinstance(value, str) and value:
                tests.append(value)
                break

    unique_tests = []
    seen_tests = set()
    framework_modules = []
    seen_modules = set()
    for label in tests:
        if label in seen_tests:
            continue
        seen_tests.add(label)
        unique_tests.append(label)
        module_name = label.rsplit(":", 1)[-1].strip() if ":" in label else ""
        if module_name and module_name not in seen_modules:
            seen_modules.add(module_name)
            framework_modules.append(module_name)

    candidates = []
    seen_candidates = set()
    test_root = bundle_path.parent / "test"
    if test_root.is_dir():
        for config_path in sorted(test_root.rglob("config.json")):
            try:
                cfg = read_json(config_path)
            except Exception:
                continue
            app = cfg.get("app") or {}
            module = cfg.get("module") or {}
            distro = module.get("distro") or {}
            bundle_name = app.get("bundleName") or cfg.get("bundleName") or ""
            module_name = distro.get("moduleName") or module.get("moduleName") or module.get("name") or "entry"
            if not bundle_name:
                continue
            key = (bundle_name, module_name)
            if key in seen_candidates:
                continue
            seen_candidates.add(key)
            candidates.append(
                {
                    "bundle_name": bundle_name,
                    "module_name": module_name,
                    "config_rel": rel(config_path),
                }
            )

    return {
        "component_name": component.get("name") or data.get("name") or bundle_path.parent.name,
        "component_subsystem": component.get("subsystem") or "",
        "relative_root": rel(bundle_path.parent),
        "bundle_json_rel": rel(bundle_path),
        "test_labels": unique_tests,
        "framework_modules": framework_modules,
        "aa_candidates": candidates,
    }


def resolve_from_path(raw_query: str):
    candidates = []
    raw_path = Path(raw_query)
    if raw_path.is_absolute():
        candidates.append(raw_path.resolve())
    else:
        candidates.append((cwd / raw_path).resolve())
        candidates.append((repo_root / raw_path).resolve())

    repo_boundary = repo_root.resolve()
    for candidate in candidates:
        if not candidate.exists():
            continue
        current = candidate if candidate.is_dir() else candidate.parent
        while True:
            try:
                current.relative_to(repo_boundary)
            except ValueError:
                break
            bundle_path = current / "bundle.json"
            if bundle_path.is_file():
                return collect_summary(bundle_path)
            if current == repo_boundary or current.parent == current:
                break
            current = current.parent
    return None


if query == "__ALL__":
    components = []
    for bundle_path in iter_bundle_paths():
        try:
            summary = collect_summary(bundle_path)
        except Exception:
            continue
        if summary["test_labels"]:
            components.append(summary)
    components.sort(key=lambda item: (item["component_name"], item["relative_root"]))
    print(json.dumps({"components": components}, ensure_ascii=False))
    raise SystemExit(0)

summary = resolve_from_path(query)
if summary is not None:
    print(json.dumps(summary, ensure_ascii=False))
    raise SystemExit(0)

matches = []
for bundle_path in iter_bundle_paths():
    try:
        data = read_json(bundle_path)
    except Exception:
        continue
    component = data.get("component") or {}
    component_name = component.get("name") or data.get("name") or ""
    relative_root = rel(bundle_path.parent)
    bundle_json_rel = rel(bundle_path)
    if query not in {component_name, relative_root, bundle_json_rel}:
        continue
    matches.append(collect_summary(bundle_path))

if not matches:
    print(
        f"Could not resolve a component with self-test metadata from query: {query}",
        file=sys.stderr,
    )
    raise SystemExit(1)

if len(matches) > 1:
    print(
        f"Query is ambiguous for self-test discovery: {query}",
        file=sys.stderr,
    )
    for item in matches:
        print(
            f"  - {item['component_name']} ({item['relative_root']})",
            file=sys.stderr,
        )
    raise SystemExit(2)

print(json.dumps(matches[0], ensure_ascii=False))
PY
}

print_self_test_discovery_summary() {
    local summary_json="${1:-}"
    SELF_TEST_SUMMARY_JSON="$summary_json" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["SELF_TEST_SUMMARY_JSON"])

if "components" in data:
    components = data.get("components") or []
    print(f"Discovered {len(components)} components with declared self-tests:")
    for item in components:
        print(
            "  - "
            f"{item.get('component_name')}  "
            f"root={item.get('relative_root')}  "
            f"declared={len(item.get('test_labels') or [])}  "
            f"bundle_backed={len(item.get('aa_candidates') or [])}"
        )
    sys.exit(0)

print(f"Component: {data.get('component_name')}")
component_subsystem = str(data.get("component_subsystem") or "").strip()
if component_subsystem:
    print(f"Subsystem: {component_subsystem}")
print(f"Root: {data.get('relative_root')}")
print(f"bundle.json: {data.get('bundle_json_rel')}")
print("")
labels = data.get("test_labels") or []
print(f"Declared self-test targets ({len(labels)}):")
if labels:
    for label in labels:
        print(f"  - {label}")
else:
    print("  - none")

framework_modules = data.get("framework_modules") or []
print("")
if framework_modules:
    print(f"developer_test modules ({len(framework_modules)}):")
    for item in framework_modules:
        print(f"  - {item}")
else:
    print("developer_test modules: not derived from bundle.json labels")

print("")
candidates = data.get("aa_candidates") or []
if candidates:
    print(f"Bundle-backed aa test candidates ({len(candidates)}):")
    for item in candidates:
        print(
            "  - "
            f"{item.get('bundle_name')} / {item.get('module_name')}  "
            f"({item.get('config_rel')})"
        )
else:
    print("Bundle-backed aa test candidates: none found")
    if labels:
        print("  This component declares self-tests, but no bundle-backed config.json was found under its test tree.")
        print("  Automatic `aa test` execution cannot be derived from bundle.json alone.")
PY
}

resolve_self_test_bundle_candidate() {
    local summary_json="${1:-}"
    SELF_TEST_SUMMARY_JSON="$summary_json" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["SELF_TEST_SUMMARY_JSON"])
candidates = data.get("aa_candidates") or []

if not candidates:
    component_name = data.get("component_name") or "<unknown>"
    print(
        f"Component '{component_name}' does not expose bundle-backed self-test metadata for automatic `aa test`.",
        file=sys.stderr,
    )
    print(
        "Run `ohos test discover <component>` to inspect declared test targets, or pass explicit `--bundle` / `--module`.",
        file=sys.stderr,
    )
    raise SystemExit(2)

if len(candidates) > 1:
    component_name = data.get("component_name") or "<unknown>"
    print(
        f"Component '{component_name}' has multiple bundle-backed self-test candidates; choose one explicitly with `--bundle` / `--module`:",
        file=sys.stderr,
    )
    for item in candidates:
        print(
            "  - "
            f"{item.get('bundle_name')} / {item.get('module_name')}  "
            f"({item.get('config_rel')})",
            file=sys.stderr,
        )
    raise SystemExit(3)

item = candidates[0]
print(
    "\t".join(
        [
            item.get("bundle_name") or "",
            item.get("module_name") or "entry",
            item.get("config_rel") or "",
        ]
    )
)
PY
}

resolve_self_test_framework_candidate() {
    local summary_json="${1:-}"
    SELF_TEST_SUMMARY_JSON="$summary_json" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["SELF_TEST_SUMMARY_JSON"])
component_name = str(data.get("component_name") or "").strip()
component_subsystem = str(data.get("component_subsystem") or "").strip()
framework_modules = [str(item).strip() for item in data.get("framework_modules") or [] if str(item).strip()]
default_module = framework_modules[0] if len(framework_modules) == 1 else ""
print("\t".join([component_name, component_subsystem, default_module]))
PY
}

cmd_test_discover() {
    require_ohos_repo

    local query="."
    if [ $# -gt 0 ]; then
        query="$1"
        shift
    fi
    if [ $# -gt 0 ]; then
        err "test discover: unexpected extra arguments: $*"
        exit 1
    fi

    local summary_json=""
    if [ "$query" = "--all" ]; then
        summary_json="$(discover_self_test_component_json "__ALL__")" || exit $?
    else
        summary_json="$(discover_self_test_component_json "$query")" || exit $?
    fi

    print_self_test_discovery_summary "$summary_json"
}

cmd_test_self_test() {
    require_ohos_repo

    local query=""
    local bundle_name=""
    local module_name=""
    local framework_mode="auto"
    local part_name=""
    local subsystem_name=""
    local suite_name=""
    local case_name=""
    local productform="${OHOS_DEVELOPER_TEST_PRODUCTFORM:-phone}"
    local coverage=false
    local run_all=false
    local repeat_count=0
    local device=""
    local hdc_endpoint="${XTS_HDC_ENDPOINT:-}"
    local explicit_hdc_path=""
    local dry_run=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --bundle)
                [ $# -ge 2 ] || { err "test self-test: --bundle requires a value"; exit 1; }
                bundle_name="$2"
                shift 2
                ;;
            --module)
                [ $# -ge 2 ] || { err "test self-test: --module requires a value"; exit 1; }
                module_name="$2"
                shift 2
                ;;
            --framework)
                [ $# -ge 2 ] || { err "test self-test: --framework requires a value"; exit 1; }
                framework_mode="$2"
                shift 2
                ;;
            --part)
                [ $# -ge 2 ] || { err "test self-test: --part requires a value"; exit 1; }
                part_name="$2"
                shift 2
                ;;
            --subsystem)
                [ $# -ge 2 ] || { err "test self-test: --subsystem requires a value"; exit 1; }
                subsystem_name="$2"
                shift 2
                ;;
            --suite)
                [ $# -ge 2 ] || { err "test self-test: --suite requires a value"; exit 1; }
                suite_name="$2"
                shift 2
                ;;
            --case)
                [ $# -ge 2 ] || { err "test self-test: --case requires a value"; exit 1; }
                case_name="$2"
                shift 2
                ;;
            --productform)
                [ $# -ge 2 ] || { err "test self-test: --productform requires a value"; exit 1; }
                productform="$2"
                shift 2
                ;;
            --coverage)
                coverage=true
                shift
                ;;
            --repeat)
                [ $# -ge 2 ] || { err "test self-test: --repeat requires a value"; exit 1; }
                case "$2" in
                    ''|*[!0-9]*)
                        err "test self-test: --repeat expects a non-negative integer"
                        exit 1
                        ;;
                esac
                repeat_count="$2"
                shift 2
                ;;
            --device|-d)
                [ $# -ge 2 ] || { err "test self-test: --device requires a value"; exit 1; }
                device="$2"
                shift 2
                ;;
            --hdc-path)
                [ $# -ge 2 ] || { err "test self-test: --hdc-path requires a value"; exit 1; }
                explicit_hdc_path="$2"
                shift 2
                ;;
            --hdc-endpoint)
                [ $# -ge 2 ] || { err "test self-test: --hdc-endpoint requires a value"; exit 1; }
                hdc_endpoint="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            help|--help|-h)
                print_help_test
                return 0
                ;;
            --all)
                run_all=true
                shift
                ;;
            auto|developer_test)
                if [ -z "$query" ] && [ -z "$bundle_name" ] && [ "$framework_mode" = "auto" ]; then
                    framework_mode="$1"
                    shift
                    continue
                fi
                if [ -n "$query" ]; then
                    err "test self-test: unexpected extra positional argument: $1"
                    exit 1
                fi
                query="$1"
                shift
                ;;
            bundle)
                if [ -z "$query" ] && [ -z "$bundle_name" ] && [ "$framework_mode" = "auto" ]; then
                    framework_mode="bundle"
                    shift
                    continue
                fi
                if [ -n "$query" ]; then
                    err "test self-test: unexpected extra positional argument: $1"
                    exit 1
                fi
                query="$1"
                shift
                ;;
            --*)
                err "test self-test: unknown option: $1"
                exit 1
                ;;
            *)
                if [ -n "$query" ]; then
                    err "test self-test: unexpected extra positional argument: $1"
                    exit 1
                fi
                query="$1"
                shift
                ;;
        esac
    done

    case "$framework_mode" in
        auto|bundle|developer_test) ;;
        *)
            err "test self-test: unsupported --framework value: $framework_mode"
            exit 1
            ;;
    esac

    if [ "$run_all" = "true" ] && [ -n "$bundle_name" ]; then
        err "test self-test: --all cannot be combined with --bundle"
        exit 1
    fi

    local summary_json=""
    if [ -n "$query" ]; then
        summary_json="$(discover_self_test_component_json "$query")" || exit $?
    fi

    local prefers_framework=false
    if [ "$run_all" = "true" ] || [ -n "$suite_name" ] || [ -n "$case_name" ] || [ "$coverage" = "true" ] || [ "$repeat_count" -gt 0 ] || [ -n "$part_name" ] || [ -n "$subsystem_name" ]; then
        prefers_framework=true
    fi

    local bundle_candidate=""
    if [ -z "$bundle_name" ] && [ -n "$summary_json" ]; then
        bundle_candidate="$(resolve_self_test_bundle_candidate "$summary_json" 2>/dev/null || true)"
    fi

    if [ "$framework_mode" = "auto" ]; then
        if [ "$run_all" = "true" ]; then
            framework_mode="developer_test"
        elif [ -n "$bundle_name" ]; then
            framework_mode="bundle"
        elif [ "$prefers_framework" = "true" ]; then
            framework_mode="developer_test"
        elif [ -n "$bundle_candidate" ]; then
            framework_mode="bundle"
        else
            framework_mode="developer_test"
        fi
    fi

    if [ "$framework_mode" = "bundle" ]; then
        if [ "$run_all" = "true" ] || [ "$coverage" = "true" ] || [ "$repeat_count" -gt 0 ] || [ -n "$suite_name" ] || [ -n "$case_name" ] || [ -n "$part_name" ] || [ -n "$subsystem_name" ]; then
            err "test self-test: --all/--coverage/--repeat/--suite/--case/--part/--subsystem are supported only with --framework developer_test"
            exit 1
        fi
        local discovery_note=""
        if [ -z "$bundle_name" ]; then
            [ -n "$query" ] || {
                err "test self-test: provide a component/path or explicit --bundle [--module]"
                exit 1
            }
            if [ -z "$bundle_candidate" ]; then
                resolve_self_test_bundle_candidate "$summary_json" >/dev/null
                exit $?
            fi
            IFS=$'\t' read -r bundle_name module_name discovery_note <<<"$bundle_candidate"
            info "Auto-discovered bundle-backed self-test metadata from ${discovery_note}"
        fi

        module_name="${module_name:-entry}"

        local resolved_hdc_path=""
        if [ -n "$explicit_hdc_path" ]; then
            resolved_hdc_path="$explicit_hdc_path"
        elif resolved_hdc_path="$(resolve_preferred_hdc_path 2>/dev/null)"; then
            :
        else
            resolved_hdc_path="$(command -v hdc 2>/dev/null || true)"
        fi

        local hdc_cmd=()
        if [ -n "$resolved_hdc_path" ]; then
            hdc_cmd+=("$resolved_hdc_path")
        else
            hdc_cmd+=("hdc")
        fi
        if [ -n "$hdc_endpoint" ]; then
            hdc_cmd+=("-s" "$hdc_endpoint")
        fi
        if [ -n "$device" ]; then
            hdc_cmd+=("-t" "$device")
        fi
        hdc_cmd+=(shell aa test -b "$bundle_name" -m "$module_name" -s unittest OpenHarmonyTestRunner)

        local env_cmd=()
        env_cmd+=(env)
        env_cmd+=("PATH=$(prepend_hdc_bin_dir_to_path "${resolved_hdc_path:-}")")
        local hdc_lib_dir=""
        if hdc_lib_dir="$(detect_hdc_library_path "${resolved_hdc_path:-}" 2>/dev/null)"; then
            env_cmd+=("LD_LIBRARY_PATH=${hdc_lib_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}")
        fi

        if [ "$dry_run" = "true" ]; then
            info "Self-test command:"
            shell_join_command "${env_cmd[@]}" "${hdc_cmd[@]}"
            return 0
        fi

        info "Running developer self-test bundle '${bundle_name}' module '${module_name}'"
        ohos_run_foreground "${env_cmd[@]}" "${hdc_cmd[@]}"
        return 0
    fi

    if [ -n "$bundle_name" ]; then
        err "test self-test: --bundle is only valid with bundle mode"
        exit 1
    fi

    local runner=""
    if ! runner="$(resolve_developer_test_runner)"; then
        if [ -n "$summary_json" ] && [ -z "$bundle_candidate" ]; then
            err "Component '${part_name:-${query:-unknown}}' does not expose bundle-backed self-test metadata for automatic \`aa test\`."
            err "Run \`ohos test discover <component>\` to inspect declared test targets or provide an explicit developer_test runner."
        fi
        err "Missing developer_test runner: ${OHOS_DEVELOPER_TEST_RUNNER:-${OHOS_DEVELOPER_TEST_DIR}/start.sh}"
        exit 1
    fi

    if [ "$run_all" = "false" ] && [ -z "$part_name" ] && [ -z "$query" ]; then
        err "test self-test: provide a component/path, --part, or --all for developer_test mode"
        exit 1
    fi

    if [ -n "$summary_json" ]; then
        local framework_candidate=""
        framework_candidate="$(resolve_self_test_framework_candidate "$summary_json")"
        local discovered_part=""
        local discovered_subsystem=""
        local discovered_module=""
        IFS=$'\t' read -r discovered_part discovered_subsystem discovered_module <<<"$framework_candidate"
        part_name="${part_name:-$discovered_part}"
        subsystem_name="${subsystem_name:-$discovered_subsystem}"
        module_name="${module_name:-$discovered_module}"
    fi

    local framework_run_args=()
    framework_run_args+=(-p "$productform" -t UT)
    if [ -n "$subsystem_name" ]; then
        framework_run_args+=(-ss "$subsystem_name")
    fi
    if [ "$run_all" != "true" ] && [ -n "$part_name" ]; then
        framework_run_args+=(-tp "$part_name")
    fi
    if [ -n "$module_name" ]; then
        framework_run_args+=(-tm "$module_name")
    fi
    if [ -n "$suite_name" ]; then
        framework_run_args+=(-ts "$suite_name")
    fi
    if [ -n "$case_name" ]; then
        framework_run_args+=(-tc "$case_name")
    fi
    if [ "$coverage" = "true" ]; then
        framework_run_args+=(-cov)
    fi
    if [ "$repeat_count" -gt 0 ]; then
        framework_run_args+=(--repeat "$repeat_count")
    fi

    local summary_xml=""
    summary_xml="$(developer_test_latest_summary_xml "$runner" 2>/dev/null || true)"

    info "Running developer self-test via developer_test framework"
    local use_tdd_runner=false
    if [ -n "$device" ] || [ -n "$explicit_hdc_path" ] || [ -n "$hdc_endpoint" ]; then
        use_tdd_runner=true
    fi
    if [ "$use_tdd_runner" = "true" ]; then
        local resolved_hdc_path=""
        if [ -n "$explicit_hdc_path" ]; then
            resolved_hdc_path="$explicit_hdc_path"
        elif resolved_hdc_path="$(resolve_preferred_hdc_path 2>/dev/null)"; then
            :
        else
            resolved_hdc_path="$(command -v hdc 2>/dev/null || true)"
        fi
        local tdd_runner_args=()
        tdd_runner_args+=(--repo-root "$(pwd)")
        tdd_runner_args+=(--runner-path "$runner")
        if [ -n "$resolved_hdc_path" ]; then
            tdd_runner_args+=(--hdc-path "$resolved_hdc_path")
        fi
        if [ -n "$hdc_endpoint" ]; then
            tdd_runner_args+=(--hdc-endpoint "$hdc_endpoint")
        fi
        if [ -n "$device" ]; then
            tdd_runner_args+=(--device "$device")
        fi
        if [ "$dry_run" = "true" ]; then
            tdd_runner_args+=(--dry-run)
        fi
        tdd_runner_args+=(--framework-args "${framework_run_args[@]}")
        run_tdd_runner_tool "${tdd_runner_args[@]}"
        return $?
    fi

    local framework_cmd=()
    framework_cmd+=("$runner" run "${framework_run_args[@]}")
    if [ "$dry_run" = "true" ]; then
        info "Self-test command:"
        shell_join_command "${framework_cmd[@]}"
        if [ -n "$summary_xml" ]; then
            info "Expected summary XML: ${summary_xml}"
        fi
        return 0
    fi
    ohos_run_foreground "${framework_cmd[@]}"
    if [ -n "$summary_xml" ] && [ -f "$summary_xml" ]; then
        print_developer_test_summary "$summary_xml" || true
    else
        warn "developer_test finished, but no summary_report.xml was found at: ${summary_xml:-<unknown>}"
    fi
}

cmd_test() {
    local subcmd="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$subcmd" in
        help|--help|-h|"")
            print_help_test
            ;;
        discover)
            cmd_test_discover "$@"
            ;;
        self-test)
            cmd_test_self_test "$@"
            ;;
        *)
            err "test: unknown subcommand: $subcmd"
            print_help_test
            exit 1
            ;;
    esac
}

cmd_manifest_save() {
    require_ohos_repo
    local name="${1:?Usage: ohos manifest-save <name>}"
    repo manifest -r -o "${name}.xml"
    info "Manifest saved to ${name}.xml"
}

cmd_products() {
    require_ohos_repo
    run_ohos_helper products
}

cmd_parts() {
    require_ohos_repo
    local product="${1:?Usage: ohos parts <product-name>}"
    run_ohos_helper parts "$product"
}

cmd_info() {
    require_ohos_repo
    local info_args=("$@")
    if [ ${#info_args[@]} -gt 0 ] && [ "${info_args[0]}" = "file" ]; then
        run_ohos_helper file "${info_args[@]:1}"
        return
    fi
    if [ ${#info_args[@]} -gt 0 ] && [[ "${info_args[0]}" != --* ]] && [ -f "${info_args[0]}" ]; then
        run_ohos_helper file "${info_args[@]}"
        return
    fi
    run_ohos_helper info "${info_args[@]}"
}

cmd_file() {
    require_ohos_repo
    run_ohos_helper file "$@"
}

cmd_params() {
    run_ohos_helper params
}

cmd_npmrc() {
    local requested_profile="${1:-mirror}"
    local profile=""
    local sync_profile=""
    local ohpm_registry=""
    local koala_registry=""

    case "$requested_profile" in
        help|--help|-h)
            print_help_npmrc
            return 0
            ;;
    esac

    if ! profile="$(normalize_npmrc_profile "$requested_profile" 2>/dev/null)"; then
        err "Unsupported npmrc profile: $requested_profile"
        print_help_npmrc
        return 1
    fi
    sync_profile="$(sync_npmrc_profile)" || return 1
    ohpm_registry="$(registry_for_npmrc_profile "$profile" ohpm)"
    koala_registry="$(registry_for_npmrc_profile "$profile" koala)"

    echo -e "${BOLD}Generated .npmrc profile:${NC} ${profile}"
    echo ""
    generate_npmrc "$profile"
    echo ""
    echo -e "${BOLD}Related registries:${NC}"
    echo "  ohpm registry       : $ohpm_registry"
    echo "  ohpm publish        : $OHPM_PUBLISH_REGISTRY"
    echo "  private scopes      : $koala_registry"
    echo ""
    echo -e "${CYAN}The script currently uses the '${sync_profile}' profile during sync/build.${NC}"
    echo -e "${CYAN}Override it in ${OHOS_CONF} with OHOS_SYNC_NPMRC_PROFILE=mirror|original.${NC}"
    echo -e "${CYAN}The generated ~/.npmrc is temporary during sync/build and is restored afterward.${NC}"
}

cmd_config() {
    echo -e "${BOLD}Configuration:${NC} ${OHOS_CONF}"
    echo ""
    echo -e "${BOLD}Mirror URLs:${NC}"
    echo "  npm registry        : $NPM_REGISTRY"
    echo "  @ohos npm           : $OHOS_NPM_REGISTRY"
    echo "  ohpm                : $OHPM_REGISTRY"
    echo "  pypi                : $PYPI_URL"
    echo "  koala-npm           : $KOALA_NPM_REGISTRY"
    echo ""
    echo -e "${BOLD}Repo:${NC}"
    echo "  manifest URL        : $REPO_MANIFEST_URL"
    echo "  reference           : $REPO_REFERENCE"
    echo "  LFS mirror          : $LFS_MIRROR (legacy/shared mirror; sync uses repo-local storage)"
    echo "  init branch         : $INIT_BRANCH"
    echo "  repo install URL    : $REPO_INSTALL_URL"
    echo ""
    echo -e "${BOLD}Node / prebuilts:${NC}"
    echo "  nvm install URL     : $NVM_INSTALL_URL"
    echo "  shared prebuilts    : $SHARED_PREBUILTS_DIR"
    echo "  sibling link name   : $PREBUILTS_SYMLINK_NAME"
    echo ""
    echo -e "${BOLD}Proxy (fallback):${NC}"
    if [ -n "$OHOS_PROXY" ]; then
        echo "  proxy               : $OHOS_PROXY"
        echo "  connect timeout     : ${OHOS_PROXY_CONNECT_TIMEOUT}s"
        echo "  no_proxy            : $OHOS_NO_PROXY"
    else
        echo "  (disabled)"
    fi
    echo ""
    echo -e "${BOLD}Parallelism:${NC}"
    echo "  sync jobs           : $REPO_SYNC_JOBS"
    echo "  lfs jobs            : $LFS_JOBS"
    echo "  reset jobs          : $RESET_JOBS"
    echo "  gc jobs             : $GC_JOBS"
    echo ""
    echo -e "${BOLD}Reset:${NC}"
    echo "  lfs prune on reset  : $RESET_LFS_PRUNE"
    echo "  git gc on reset     : $RESET_GC"
    echo "  remove dirs         : $RESET_RM_DIRS"
    echo ""
    echo -e "${BOLD}Build aliases:${NC}"
    echo "  sdk                 : $BUILD_SDK"
    echo "  sdk-linux           : $BUILD_SDK_LINUX"
    echo "  sdk-win             : $BUILD_SDK_WIN"
    echo "  rk3568              : $BUILD_RK3568"
    echo ""
    echo -e "${BOLD}ccache:${NC}"
    echo "  cache dir           : $CCACHE_DIR"
    echo "  max size            : $CCACHE_MAXSIZE"
    echo ""
    echo -e "${BOLD}Download roots:${NC}"
    echo "  shared root         : $OHOS_SHARED_DOWNLOAD_ROOT"
    echo "  xts tests           : $XTS_DOWNLOAD_ROOT"
    echo "  sdk                 : $SDK_DOWNLOAD_ROOT"
    echo "  firmware            : $FIRMWARE_DOWNLOAD_ROOT"
    echo ""
    echo -e "${BOLD}Vendored tools:${NC}"
    echo "  gitee util runner   : $GITEE_UTIL_RUNNER"
    echo "  gitee util repo     : $GITEE_UTIL_DIR"
    echo "  xts selector repo   : $ARKUI_XTS_SELECTOR_DIR"
}

feedback_repo_url() {
    git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true
}

feedback_clone_command() {
    local repo_url
    repo_url="$(feedback_repo_url)"
    if [ -n "$repo_url" ]; then
        printf 'git clone --recurse-submodules %s\n' "$repo_url"
    else
        printf 'git clone --recurse-submodules <repo-url>\n'
    fi
}

feedback_upstream_command() {
    local repo_url
    repo_url="$(feedback_repo_url)"
    if [ -n "$repo_url" ]; then
        printf 'git remote add upstream %s\n' "$repo_url"
    else
        printf 'git remote add upstream <repo-url>\n'
    fi
}

feedback_slug() {
    local raw="${1:-feedback}"
    local normalized
    normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')"
    if [ -z "$normalized" ]; then
        normalized="feedback"
    fi
    printf '%s\n' "$normalized"
}

cmd_feedback() {
    local default_author
    local author
    local topic
    local feedback_body=""
    local line
    local stamp
    local host_name
    local repo_url
    local output_file

    default_author="$(id -un 2>/dev/null || printf '%s' "${USER:-user}")"
    repo_url="$(feedback_repo_url)"

    echo -e "${BOLD}Project Feedback${NC}"
    echo ""
    echo "Current script directory:"
    echo "  $SCRIPT_DIR"
    echo ""
    echo "Repository to clone or fork:"
    if [ -n "$repo_url" ]; then
        echo "  $repo_url"
    else
        echo "  <remote origin is not configured>"
    fi
    echo ""
    echo "Clone command:"
    echo "  $(feedback_clone_command)"
    echo ""
    echo "Fork + PR flow:"
    echo "  1. Fork the repository in GitHub/GitCode."
    echo "  2. Clone your fork."
    echo "  3. Add upstream:"
    echo "     $(feedback_upstream_command)"
    echo "  4. Create a branch, commit your change, push the branch."
    echo "  5. Open a PR from your fork branch to upstream."
    echo ""
    echo "You can now save a project wish or proposal."
    echo "Finish the feedback text with a single '.' on a new line."
    echo ""

    read -r -p "Author [${default_author}]: " author
    author="${author:-$default_author}"
    read -r -p "Topic [general]: " topic
    topic="${topic:-general}"

    while IFS= read -r line; do
        if [ "$line" = "." ]; then
            break
        fi
        feedback_body+="${line}"$'\n'
    done
    feedback_body="${feedback_body%$'\n'}"

    if [ -z "${feedback_body//[[:space:]]/}" ]; then
        warn "Empty feedback; nothing was saved."
        return 1
    fi

    mkdir -p "$OHOS_FEEDBACK_DIR"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    host_name="$(hostname 2>/dev/null || uname -n)"
    output_file="${OHOS_FEEDBACK_DIR}/${stamp}__$(feedback_slug "$author").md"

    cat > "$output_file" <<EOF
# Project Feedback

Author: $author
Topic: $topic
Created At (UTC): $stamp
Host: $host_name
Working Directory: $(pwd)
Script Directory: $SCRIPT_DIR
Repository URL: ${repo_url:-<not configured>}
Suggested Clone: $(feedback_clone_command)
Suggested Upstream: $(feedback_upstream_command)

## Feedback

$feedback_body
EOF

    info "Feedback saved: $output_file"
}

cmd_device() {
    run_device_tool "$@"
}

run_pr_comments_viewer() {
    local input_path="$1"
    if [ ! -f "$OHOS_PR_COMMENTS_VIEWER" ]; then
        cat "$input_path"
        return 0
    fi
    ohos_run_foreground python3 "$OHOS_PR_COMMENTS_VIEWER" "$input_path"
}

cmd_pr() {
    require_tool_repo "gitee_util" "$GITEE_UTIL_DIR"
    if [ ! -f "$GITEE_UTIL_RUNNER" ]; then
        err "Missing gitee util runner: $GITEE_UTIL_RUNNER"
        exit 1
    fi

    local provider_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --provider)
                [ $# -ge 2 ] || { err "pr: missing value for $1"; exit 1; }
                provider_args+=("$1" "$2")
                shift 2
                ;;
            --provider=*)
                provider_args+=("$1")
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    local subcmd="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    if [ $# -gt 0 ] && [[ "${1:-}" =~ ^https?://[^[:space:]]+/(pull|pulls|merge_requests)/[0-9]+/?$ ]]; then
        if ! has_long_flag "--url" "$@"; then
            case "$subcmd" in
                show-pr|show-comments)
                    set -- --url "$1" "${@:2}"
                    ;;
            esac
        fi
    fi

    case "$subcmd" in
        help|--help|-h|"")
            print_help_pr
            ;;
        show-comments)
            ensure_gitee_util_runtime
            local comments_output=""
            local comments_rc=0
            comments_output="$(mktemp /tmp/ohos_pr_comments_XXXXXX.txt)"
            if "$GITEE_UTIL_PYTHON" "$GITEE_UTIL_RUNNER" "${provider_args[@]}" "$subcmd" "$@" >"$comments_output" 2>&1; then
                run_pr_comments_viewer "$comments_output"
                comments_rc=$?
            else
                comments_rc=$?
                cat "$comments_output" >&2
            fi
            rm -f "$comments_output"
            return "$comments_rc"
            ;;
        create-pr|create-issue|create-issue-pr|comment-pr|list-pr|show-pr)
            ensure_gitee_util_runtime
            ohos_run_foreground "$GITEE_UTIL_PYTHON" "$GITEE_UTIL_RUNNER" "${provider_args[@]}" "$subcmd" "$@"
            ;;
        *)
            err "pr: unknown subcommand: $subcmd"
            print_help_pr
            exit 1
            ;;
    esac
}

run_xts_selector() {
    require_tool_repo "arkui-xts-selector" "$ARKUI_XTS_SELECTOR_DIR"
    local xts_extra=()
    local xts_env=()
    local xts_repo_root=""
    local explicit_hdc_path=""
    local resolved_hdc_path=""
    local hdc_lib_dir=""
    local _gitcode_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/gitee_util/config.ini"

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

    if [ -f "$_gitcode_cfg" ]; then
        xts_extra+=(--git-host-config "$_gitcode_cfg")
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
    xts_env+=(ARKUI_XTS_SELECTOR_COMMAND_PREFIX="ohos xts")
    xts_env+=(ARKUI_XTS_SELECTOR_COMMAND_MODE="wrapper")
    xts_env+=(PATH="$(prepend_hdc_bin_dir_to_path "${resolved_hdc_path:-}")")
    if [ -n "${resolved_hdc_path:-}" ] && [ -f "${resolved_hdc_path}" ]; then
        xts_env+=(HDC_PATH="$resolved_hdc_path")
    fi
    if hdc_lib_dir="$(detect_hdc_library_path "${resolved_hdc_path:-${HDC_PATH:-}}" 2>/dev/null)"; then
        xts_env+=(ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH="$hdc_lib_dir")
        xts_env+=(LD_LIBRARY_PATH="$hdc_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
    fi
    ohos_run_foreground env "${xts_env[@]}" python3 -m arkui_xts_selector "${xts_extra[@]}" "$@"
}

run_xts_compare() {
    require_tool_repo "arkui-xts-selector" "$ARKUI_XTS_SELECTOR_DIR"
    ohos_run_foreground env PYTHONPATH="${ARKUI_XTS_SELECTOR_DIR}/src" python3 -m arkui_xts_selector.xts_compare "$@"
}

run_xts_stage() {
    require_tool_repo "arkui-xts-selector" "$ARKUI_XTS_SELECTOR_DIR"
    ohos_run_foreground env PYTHONPATH="${ARKUI_XTS_SELECTOR_DIR}/src" python3 -m arkui_xts_selector.xts_stage "$@"
}

run_xts_bridge_tool() {
    ohos_run_foreground python3 "$OHOS_XTS_BRIDGE_TOOL" "$@"
}

run_tdd_runner_tool() {
    if [ ! -f "$OHOS_TDD_RUNNER_TOOL" ]; then
        err "Missing TDD runner tool: $OHOS_TDD_RUNNER_TOOL"
        exit 1
    fi
    ohos_run_foreground env \
        PYTHONPATH="${ARKUI_XTS_SELECTOR_DIR}/src" \
        ARKUI_XTS_SELECTOR_DIR="${ARKUI_XTS_SELECTOR_DIR}" \
        python3 "$OHOS_TDD_RUNNER_TOOL" "$@"
}

run_device_tool() {
    if [ ! -f "$OHOS_DEVICE_TOOL" ]; then
        err "Missing device tool: $OHOS_DEVICE_TOOL"
        exit 1
    fi
    exec bash "$OHOS_DEVICE_TOOL" "$@"
}

run_ohos_helper() {
    ohos_run_foreground python3 "$OHOS_HELPER" "$@"
}

run_download_tool() {
    if [ ! -f "$OHOS_DOWNLOAD_TOOL" ]; then
        err "Missing download tool: $OHOS_DOWNLOAD_TOOL"
        exit 1
    fi
    exec bash "$OHOS_DOWNLOAD_TOOL" "$@"
}

xts_is_pr_url() {
    local value="${1:-}"
    [[ "$value" =~ ^https?://[^[:space:]]+/(pull|merge_requests)/[0-9]+/?$ ]]
}

xts_label_fragment() {
    local raw="${1:-selection}"
    local normalized
    normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')"
    if [ -z "$normalized" ]; then
        normalized="selection"
    fi
    printf '%s\n' "$normalized"
}

xts_default_run_label() {
    local user_name
    user_name="$(id -un 2>/dev/null || printf '%s' "${USER:-user}")"
    local base="selection"
    local args=("$@")
    local index=0
    while [ $index -lt ${#args[@]} ]; do
        case "${args[$index]}" in
            --pr-url|--pr-number)
                if [ $((index + 1)) -lt ${#args[@]} ]; then
                    local value="${args[$((index + 1))]}"
                    if [[ "$value" =~ ([0-9]+) ]]; then
                        base="mr-${BASH_REMATCH[1]}"
                    else
                        base="$value"
                    fi
                    break
                fi
                ;;
            --symbol-query)
                if [ $((index + 1)) -lt ${#args[@]} ]; then
                    base="symbol-${args[$((index + 1))]}"
                    break
                fi
                ;;
            --changed-file)
                if [ $((index + 1)) -lt ${#args[@]} ]; then
                    base="file-$(basename "${args[$((index + 1))]}")"
                    break
                fi
                ;;
        esac
        index=$((index + 1))
    done
    printf '%s__%s\n' "$(xts_label_fragment "$user_name")" "$(xts_label_fragment "$base")"
}

xts_resolve_server_host() {
    local value=""
    if value="$(get_long_flag_value "--server-host" "$@" 2>/dev/null)"; then
        printf '%s\n' "$value"
        return 0
    fi
    if [ -n "${OHOS_DEVICE_SERVER_HOST:-}" ]; then
        printf '%s\n' "${OHOS_DEVICE_SERVER_HOST}"
        return 0
    fi
    return 1
}

xts_resolve_server_user() {
    local value=""
    if value="$(get_long_flag_value "--server-user" "$@" 2>/dev/null)"; then
        printf '%s\n' "$value"
        return 0
    fi
    if [ -n "${OHOS_DEVICE_SERVER_USER:-}" ]; then
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
    return 1
}

run_xts_remote_command() {
    local subcmd="$1"
    local server_host="$2"
    local server_user="$3"
    shift 3 || true

    local target="$server_host"
    if [ -n "$server_user" ]; then
        target="${server_user}@${server_host}"
    fi

    local remote_payload=""
    local remote_command=""
    remote_payload="$(shell_join_command env OHOS_XTS_REMOTE_EXEC=1 bash "${OHOS_LAUNCH_DIR}/ohos.sh" xts "$subcmd" "$@")"
    remote_command="$(shell_join_command bash -lc "$remote_payload")"

    info "Delegating 'ohos xts ${subcmd}' to remote execution host: ${target}"
    ohos_run_foreground ssh "$target" "$remote_command"
}

cmd_download() {
    run_download_tool "$@"
}

cmd_admin_relocate() {
    local target_root=""
    local legacy_link="$OHOS_LAUNCH_DIR"
    local dry_run=false
    local assume_yes=false
    local current_real_root="$OHOS_REAL_DIR"
    local current_launch_root="$OHOS_LAUNCH_DIR"
    local target_root_abs=""
    local legacy_link_abs=""
    local target_parent=""
    local legacy_parent=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --target-root)
                [ $# -ge 2 ] || { err "admin relocate: missing value for $1"; exit 1; }
                target_root="$2"
                shift 2
                ;;
            --target-root=*)
                target_root="${1#--target-root=}"
                shift
                ;;
            --legacy-link)
                [ $# -ge 2 ] || { err "admin relocate: missing value for $1"; exit 1; }
                legacy_link="$2"
                shift 2
                ;;
            --legacy-link=*)
                legacy_link="${1#--legacy-link=}"
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --yes)
                assume_yes=true
                shift
                ;;
            --help|-h)
                print_help_admin
                return 0
                ;;
            *)
                err "admin relocate: unknown option $1"
                exit 1
                ;;
        esac
    done

    if [ -z "$target_root" ]; then
        err "admin relocate: --target-root is required"
        err "Example: ohos admin relocate --target-root /data/shared/common/projects/ohos-helper --dry-run"
        exit 1
    fi

    target_root_abs="$(resolve_absolute_path "$target_root")"
    legacy_link_abs="$(resolve_absolute_path "$legacy_link")"

    if [ "$target_root_abs" = "$current_real_root" ]; then
        err "admin relocate: target root is already current real root: $target_root_abs"
        exit 1
    fi
    if [[ "$target_root_abs" == "$current_real_root/"* ]]; then
        err "admin relocate: target root cannot be inside current real root"
        err "current_real_root=$current_real_root"
        err "target_root=$target_root_abs"
        exit 1
    fi

    target_parent="$(dirname "$target_root_abs")"
    legacy_parent="$(dirname "$legacy_link_abs")"

    if [ -e "$target_root_abs" ] || [ -L "$target_root_abs" ]; then
        err "admin relocate: target root already exists: $target_root_abs"
        exit 1
    fi
    if [ -e "$legacy_link_abs" ] || [ -L "$legacy_link_abs" ]; then
        if [ "$legacy_link_abs" != "$current_launch_root" ] && [ "$legacy_link_abs" != "$current_real_root" ]; then
            if [ -L "$legacy_link_abs" ]; then
                warn "admin relocate: legacy link path is an existing symlink and will be replaced: $legacy_link_abs"
            else
                err "admin relocate: legacy link path exists and is not the current project root: $legacy_link_abs"
                exit 1
            fi
        fi
    fi

    info "Relocation plan"
    echo "  current launch root : $current_launch_root"
    echo "  current real root   : $current_real_root"
    echo "  target real root    : $target_root_abs"
    echo "  legacy link path    : $legacy_link_abs"
    echo "  move command        : mv '$current_real_root' '$target_root_abs'"
    echo "  link command        : ln -s '$target_root_abs' '$legacy_link_abs'"

    if [ "$dry_run" = "true" ]; then
        info "Dry-run completed. No filesystem changes were made."
        return 0
    fi

    if [ "$assume_yes" != "true" ]; then
        if ! confirm_default_no "Proceed with relocation now? [y/N] "; then
            info "Aborted."
            return 0
        fi
    fi

    mkdir -p "$target_parent"
    if [ "$legacy_parent" != "$target_parent" ]; then
        mkdir -p "$legacy_parent"
    fi

    info "Moving project root: $current_real_root -> $target_root_abs"
    mv "$current_real_root" "$target_root_abs"

    if [ -L "$legacy_link_abs" ]; then
        rm -f "$legacy_link_abs"
    elif [ -e "$legacy_link_abs" ]; then
        err "Failed to create legacy symlink: path already exists after move: $legacy_link_abs"
        err "Rolling back: moving project back to $current_real_root"
        mv "$target_root_abs" "$current_real_root" || true
        exit 1
    fi

    if ! ln -s "$target_root_abs" "$legacy_link_abs"; then
        err "Failed to create legacy symlink: $legacy_link_abs -> $target_root_abs"
        err "Rolling back: moving project back to $current_real_root"
        mv "$target_root_abs" "$current_real_root" || true
        exit 1
    fi

    info "Relocation completed."
    info "Legacy path now points to: $legacy_link_abs -> $target_root_abs"
}

cmd_admin() {
    local subcmd="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$subcmd" in
        help|--help|-h|"")
            print_help_admin
            ;;
        relocate)
            cmd_admin_relocate "$@"
            ;;
        *)
            err "admin: unknown subcommand: $subcmd"
            print_help_admin
            exit 1
            ;;
    esac
}

cmd_xts() {
    local subcmd="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi
    local xts_args=("$@")
    local remote_server_host=""
    local remote_server_user=""

    if [ "${OHOS_XTS_REMOTE_EXEC:-0}" != "1" ] && [ "$subcmd" != "help" ] && [ "$subcmd" != "--help" ] && [ "$subcmd" != "-h" ]; then
        if remote_server_host="$(xts_resolve_server_host "${xts_args[@]}" 2>/dev/null)"; then
            remote_server_user="$(xts_resolve_server_user "${xts_args[@]}" 2>/dev/null || true)"
            run_xts_remote_command "$subcmd" "$remote_server_host" "$remote_server_user" "${xts_args[@]}"
            return $?
        fi
    fi

    case "$subcmd" in
        help|--help|-h|"")
            print_help_xts
            ;;
        select)
            local select_args=("$@")
            if [ ${#select_args[@]} -gt 0 ] && [[ "${select_args[0]}" != -* ]] && xts_is_pr_url "${select_args[0]}" \
                && ! has_long_flag "--pr-url" "${select_args[@]}" && ! has_long_flag "--pr-number" "${select_args[@]}"; then
                select_args=(--pr-url "${select_args[0]}" "${select_args[@]:1}")
            elif [ ${#select_args[@]} -gt 0 ] && [[ "${select_args[0]}" != -* ]] && [ -f "${select_args[0]}" ] \
                && ! has_long_flag "--changed-file" "${select_args[@]}" \
                && ! has_long_flag "--changed-files-from" "${select_args[@]}" \
                && ! has_long_flag "--symbol-query" "${select_args[@]}" \
                && ! has_long_flag "--code-query" "${select_args[@]}" \
                && ! has_long_flag "--pr-url" "${select_args[@]}" \
                && ! has_long_flag "--pr-number" "${select_args[@]}" \
                && ! has_long_flag "--from-report" "${select_args[@]}" \
                && ! has_long_flag "--last-report" "${select_args[@]}"; then
                select_args=(--changed-file "${select_args[0]}" "${select_args[@]:1}")
            fi
            if ! has_long_flag "--top-projects" "${select_args[@]}"; then
                select_args+=(--top-projects 0)
            fi
            if ! has_long_flag "--run-label" "${select_args[@]}" \
                && ! has_long_flag "--json" "${select_args[@]}" \
                && ! has_long_flag "--json-out" "${select_args[@]}"; then
                select_args+=(--run-label "$(xts_default_run_label "${select_args[@]}")")
            fi
            run_xts_selector "${select_args[@]}"
            ;;
        run)
            local run_args=("$@")
            if [ ${#run_args[@]} -gt 0 ] && [ "${run_args[0]}" = "last" ]; then
                run_args=("${run_args[@]:1}")
                if ! has_long_flag "--last-report" "${run_args[@]}" && ! has_long_flag "--from-report" "${run_args[@]}"; then
                    run_args=(--last-report "${run_args[@]}")
                fi
            elif [ ${#run_args[@]} -gt 0 ] && [[ "${run_args[0]}" != -* ]] && [ -f "${run_args[0]}" ] \
                && ! has_long_flag "--from-report" "${run_args[@]}" && ! has_long_flag "--last-report" "${run_args[@]}"; then
                run_args=(--from-report "${run_args[0]}" "${run_args[@]:1}")
            fi
            run_xts_selector --run-now "${run_args[@]}"
            ;;
        stage)
            local stage_args=("$@")
            if [ ${#stage_args[@]} -gt 0 ] && [ "${stage_args[0]}" = "last" ]; then
                stage_args=("${stage_args[@]:1}")
                if ! has_long_flag "--last-report" "${stage_args[@]}" \
                    && ! has_long_flag "--from-report" "${stage_args[@]}" \
                    && ! has_long_flag "--selected-tests-json" "${stage_args[@]}"; then
                    stage_args=(--last-report "${stage_args[@]}")
                fi
            elif [ ${#stage_args[@]} -gt 0 ] && [[ "${stage_args[0]}" != -* ]] && [ -f "${stage_args[0]}" ] \
                && ! has_long_flag "--from-report" "${stage_args[@]}" \
                && ! has_long_flag "--last-report" "${stage_args[@]}" \
                && ! has_long_flag "--selected-tests-json" "${stage_args[@]}"; then
                local stage_input="${stage_args[0]}"
                if [ "$(basename "$stage_input")" = "selected_tests.json" ]; then
                    stage_args=(--selected-tests-json "$stage_input" "${stage_args[@]:1}")
                else
                    stage_args=(--from-report "$stage_input" "${stage_args[@]:1}")
                fi
            fi
            run_xts_stage "${stage_args[@]}"
            ;;
        compare)
            local compare_args=("$@")
            if ! has_long_flag "--base" "${compare_args[@]}" \
                && ! has_long_flag "--target" "${compare_args[@]}" \
                && ! has_long_flag "--base-label" "${compare_args[@]}" \
                && ! has_long_flag "--target-label" "${compare_args[@]}" \
                && ! has_long_flag "--timeline" "${compare_args[@]}" \
                && [ ${#compare_args[@]} -ge 2 ] \
                && [[ "${compare_args[0]}" != -* ]] \
                && [[ "${compare_args[1]}" != -* ]]; then
                local base_spec="${compare_args[0]}"
                local target_spec="${compare_args[1]}"
                local compare_rest=("${compare_args[@]:2}")
                local inferred=()
                local inferred_labels=0
                if [ -e "$base_spec" ]; then
                    inferred+=(--base "$base_spec")
                else
                    inferred+=(--base-label "$base_spec")
                    inferred_labels=1
                fi
                if [ -e "$target_spec" ]; then
                    inferred+=(--target "$target_spec")
                else
                    inferred+=(--target-label "$target_spec")
                    inferred_labels=1
                fi
                if [ "$inferred_labels" -eq 1 ] && ! has_long_flag "--label-root" "${compare_rest[@]}"; then
                    inferred+=(--label-root "$(xts_default_run_store_root)")
                fi
                compare_args=("${inferred[@]}" "${compare_rest[@]}")
            fi
            run_xts_compare "${compare_args[@]}"
            ;;
        sdk)
            warn "xts sdk is a compatibility alias; use 'ohos download sdk ...' instead."
            cmd_download sdk "$@"
            ;;
        tests)
            warn "xts tests is a compatibility alias; use 'ohos download tests ...' instead."
            cmd_download tests "$@"
            ;;
        firmware)
            warn "xts firmware is a compatibility alias; use 'ohos download firmware ...' instead."
            cmd_download firmware "$@"
            ;;
        list-tags)
            warn "xts list-tags is a compatibility alias; use 'ohos download list-tags ...' instead."
            cmd_download list-tags "$@"
            ;;
        flash)
            warn "xts flash is deprecated; use 'ohos device flash ...' instead."
            cmd_device flash "$@"
            ;;
        bridge)
            warn "xts bridge is deprecated; use 'ohos device bridge ...' instead."
            cmd_device bridge "$@"
            ;;
        --*)
            run_xts_selector "$subcmd" "$@"
            ;;
        *)
            err "xts: unknown subcommand: $subcmd"
            print_help_xts
            exit 1
            ;;
    esac
}

print_help_overview() {
    cat <<HELP
ohos - unified OpenHarmony repo management tool

Usage:
  ohos [global-options] <command> [options]
  ohos init [options] sync build
  ohos sync build rk3568
  ohos help <command>

Chainable commands:
  init [options]           Initialize a repo in the current directory
  sync [options] [project..] repo sync + git lfs fetch/checkout + prebuilts download
  reset [options] [project] Hard-reset sub-repos; single project if name given
  gc [options]             Maintenance: lfs prune + git gc
  build [target] [args]    Build a target; chained build should be the final command
  fr [target] [args]       Quick rebuild with ./build.sh --fast-rebuild

Tool commands:
  admin [subcommand]       Workspace admin helpers (for example project relocation)
  download [subcommand]    Download daily SDK / firmware / XTS test packages
  device [subcommand]      Device-oriented helpers: remote HDC access and bridge packaging
  feedback                 Save project feedback / wishes next to this script
  pr [subcommand]          Wrapper around vendored gitee/gitcode PR helper
  run [subcommand]         Local run wrappers for host-side tests and post-build actions
  test [subcommand]        Developer self-test discovery and bundle-backed device wrappers
  xts [subcommand]         Wrapper around vendored arkui-xts-selector flows

Info commands:
  products                 List all available products
  parts <product>          List subsystems and components in a product
  info <component>         Show component details; supports helper filters like --deep
  file <path-or-name>      Show which GN targets and build params include a file
  params                   Quick reference for build.sh flags
  npmrc                    Show generated npm registry profiles for sync/build
  config                   Show current configuration values
  manifest-save <name>     Save current manifest to <name>.xml
  help [command]           Show general or command-specific help

Useful examples:
  ohos init
  ohos init --branch weekly_20260330 sync build rk3568
  ohos sync build sdk-linux
  ohos fr rk3568
  ohos help sync
  ohos help reset
  ohos info ace_engine --deep --path-filter arkts_frontend --target-filter native
  ohos file form_link_modifier_test.cpp
  ohos download list-tags sdk
  ohos download sdk
  ohos download sdk 20260404_120537
  ohos download firmware 20260404_120244
  ohos admin relocate --target-root /data/shared/common/projects/ohos-helper --dry-run
  ohos npmrc original
  ohos device help
  ohos run ut ace_engine_linux_unittest
  ohos test discover ace_engine
  ohos test self-test --bundle com.example.myapplication --module entry --dry-run
  ohos feedback
  ohos pr create-pr --repo openharmony/arkui_ace_engine --base master
  ohos xts sdk --sdk-build-tag 20260404_120537

Global options:
  --proxy URL              Override proxy for this run
  --config FILE            Use an alternative config file
  --help, -h               Show this help
HELP
}

print_help_init() {
    cat <<HELP
init - initialize an OpenHarmony repo in the current directory

What it runs:
  repo init -u "$REPO_MANIFEST_URL" -b <branch> --reference="$REPO_REFERENCE" $INIT_EXTRA_ARGS [manifest/depth args]

Behavior:
  - If 'init' runs alone, it auto-runs 'sync' afterward for backward compatibility.
  - If 'init' is followed by another chainable command, it stops after repo init.
  - In chained mode (`init sync build`, `sync build`, etc.), any failing step aborts the remaining steps immediately.
  - Use '--no-sync' to suppress the old auto-sync behavior explicitly.

Options:
  --branch, -b BRANCH
  --manifest, -m FILE
  --depth N
  --no-sync

Examples:
  ohos init
  ohos init --branch master
  ohos init --branch master sync build rk3568
HELP
}

print_help_sync() {
    cat <<HELP
sync - synchronize an existing OpenHarmony repo reliably

Preflight checks:
  - ensure 'repo' is installed, offer install if missing
  - when prebuilts are enabled, ensure 'nvm' / 'npm' are installed
  - when prebuilts are enabled, ensure sibling link exists:
      <repo-parent>/$PREBUILTS_SYMLINK_NAME -> $SHARED_PREBUILTS_DIR

What it runs:
  1. repo sync -j $REPO_SYNC_JOBS --optimized-fetch --current-branch --retry-fetches=5
  2. repo forall -j $LFS_JOBS -c 'env -u LocalMediaDir -u LocalReferenceDirs -u TempDir -u LfsStorageDir GIT_LFS_STORAGE=.git/lfs git lfs fetch && ... git lfs checkout'
  3. bash build/prebuilts_download.sh --npm-registry "$NPM_REGISTRY" --pypi-url "$PYPI_URL" --trusted-host "$TRUSTED_HOST" --skip-ssl

Notes:
  - The script swaps ~/.npmrc only for the prebuilts step, using the profile from OHOS_SYNC_NPMRC_PROFILE (default: mirror), and restores it after.
  - Proxy fallback applies only when configured.
  - If a sync stage fails, the script prints the stage name and a saved log path.
  - On success, every stage now prints an explicit completion line so the handoff between repo sync, LFS, and prebuilts is visible.
  - Sync-time LFS hydration uses repo-local `.git/lfs` storage and clears inherited mirror env vars that can redirect writes into shared locations.
  - After the LFS stage, the wrapper checks critical ArkUI `.tgz` files and fails early if they are still Git LFS pointer files.
  - --download-sdk is forwarded only to build/prebuilts_download.sh. It requests the repo-local OHOS SDK prebuilts used by some SDK packaging/integration flows and increases sync time and disk usage.

Options:
  -f, --force
      Back up a conflicting sibling prebuilts path automatically and, if repo checkout fails,
      discard local tracked/untracked changes in the failing repos before retrying.
  --raw-output
      Disable the compact progress bar and print the underlying command output directly.
  --download-sdk
      Pass --download-sdk to build/prebuilts_download.sh during the prebuilts stage.
      Use this only when you specifically need repo-local SDK prebuilts in this tree.
  --skip-lfs
  --skip-prebuilts
  --repo-only

Examples:
  ohos sync
  ohos sync -f
  ohos sync --raw-output
  ohos sync --download-sdk
  ohos sync build
  ohos sync --repo-only
HELP
}

print_help_build() {
    cat <<HELP
build - run ./build.sh with a named target alias or product name

Preflight checks:
  - ensure nvm/npm are available
  - ensure sibling link exists:
      <repo-parent>/$PREBUILTS_SYMLINK_NAME -> $SHARED_PREBUILTS_DIR

Common aliases:
  sdk                 ./build.sh $BUILD_SDK
  sdk-linux           ./build.sh $BUILD_SDK_LINUX
  sdk-win             ./build.sh $BUILD_SDK_WIN
  rk3568              ./build.sh $BUILD_RK3568

Behavior:
  - Unknown targets are treated as product names:
      ./build.sh --product-name <target> --ccache
  - --no-prebuilt-sdk skips the ohos-sdk prebuild stage.
      Use it for faster local component or test builds when you do not need refreshed SDK artifacts.
  - For a quick rebuild of an already-configured tree, use:
      ohos fr <target>
      This adds --fast-rebuild and skips prepare/preloader/gn_gen, so use it only when GN/build config did not change.
  - In a chained invocation, build should be the final command.

Examples:
  ohos build
  ohos build rk3568
  ohos build rk3568 --no-prebuilt-sdk --build-target linux_unittest
    Build all Linux-host ace_engine unit tests.
    Run them afterward with: ohos run ut ace_engine_linux_unittest
  ohos fr rk3568 --no-prebuilt-sdk --build-target linux_unittest
    Faster repeat build of the same Linux-host tests before rerunning them locally.
  ohos build rk3568 --no-prebuilt-sdk --build-target run_linux_unittest_capi
    Build and immediately run the Linux CAPI ace_engine unit tests.
  ohos build rk3568 --build-target ace_engine
    Build the ace_engine part itself.
    Add --no-prebuilt-sdk if you want a faster local part build and do not need refreshed ohos-sdk outputs.
  ohos build rk3568 --build-target ace_engine_test
    Build the generated aggregate ace_engine test target.
    In OHOS it pulls the ace_engine part itself plus the ace_engine unittest and benchmark targets.
  ohos sync build sdk-linux
  ohos build rk3568 --gn-args is_debug=true
HELP
}

print_help_fast_rebuild() {
    cat <<HELP
fr - run ./build.sh with --fast-rebuild for an already-configured tree

Aliases:
  fr
  fast-rebuild

Behavior:
  - Prepends --fast-rebuild to the normal wrapper build flow
  - Reuses the same target aliases as 'ohos build'
  - Intended for quick rebuilds after the initial full configuration
  - In a chained invocation, fr should be the final command

Examples:
  ohos fr
  ohos fr rk3568
  ohos fast-rebuild rk3568 --build-target ace_engine
  ohos sync fr rk3568
HELP
}

print_help_run() {
    cat <<HELP
run - wrapper for local post-build execution flows

Usage:
  ohos run ut <alias> [run.py args]

Supported unit-test aliases:
  ace_engine_capi
      Run the built Linux CAPI subset of ace_engine unit tests.
      This wrapper calls:
        python3 ${OHOS_ACE_UNITTEST_RUNNER} --path C-API-Main
      Build first with:
        ohos build rk3568 --no-prebuilt-sdk --build-target linux_unittest_capi
      Or build and run in one step with:
        ohos build rk3568 --no-prebuilt-sdk --build-target run_linux_unittest_capi

  ace_engine_linux_unittest
      Run the full built ace_engine Linux-host unittest group.
      In the OHOS repo, this group includes Linux host tests from:
        base, capi, core, core/pipeline
      This wrapper calls:
        python3 ${OHOS_ACE_UNITTEST_RUNNER}
      Build first with:
        ohos build rk3568 --no-prebuilt-sdk --build-target linux_unittest

Notes:
  - These are local Linux-host gtest binaries under foundation/arkui/ace_engine/test/unittest.
  - They are not XTS/device tests.
  - For device-side bundle-backed developer tests, use:
      ohos test help
  - The wrapper expects the test binaries to be built already.
  - Extra runner flags are passed through to run.py, for example:
      -j/--process, -d/--debug, -o/--output

Examples:
  ohos run ut ace_engine_capi
  ohos run ut ace_engine_capi --debug
  ohos run ut ace_engine_linux_unittest
  ohos run ut ace_engine_linux_unittest -j 16 --output out/ace_linux_ut.json
HELP
}

print_help_test() {
    cat <<HELP
test - developer self-test discovery and execution

Usage:
  ohos test discover <component|path>
  ohos test discover --all
  ohos test self-test <component|path> [--framework auto|bundle|developer_test] [--device SERIAL] [--hdc-path PATH] [--hdc-endpoint HOST:PORT] [--dry-run]
  ohos test self-test --bundle <bundle> [--module <module>] [--framework bundle] [--device SERIAL] [--hdc-path PATH] [--hdc-endpoint HOST:PORT] [--dry-run]
  ohos test self-test --framework developer_test --all [--productform phone] [--coverage] [--repeat N] [--dry-run]

Subcommands:
  discover
      Inspect repo-side self-test metadata.
      What it reads:
        - <component>/bundle.json -> component.build.test
        - <component>/test/**/config.json -> bundle-backed aa-test candidates
      Notes:
        - bundle.json is a valid discovery source for declared self-test targets
        - derived output also shows developer_test module names when they can be inferred from declared labels
        - use '--all' to list every component in the repo that declares self-tests

  self-test
      Run a developer self-test in one of two modes:
        bundle mode:
          hdc shell aa test -b <bundle> -m <module> -s unittest OpenHarmonyTestRunner
        developer_test mode:
          test/testfwk/developer_test/start.sh run -t UT ...
          with --device/--hdc-path/--hdc-endpoint, execution is routed through
          an hdc-aware wrapper runner so remote endpoint + serial targeting work
      Resolution order in auto mode:
        1. explicit --bundle forces bundle mode
        2. framework-only options such as --all / --coverage / --suite / --case force developer_test mode
        3. unique bundle metadata prefers bundle mode
        4. otherwise the wrapper falls back to developer_test for GN/gtest-style self-tests
      Notes:
        - '--all' is supported only with '--framework developer_test'
        - '--coverage' is supported only with '--framework developer_test'
        - after a successful developer_test run, the wrapper prints a concise summary from reports/latest/summary_report.xml when present
        - use '--dry-run' to print the exact command without executing it

Examples:
  ohos test discover ace_engine
  ohos test discover ./foundation/arkui/ace_engine
  ohos test discover --all
  ohos test self-test ace_engine --dry-run
  ohos test self-test gn_only --framework developer_test --dry-run
  ohos test self-test --framework developer_test --all --dry-run
  ohos test self-test ace_engine --framework developer_test --module unittest --suite SmokeSuite --dry-run
  ohos test self-test --bundle com.example.myapplication --module entry --dry-run
  ohos test self-test --bundle com.example.myapplication --module entry --device SER123456
HELP
}

print_help_info() {
    cat <<HELP
info - show component metadata and optional BUILD.gn deep scan

What it runs:
  python3 "$OHOS_HELPER" info <component> [--deep] [--path-filter TEXT] [--target-filter TEXT] [--target-type TYPE] [--view grouped|tree|flat] [--max-depth N] [--describe]

File-mode shortcuts:
  - ohos info file <path-or-name>
  - ohos info <existing-file-path>
  These route to:
    python3 "$OHOS_HELPER" file <path-or-name>

Useful flags:
  --deep                 Scan BUILD.gn files under the component directory
  --path-filter TEXT     Keep only matching subdirectories in deep output
  --target-filter TEXT   Keep only matching target names in deep output
  --target-type TYPE     Keep only matching target types like group or action
  --view grouped         Group targets by directory
  --view tree            Show directory hierarchy for step-by-step narrowing
  --view flat            Show path:target lines for grep/less/filtering
  --max-depth N          Limit tree expansion depth for tree view
  --describe             Show file/line/type/deps/summary for each matched target

Examples:
  ohos info ace_engine
  ohos info ace_engine --deep
  ohos info file ./foundation/arkui/ace_engine/frameworks/bridge/declarative_frontend/engine/jsi/nativeModule/arkts_native_common_bridge.cpp
  ohos info ./foundation/arkui/ace_engine/frameworks/bridge/declarative_frontend/engine/jsi/nativeModule/arkts_native_common_bridge.cpp
  ohos info ace_engine --deep --path-filter arkts_frontend
  ohos info ace_engine --deep --target-filter native
  ohos info ace_engine --deep --view tree --max-depth 2
  ohos info ace_engine --deep --view tree --max-depth 3 | less -R
  ohos info ace_engine --deep --target-filter linux_unittest --describe
HELP
}

print_help_file() {
    cat <<HELP
file - resolve a file and show which build targets and params include it

What it runs:
  python3 "$OHOS_HELPER" file <path-or-name>

Accepted input:
  - absolute file path
  - path relative to the current directory
  - plain file name

Behavior:
  - exact paths are preferred when they exist
  - plain file names are resolved across the repo
  - if multiple files match, the helper prompts you to choose one
  - if there is no exact basename match, the helper falls back to basename substring matching

Output includes:
  - resolved file path
  - direct GN targets that list the file in sources
  - reverse dependent targets inside the scanned scope
  - likely binary/package outputs inferred from direct targets, reverse deps, and build metadata
  - related component/product build hints when bundle.json metadata is available

Examples:
  ohos file form_link_modifier_test.cpp
  ohos file foundation/arkui/ace_engine/test/unittest/capi/modifiers/form_link_modifier_test.cpp
  ohos file ./foundation/arkui/ace_engine/test/unittest/capi/modifiers/form_link_modifier_test.cpp
  ohos file /home/dmazur/proj/ohos_master/foundation/arkui/ace_engine/test/unittest/capi/modifiers/form_link_modifier_test.cpp
  ohos file link_modifier_test.cpp
HELP
}

print_help_pr() {
    cat <<HELP
pr - wrapper around vendored gitee_util / gitcode PR helper

What it runs:
  python3 "$GITEE_UTIL_RUNNER" [--provider gitee|gitcode] <subcommand> [args]

Supported subcommands:
  create-pr
  create-issue
  create-issue-pr
  comment-pr
  list-pr
  show-pr
  show-comments

Notes:
  - Runtime config is stored in:
      ${XDG_CONFIG_HOME:-$HOME/.config}/gitee_util/config.ini
  - Provider can be selected with --provider gitee or --provider gitcode
  - On the first real PR command, the wrapper may offer:
      python3 -m pip install --user requests tqdm prompt_toolkit beautifulsoup4 python-dateutil
  - show-pr prints one readable PR card with description, reviewers, code owners, and changed files.
  - show-comments is reformatted into a compact viewer.
  - In an interactive terminal with less available, comment output opens in a pager
    so you can navigate with arrows/PageUp/PageDown and quit with q.

Examples:
  ohos pr create-pr --repo openharmony/arkui_ace_engine --base master
  ohos pr --provider gitcode create-pr --repo openharmony/arkui_ace_engine --base master
  ohos pr create-issue-pr --repo openharmony/arkui_ace_engine --type bug --base master
  ohos pr comment-pr --url https://gitcode.com/owner/repo/pull/123 --comment "Please rerun tests"
  ohos pr list-pr --repos openharmony/arkui_ace_engine --state open
  ohos pr show-pr --url https://gitcode.com/owner/repo/pulls/123
  ohos pr show-comments --url https://gitcode.com/owner/repo/pulls/123
HELP
}

print_help_feedback() {
    cat <<HELP
feedback - save project wishes / proposals next to this script

What it does:
  - shows the current repository URL to clone or fork
  - shows a short fork + PR flow
  - prompts for author, topic, and free-form feedback text
  - saves the note under:
      $OHOS_FEEDBACK_DIR

Input behavior:
  - Press Enter to accept the default author/topic values.
  - Finish the feedback text with a single '.' on a new line.

Saved file format:
  <UTC timestamp>__<author>.md

Examples:
  ohos feedback
HELP
}

print_help_device() {
    if [ -f "$OHOS_DEVICE_TOOL" ]; then
        bash "$OHOS_DEVICE_TOOL" help
        return
    fi

    cat <<HELP
device - standalone device access and bridge helper

What it runs:
  bash "$OHOS_DEVICE_TOOL" <subcommand> [args]

Supported subcommands:
  help
  bridge

Purpose:
  - connect to devices attached to another Linux or Windows PC
  - package the Windows HDC bridge bundle
  - keep device-specific setup separate from the main XTS help

Examples:
  ohos device help
  ohos device bridge help
  ohos device bridge package-windows --last-report
HELP
}

print_help_xts() {
    cat <<HELP
xts - wrapper around vendored arkui-xts-selector

What it runs:
  (cd "$ARKUI_XTS_SELECTOR_DIR" && PYTHONPATH=src python3 -m arkui_xts_selector ...)

Supported subcommands:
  select     Save a reusable selector report; accepts a raw PR/MR URL as the first arg
  run        Execute from a saved report (ohos xts run last) or raw selector args
  stage      Stage a compact ACTS testcase directory from a saved report
  compare    Compare two XTS runs by label or by result paths
  bridge     Compatibility alias; prefer 'ohos device bridge'
  sdk        Compatibility alias; prefer 'ohos download sdk'
  tests      Compatibility alias; prefer 'ohos download tests'
  firmware   Compatibility alias; prefer 'ohos download firmware'
  list-tags  Compatibility alias; prefer 'ohos download list-tags'
  flash      Compatibility alias; prefer 'ohos device flash'

Notes:
  - The vendored tool repo lives at: $ARKUI_XTS_SELECTOR_DIR
  - After a plain clone or after pulling new superproject commits, refresh nested tools with:
      git submodule update --init --recursive
  - The selector is pinned by this repository; avoid pulling it independently unless
    you intentionally plan to update the recorded submodule pointer.
  - You can also skip the wrapper subcommand and pass raw selector flags:
      ohos xts --pr-url <url>
  - ohos xts select auto-adds:
      --top-projects 0
      --run-label <user__context>
    unless you override them explicitly.
  - ohos xts run last reuses the latest saved selector report instead of rescoring the PR.
  - ohos xts stage reuses a saved selector report and writes a compact staged
    testcases directory plus stage_report.json next to that report.
  - The daily artifact aliases now route through the dedicated download tool:
      ohos download tests
      ohos download sdk
      ohos download firmware
      ohos download list-tags
  - 'ohos xts flash' is a compatibility alias to 'ohos device flash'.
  - Default daily download roots are shared per-user:
      tests    -> $XTS_DOWNLOAD_ROOT
      sdk      -> $SDK_DOWNLOAD_ROOT
      firmware -> $FIRMWARE_DOWNLOAD_ROOT
  - If HDC needs extra shared libraries such as libusb_shared.so, set
    HDC_LIBRARY_PATH in $OHOS_CONF or let the wrapper auto-detect a common
    SDK/toolchains location.
  - When launched outside an OHOS repo, the wrapper auto-injects --repo-root
    from OHOS_REPO_ROOT, the current directory if it is an OHOS tree, or
    common defaults like $HOME/proj/ohos_master.
  - If XTS_HDC_ENDPOINT is set in $OHOS_CONF, select/run flows auto-target that
    remote HDC server for generated commands and preflight.
  - Remote device setup and bridge packaging moved to:
      ohos device help
      ohos device bridge help
  - After ``ohos xts run`` (or ``--run-now``), the human report lists ``Next Steps``
    with ``Repeat this run`` first: a copy-paste command with the same report path,
    devices, HDC flags, and run options. The JSON report also includes
    ``repeat_run_command``.
  - To avoid xdevice and run via ``hdc`` + ``aa test``, pass ``--run-tool aa_test``.
    With ``--run-tool auto``, a remote HDC endpoint (``--hdc-endpoint`` or
    XTS_HDC_ENDPOINT) makes the selector prefer ``aa_test`` over xdevice.

Recommended flow:
  1. Pick tests and save a reusable report:
     ohos xts select https://gitcode.com/openharmony/arkui_ace_engine/merge_requests/83065
  2. Run the saved plan:
     ohos xts run last
  3. If you want explicit compare labels across two runs:
     ohos xts select https://gitcode.com/.../83065 --run-label mr83065_before
     ohos xts run last
     ohos xts select https://gitcode.com/.../83065 --run-label mr83065_after
     ohos xts run last
     ohos xts compare mr83065_before mr83065_after

Regression / improvement compare:
  - Use explicit labels for before/after runs.
  - ohos xts compare <base-label> <target-label> shows regressions and improvements.
  - You can also compare raw result paths instead of labels.

Examples:
  ohos xts select --symbol-query ButtonModifier
  ohos xts --pr-url https://gitcode.com/openharmony/arkui_ace_engine/pull/82225
  ohos xts run last
  ohos xts stage last
  ohos xts stage /path/to/selector_report.json
  ohos xts run /path/to/selector_report.json
  ohos xts compare baseline fix
  ohos xts tests --daily-build-tag 20260404_120510
  ohos xts sdk --sdk-build-tag 20260404_120537
  ohos xts firmware --firmware-build-tag 20260404_120244
  ohos xts list-tags firmware --list-tags-count 10
  ohos device flash --firmware-build-tag 20260404_120244 --device <serial>
  ohos device bridge package-windows --last-report
HELP
}

print_help_xts_bridge() {
    cat <<HELP
xts bridge - compatibility alias for 'ohos device bridge'

What it runs:
  bash "$OHOS_DEVICE_TOOL" bridge ...

Preferred command:
  ohos device bridge help

Examples:
  ohos device bridge package-windows --last-report
  ohos device bridge package-windows --server-host 10.0.0.10 --server-user user --selector-report /tmp/selector_report.json --output /tmp/rk3568_bundle.zip
HELP
}

print_help_reset() {
    cat <<HELP
reset - hard-reset sub-repos, clean artifacts, and optionally re-sync

Usage:
  ohos reset [options]          Reset ALL sub-repos (with confirmation)
  ohos reset <project>         Reset a single project (delete + re-sync)

Single-project mode:
  Deletes the project directory and re-syncs it via repo sync.
  No confirmation prompt. Also runs LFS checkout.

Full reset runs (in order):
  [1] repo forall -j $RESET_JOBS -c 'git clean -fxd'
       Remove all untracked and ignored files in every sub-repo.
  [2] repo forall -j $RESET_JOBS -c 'git reset --hard HEAD'
       Discard all local modifications in every sub-repo.
  [3] repo forall -j $GC_JOBS  -c 'git lfs prune'
       Prune unreachable LFS objects.  (skipped unless RESET_LFS_PRUNE=true)
  [4] repo forall -j $GC_JOBS  -c 'git gc'
       Run garbage collection on every sub-repo.  (skipped unless RESET_GC=true)
  [5] rm -rf $RESET_RM_DIRS
       Delete the listed directories from the repo root.
  [6] ohos sync
       Full sync (repo + lfs + prebuilts).  (skipped with --no-sync)

Configuration (from ${OHOS_CONF}):
  RESET_JOBS=$RESET_JOBS       parallel jobs for clean/reset
  GC_JOBS=$GC_JOBS         parallel jobs for lfs prune / git gc
  RESET_LFS_PRUNE=$RESET_LFS_PRUNE  run 'git lfs prune' during reset
  RESET_GC=$RESET_GC           run 'git gc' during reset
  RESET_RM_DIRS="$RESET_RM_DIRS"

Options:
  --no-sync     skip the final 'ohos sync' step (full reset only)

Examples:
  ohos reset arkui_ace_engine
  ohos reset
  ohos reset --no-sync
HELP
}

print_help_download() {
    if [ -f "$OHOS_DOWNLOAD_TOOL" ]; then
        bash "$OHOS_DOWNLOAD_TOOL" help
        return
    fi
    err "Missing download tool: $OHOS_DOWNLOAD_TOOL"
}

print_help_admin() {
    cat <<HELP
admin - workspace maintenance helpers

Usage:
  ohos admin help
  ohos admin relocate --target-root <path> [--legacy-link <path>] [--dry-run] [--yes]

Subcommands:
  relocate
      Move the current project root to a new canonical location and create
      a legacy symlink path.

      Path model:
        - current real root: resolved script directory (follows symlinks)
        - legacy link path: launch directory path by default

      Safety:
        - target root must not exist
        - target root must not be inside current real root
        - dry-run prints the plan without changing filesystem state
        - real move asks confirmation unless --yes is passed

Examples:
  ohos admin relocate --target-root /data/shared/common/projects/ohos-helper --dry-run
  ohos admin relocate --target-root /data/shared/common/projects/ohos-helper --legacy-link /data/shared/common/scripts --yes
HELP
}

cmd_help() {
    local topic="${1:-}"
    case "$topic" in
        "") print_help_overview ;;
        init) print_help_init ;;
        sync) print_help_sync ;;
        build) print_help_build ;;
        fr|fast-rebuild) print_help_fast_rebuild ;;
        run) print_help_run ;;
        test) print_help_test ;;
        reset) print_help_reset ;;
        info) print_help_info ;;
        file) print_help_file ;;
        device) print_help_device ;;
        feedback) print_help_feedback ;;
        pr) print_help_pr ;;
        xts) print_help_xts ;;
        download) print_help_download ;;
        admin) print_help_admin ;;
        npmrc) print_help_npmrc ;;
        gc|products|parts|params|config|manifest-save)
            print_help_overview
            ;;
        *)
            err "Unknown help topic: $topic"
            print_help_overview
            exit 1
            ;;
    esac
}

is_chainable_command() {
    case "$1" in
        init|sync|reset|gc|build|fr|fast-rebuild) return 0 ;;
        *) return 1 ;;
    esac
}

dispatch_single_command() {
    local cmd="$1"
    shift
    case "$cmd" in
        help|--help|-h) cmd_help "$@" ;;
        products) cmd_products "$@" ;;
        parts) cmd_parts "$@" ;;
        info) cmd_info "$@" ;;
        file) cmd_file "$@" ;;
        device) cmd_device "$@" ;;
        admin) cmd_admin "$@" ;;
        feedback) cmd_feedback "$@" ;;
        params) cmd_params "$@" ;;
        npmrc) cmd_npmrc "$@" ;;
        config) cmd_config "$@" ;;
        manifest-save) cmd_manifest_save "$@" ;;
        pr) cmd_pr "$@" ;;
        run) cmd_run "$@" ;;
        test) cmd_test "$@" ;;
        xts) cmd_xts "$@" ;;
        download) cmd_download "$@" ;;
        *)
            err "Unknown command: $cmd"
            print_help_overview
            exit 1
            ;;
    esac
}

while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --proxy)
            [ $# -ge 2 ] || { err "--proxy requires a value"; exit 1; }
            OHOS_PROXY="$2"
            shift 2
            ;;
        --proxy=*)
            OHOS_PROXY="${1#--proxy=}"
            shift
            ;;
        --config)
            [ $# -ge 2 ] || { err "--config requires a value"; exit 1; }
            OHOS_CONF="$2"
            # shellcheck disable=SC1090
            source "$OHOS_CONF"
            if [ -f "$OHOS_USER_CONF" ]; then
                # shellcheck disable=SC1090
                source "$OHOS_USER_CONF"
            fi
            shift 2
            ;;
        --config=*)
            OHOS_CONF="${1#--config=}"
            # shellcheck disable=SC1090
            source "$OHOS_CONF"
            if [ -f "$OHOS_USER_CONF" ]; then
                # shellcheck disable=SC1090
                source "$OHOS_USER_CONF"
            fi
            shift
            ;;
        --help|-h)
            cmd_help
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -eq 0 ]; then
    cmd_help
    exit 0
fi

case "$1" in
    help|--help|-h|products|parts|info|file|device|admin|feedback|params|npmrc|config|manifest-save|pr|run|test|xts|download)
        cmd="$1"
        shift
        dispatch_single_command "$cmd" "$@"
        exit 0
        ;;
esac

while [ $# -gt 0 ]; do
    cmd="$1"
    shift

    case "$cmd" in
        init)
            init_args=()
            init_no_sync=false
            while [ $# -gt 0 ] && ! is_chainable_command "$1"; do
                case "$1" in
                    --branch|-b|--manifest|-m|--depth)
                        [ $# -ge 2 ] || { err "init: missing value for $1"; exit 1; }
                        init_args+=("$1" "$2")
                        shift 2
                        ;;
                    --no-sync)
                        init_no_sync=true
                        init_args+=("$1")
                        shift
                        ;;
                    *)
                        err "init: unknown option $1"
                        exit 1
                        ;;
                esac
            done
            if [ $# -eq 0 ] && [ "$init_no_sync" = "false" ]; then
                OHOS_INIT_AUTOSYNC=1 run_chain_command "init" cmd_init "${init_args[@]}"
            else
                OHOS_INIT_AUTOSYNC=0 run_chain_command "init" cmd_init "${init_args[@]}"
            fi
            ;;
        sync)
            sync_args=()
            while [ $# -gt 0 ] && ! is_chainable_command "$1"; do
                case "$1" in
                    -f|--force|--raw-output|--download-sdk|--skip-lfs|--skip-prebuilts|--repo-only)
                        sync_args+=("$1")
                        shift
                        ;;
                    *)
                        sync_args+=("$1")
                        shift
                        ;;
                esac
            done
            run_chain_command "sync" cmd_sync "${sync_args[@]}"
            ;;
        reset)
            reset_args=()
            while [ $# -gt 0 ] && ! is_chainable_command "$1"; do
                case "$1" in
                    --no-sync)
                        reset_args+=("$1")
                        shift
                        ;;
                    *)
                        reset_args+=("$1")
                        shift
                        ;;
                esac
            done
            run_chain_command "reset" cmd_reset "${reset_args[@]}"
            ;;
        gc)
            gc_args=()
            while [ $# -gt 0 ] && ! is_chainable_command "$1"; do
                case "$1" in
                    --no-prune|--no-gc|--prune|--gc)
                        gc_args+=("$1")
                        shift
                        ;;
                    *)
                        err "gc: unknown option $1"
                        exit 1
                        ;;
                esac
            done
            run_chain_command "gc" cmd_gc "${gc_args[@]}"
            ;;
        fr|fast-rebuild)
            run_chain_command "fast-rebuild" cmd_fast_rebuild "$@"
            break
            ;;
        build)
            run_chain_command "build" cmd_build "$@"
            break
            ;;
        *)
            err "Unknown command: $cmd"
            print_help_overview
            exit 1
            ;;
    esac
done
