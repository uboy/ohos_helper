#!/bin/bash
# =============================================================================
# ohos.sh - unified OpenHarmony repo management tool
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OHOS_HELPER="${SCRIPT_DIR}/ohos-helper.py"
OHOS_CONF="${OHOS_CONF:-${SCRIPT_DIR}/ohos.conf}"
CURL_WRAPPER="${SCRIPT_DIR}/ohos-curl-fallback"

if [ -f "$OHOS_CONF" ]; then
    # shellcheck disable=SC1090
    source "$OHOS_CONF"
fi

NPM_REGISTRY="${NPM_REGISTRY:-http://tsnnlx12bs02.ad.telmast.com:8081/repository/huaweicloud}"
OHOS_NPM_REGISTRY="${OHOS_NPM_REGISTRY:-http://tsnnlx12bs02.ad.telmast.com:8081/harmonyos/}"
OHPM_REGISTRY="${OHPM_REGISTRY:-http://tsnnlx12bs02.ad.telmast.com:8081/repository/ohpm/}"
PYPI_URL="${PYPI_URL:-http://tsnnlx12bs02.ad.telmast.com:8081/repository/pypi/simple/}"
TRUSTED_HOST="${TRUSTED_HOST:-tsnnlx12bs02.ad.telmast.com}"
KOALA_NPM_REGISTRY="${KOALA_NPM_REGISTRY:-http://tsnnlx12bs02.ad.telmast.com:8081/repository/koala-npm/}"

REPO_MANIFEST_URL="${REPO_MANIFEST_URL:-https://gitcode.com/openharmony/manifest.git}"
REPO_REFERENCE="${REPO_REFERENCE:-/data/shared/ohos_mirror}"
LFS_MIRROR="${LFS_MIRROR:-/data/shared/ohos_mirror}"

OHOS_PROXY="${OHOS_PROXY:-}"
OHOS_PROXY_CONNECT_TIMEOUT="${OHOS_PROXY_CONNECT_TIMEOUT:-15}"
OHOS_NO_PROXY="${OHOS_NO_PROXY:-tsnnlx12bs02.ad.telmast.com,localhost,127.0.0.1}"

REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-8}"
LFS_JOBS="${LFS_JOBS:-64}"
RESET_JOBS="${RESET_JOBS:-64}"

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

REPO_INSTALL_URL="${REPO_INSTALL_URL:-https://gitee.com/oschina/repo/raw/fork_flow/repo-py3}"
NVM_INSTALL_URL="${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh}"
SHARED_PREBUILTS_DIR="${SHARED_PREBUILTS_DIR:-/data/shared/openharmony_prebuilts}"
PREBUILTS_SYMLINK_NAME="${PREBUILTS_SYMLINK_NAME:-openharmony_prebuilts}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[ohos]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ohos]${NC} $*"; }
err()   { echo -e "${RED}[ohos]${NC} $*" >&2; }

has_command() {
    command -v "$1" >/dev/null 2>&1
}

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
    shift
    info "======== ${label} ========"
    "$@"
}

is_ohos_repo() {
    [[ -d ".repo" ]] && [[ -f "build/prebuilts_download.sh" ]]
}

require_ohos_repo() {
    if ! is_ohos_repo; then
        err "Current directory is not an OpenHarmony repository."
        err "Expected .repo/ and build/prebuilts_download.sh in $(pwd)"
        err "Run 'ohos init' first, or cd into an existing OH repo."
        exit 1
    fi
}

NPMRC="$HOME/.npmrc"
NPMRC_BAK=""
NPMRC_PROTECTED=0

generate_npmrc() {
    cat <<EOF
fund=false
package-lock=true
strict-ssl=false
lockfile=false
registry=${NPM_REGISTRY}
@ohos:registry=${OHOS_NPM_REGISTRY}
@azanat:registry=${KOALA_NPM_REGISTRY}
@koalaui:registry=${KOALA_NPM_REGISTRY}
@arkoala:registry=${KOALA_NPM_REGISTRY}
@panda:registry=${KOALA_NPM_REGISTRY}
@idlizer:registry=${KOALA_NPM_REGISTRY}
EOF
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
    check_stale_backup

    NPMRC_BAK="$HOME/.npmrc.ohos_backup_$$"
    if [ -f "$NPMRC" ]; then
        cp -a "$NPMRC" "$NPMRC_BAK"
    else
        touch "$NPMRC_BAK.empty"
        NPMRC_BAK="${NPMRC_BAK}.empty"
    fi

    generate_npmrc > "$NPMRC"
    NPMRC_PROTECTED=1
    info "~/.npmrc replaced with script config (backup: ${NPMRC_BAK})"
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
        if confirm_default_no "Replace it with $SHARED_PREBUILTS_DIR? [y/N] "; then
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
        err "Expected sibling prebuilts link path already exists and is not a symlink:"
        err "  $link_path"
        err "Move it away or replace it manually, then rerun the command."
        exit 1
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
}

sync_stage_repo() {
    repo sync -j "$REPO_SYNC_JOBS" --optimized-fetch --current-branch --retry-fetches=5
}

sync_stage_lfs() {
    repo forall -j "$LFS_JOBS" -c \
        "git config lfs.storage ${LFS_MIRROR}/\$REPO_PROJECT.git/lfs/objects && git lfs fetch && git lfs checkout"
}

sync_stage_prebuilts() {
    protect_npmrc
    trap 'restore_npmrc; cleanup_proxy_fallback' EXIT INT TERM
    setup_proxy_fallback

    bash build/prebuilts_download.sh \
        --npm-registry "$NPM_REGISTRY" \
        --pypi-url "$PYPI_URL" \
        --trusted-host "$TRUSTED_HOST" \
        --skip-ssl

    restore_npmrc
    cleanup_proxy_fallback
    trap - EXIT INT TERM
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
    require_ohos_repo

    local run_lfs=true
    local run_prebuilts=true

    while [ $# -gt 0 ]; do
        case "$1" in
            --skip-lfs) run_lfs=false ;;
            --skip-prebuilts) run_prebuilts=false ;;
            --repo-only)
                run_lfs=false
                run_prebuilts=false
                ;;
            *)
                err "sync: unknown option $1"
                exit 1
                ;;
        esac
        shift
    done

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
        run_step "[$step/$total] prebuilts_download.sh" sync_stage_prebuilts
    fi

    info "Sync complete."
}

cmd_reset() {
    require_ohos_repo
    local skip_sync=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --no-sync) skip_sync=true ;;
            *)
                err "reset: unknown option $1"
                exit 1
                ;;
        esac
        shift
    done

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

cmd_build() {
    require_ohos_repo
    ensure_build_prereqs

    local target="sdk"
    if [ $# -gt 0 ]; then
        target="$1"
        shift
    fi

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

    info "Building: ./build.sh $build_args $*"
    time ./build.sh $build_args "$@"
}

cmd_manifest_save() {
    require_ohos_repo
    local name="${1:?Usage: ohos manifest-save <name>}"
    repo manifest -r -o "${name}.xml"
    info "Manifest saved to ${name}.xml"
}

cmd_products() {
    require_ohos_repo
    python3 "$OHOS_HELPER" products
}

cmd_parts() {
    require_ohos_repo
    local product="${1:?Usage: ohos parts <product-name>}"
    python3 "$OHOS_HELPER" parts "$product"
}

cmd_info() {
    require_ohos_repo
    python3 "$OHOS_HELPER" info "$@"
}

cmd_params() {
    python3 "$OHOS_HELPER" params
}

cmd_npmrc() {
    echo -e "${BOLD}The script uses this .npmrc during sync/build:${NC}"
    echo ""
    generate_npmrc
    echo ""
    echo -e "${CYAN}Configure your own ~/.npmrc to match if you run npm/ohpm manually.${NC}"
    echo -e "${CYAN}During 'ohos sync' and 'ohos build', the script swaps it in automatically${NC}"
    echo -e "${CYAN}and restores your original ~/.npmrc afterward.${NC}"
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
    echo "  LFS mirror          : $LFS_MIRROR"
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
  sync [options]           repo sync + git lfs fetch/checkout + prebuilts download
  reset [options]          Hard-reset all sub-repos, remove artifacts, optionally sync
  gc [options]             Maintenance: lfs prune + git gc
  build [target] [args]    Build a target; chained build should be the final command

Info commands:
  products                 List all available products
  parts <product>          List subsystems and components in a product
  info <component>         Show component details; supports helper filters like --deep
  params                   Quick reference for build.sh flags
  npmrc                    Show the temporary .npmrc used during sync/build
  config                   Show current configuration values
  manifest-save <name>     Save current manifest to <name>.xml
  help [command]           Show general or command-specific help

Useful examples:
  ohos init
  ohos init --branch weekly_20260330 sync build rk3568
  ohos sync build sdk-linux
  ohos help sync
  ohos info ace_engine --deep --path-filter arkts_frontend --target-filter native

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
  2. repo forall -j $LFS_JOBS -c 'git config lfs.storage ${LFS_MIRROR}/\$REPO_PROJECT.git/lfs/objects && git lfs fetch && git lfs checkout'
  3. bash build/prebuilts_download.sh --npm-registry "$NPM_REGISTRY" --pypi-url "$PYPI_URL" --trusted-host "$TRUSTED_HOST" --skip-ssl

Notes:
  - The script swaps ~/.npmrc only for the prebuilts step and restores it after.
  - Proxy fallback applies only when configured.

Options:
  --skip-lfs
  --skip-prebuilts
  --repo-only

Examples:
  ohos sync
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
  - In a chained invocation, build should be the final command.

Examples:
  ohos build
  ohos build rk3568
  ohos sync build sdk-linux
  ohos build rk3568 --gn-args is_debug=true
HELP
}

print_help_info() {
    cat <<HELP
info - show component metadata and optional BUILD.gn deep scan

What it runs:
  python3 "$OHOS_HELPER" info <component> [--deep] [--path-filter TEXT] [--target-filter TEXT] [--target-type TYPE] [--view grouped|tree|flat] [--max-depth N] [--describe]

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
  ohos info ace_engine --deep --path-filter arkts_frontend
  ohos info ace_engine --deep --target-filter native
  ohos info ace_engine --deep --view tree --max-depth 2
  ohos info ace_engine --deep --view tree --max-depth 3 | less -R
  ohos info ace_engine --deep --target-filter linux_unittest --describe
HELP
}

cmd_help() {
    local topic="${1:-}"
    case "$topic" in
        "") print_help_overview ;;
        init) print_help_init ;;
        sync) print_help_sync ;;
        build) print_help_build ;;
        info) print_help_info ;;
        reset|gc|products|parts|params|npmrc|config|manifest-save)
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
        init|sync|reset|gc|build) return 0 ;;
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
        params) cmd_params "$@" ;;
        npmrc) cmd_npmrc "$@" ;;
        config) cmd_config "$@" ;;
        manifest-save) cmd_manifest_save "$@" ;;
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
            shift 2
            ;;
        --config=*)
            OHOS_CONF="${1#--config=}"
            # shellcheck disable=SC1090
            source "$OHOS_CONF"
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
    help|--help|-h|products|parts|info|params|npmrc|config|manifest-save)
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
                OHOS_INIT_AUTOSYNC=1 cmd_init "${init_args[@]}"
            else
                OHOS_INIT_AUTOSYNC=0 cmd_init "${init_args[@]}"
            fi
            ;;
        sync)
            sync_args=()
            while [ $# -gt 0 ] && ! is_chainable_command "$1"; do
                case "$1" in
                    --skip-lfs|--skip-prebuilts|--repo-only)
                        sync_args+=("$1")
                        shift
                        ;;
                    *)
                        err "sync: unknown option $1"
                        exit 1
                        ;;
                esac
            done
            cmd_sync "${sync_args[@]}"
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
                        err "reset: unknown option $1"
                        exit 1
                        ;;
                esac
            done
            cmd_reset "${reset_args[@]}"
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
            cmd_gc "${gc_args[@]}"
            ;;
        build)
            cmd_build "$@"
            break
            ;;
        *)
            err "Unknown command: $cmd"
            print_help_overview
            exit 1
            ;;
    esac
done
