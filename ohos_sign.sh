#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
    case "$0" in
        */ohos_sign.sh|ohos_sign.sh)
            exec bash "$0" "$@"
            ;;
    esac
    printf '%s\n' "ohos_sign.sh requires bash. Run it with: bash $0 ..." >&2
    return 1 2>/dev/null || exit 1
fi

set -euo pipefail

# ── Path resolution (same pattern as ohos_download.sh) ───────────────────────

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
OHOS_USER_CONF="${OHOS_USER_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/ohos/local.conf}"

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

# ── Defaults ──────────────────────────────────────────────────────────────────

SIGN_KEYSTORE_PWD="${SIGN_KEYSTORE_PWD:-123456}"
SIGN_KEY_PWD="${SIGN_KEY_PWD:-123456}"
SIGN_MODE="${SIGN_MODE:-debug}"
SIGN_KEY_ALIAS_APP="${SIGN_KEY_ALIAS_APP:-openharmony application release}"
SIGN_PROFILE_TEMPLATE="${SIGN_PROFILE_TEMPLATE:-}"

# Profile key alias depends on mode
resolve_profile_key_alias() {
    local mode="${1:-$SIGN_MODE}"
    if [ -n "${SIGN_KEY_ALIAS_PROFILE:-}" ]; then
        printf '%s' "$SIGN_KEY_ALIAS_PROFILE"
    elif [ "$mode" = "debug" ]; then
        printf '%s' "openharmony application profile debug"
    else
        printf '%s' "openharmony application profile release"
    fi
}

# ── Colors / output helpers ──────────────────────────────────────────────────

info()  { printf '\033[1;34m[sign]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[sign]\033[0m %s\n' "$*" >&2; }
err()   { printf '\033[1;31m[sign]\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

# ── Toolchain resolution ─────────────────────────────────────────────────────

# Resolve OHOS_ROOT: current dir or config
resolve_ohos_root() {
    if [ -n "${OHOS_REPO_ROOT:-}" ] && [ -d "${OHOS_REPO_ROOT}/.repo" ]; then
        printf '%s' "$OHOS_REPO_ROOT"
        return
    fi
    if [ -d ".repo" ]; then
        printf '%s' "$(pwd)"
        return
    fi
    # Common defaults
    local try
    for try in "$HOME/proj/ohos_master" "$HOME/proj/openharmony"; do
        if [ -d "$try/.repo" ]; then
            printf '%s' "$try"
            return
        fi
    done
    printf ''
}

# Find toolchains/lib/ directory with signing tools.
# Cascade: SIGN_TOOL_PATH → shared tools → downloaded SDK → ohos_root
resolve_sign_toolchain() {
    local toolchain_dir=""

    # 1. Explicit config
    if [ -n "${SIGN_TOOL_PATH:-}" ] && [ -f "${SIGN_TOOL_PATH}/hap-sign-tool.jar" ]; then
        toolchain_dir="$SIGN_TOOL_PATH"
    fi

    # 2. Shared tools
    if [ -z "$toolchain_dir" ] && [ -f "${OHOS_TOOLS_DIR:-$HOME/ohos_cache/tools}/toolchains/lib/hap-sign-tool.jar" ]; then
        toolchain_dir="${OHOS_TOOLS_DIR:-$HOME/ohos_cache/tools}/toolchains/lib"
    fi

    # 3. Downloaded SDK — find latest extracted toolchains
    if [ -z "$toolchain_dir" ]; then
        local sdk_root="${SDK_DOWNLOAD_ROOT:-$HOME/ohos_cache/sdk}"
        local sdk_public="$sdk_root/ohos-sdk-public"
        if [ -d "$sdk_public" ]; then
            # Find latest tag with extracted toolchains zip
            local latest_toolchains_zip
            latest_toolchains_zip=$(find "$sdk_public" -maxdepth 3 -name 'toolchains-linux-x64-*.zip' 2>/dev/null | sort -r | head -1)
            if [ -n "$latest_toolchains_zip" ]; then
                local tc_extract_dir
                tc_extract_dir="$(dirname "$latest_toolchains_zip")/toolchains/lib"
                if [ -f "$tc_extract_dir/hap-sign-tool.jar" ]; then
                    toolchain_dir="$tc_extract_dir"
                fi
            fi
        fi
    fi

    # 4. ohos_root source tree
    if [ -z "$toolchain_dir" ]; then
        local ohos_root
        ohos_root="$(resolve_ohos_root)"
        if [ -n "$ohos_root" ] && [ -f "$ohos_root/developtools/hapsigner/dist/hap-sign-tool.jar" ]; then
            toolchain_dir="$ohos_root/developtools/hapsigner/dist"
        fi
    fi

    printf '%s' "$toolchain_dir"
}

# Locate the OpenHarmony keystore, certificates, and templates.
# Returns the directory containing them (may differ from toolchain if fallbacks are used).
resolve_sign_certs_dir() {
    local tc_dir
    tc_dir="$(resolve_sign_toolchain)"

    # Check if Application.pem exists in toolchain dir
    if [ -f "$tc_dir/OpenHarmonyApplication.pem" ]; then
        printf '%s' "$tc_dir"
        return
    fi

    # Fallback: ohos_root/dist has it
    local ohos_root
    ohos_root="$(resolve_ohos_root)"
    if [ -n "$ohos_root" ] && [ -f "$ohos_root/developtools/hapsigner/dist/OpenHarmonyApplication.pem" ]; then
        printf '%s' "$ohos_root/developtools/hapsigner/dist"
        return
    fi

    # Last resort: return toolchain dir (will fail with clear error later)
    printf '%s' "$tc_dir"
}

resolve_profile_template() {
    local mode="$1"  # debug or release

    if [ -n "$SIGN_PROFILE_TEMPLATE" ] && [ -f "$SIGN_PROFILE_TEMPLATE" ]; then
        printf '%s' "$SIGN_PROFILE_TEMPLATE"
        return
    fi

    local certs_dir
    certs_dir="$(resolve_sign_certs_dir)"

    if [ "$mode" = "debug" ]; then
        printf '%s' "$certs_dir/UnsgnedDebugProfileTemplate.json"
    else
        printf '%s' "$certs_dir/UnsgnedReleasedProfileTemplate.json"
    fi
}

# ── Check java availability ──────────────────────────────────────────────────

require_java() {
    if ! command -v java &>/dev/null; then
        die "java not found in PATH. Install JDK 11+ to use signing."
    fi
}

# ── Signing functions ────────────────────────────────────────────────────────

sign_profile() {
    local mode="${1:-$SIGN_MODE}"
    local output_file="${2:-}"
    local certs_dir
    certs_dir="$(resolve_sign_certs_dir)"
    local tc_dir
    tc_dir="$(resolve_sign_toolchain)"

    local tool_jar="$tc_dir/hap-sign-tool.jar"
    [ -f "$tool_jar" ] || die "hap-sign-tool.jar not found at $tc_dir"

    local profile_cert
    if [ "$mode" = "debug" ]; then
        profile_cert="$certs_dir/OpenHarmonyProfileDebug.pem"
    else
        profile_cert="$certs_dir/OpenHarmonyProfileRelease.pem"
    fi
    [ -f "$profile_cert" ] || die "Profile certificate not found: $profile_cert"

    local keystore="$certs_dir/OpenHarmony.p12"
    [ -f "$keystore" ] || die "Keystore not found: $keystore"

    local template
    template="$(resolve_profile_template "$mode")"
    [ -f "$template" ] || die "Profile template not found: $template"

    if [ -z "$output_file" ]; then
        local tmp_dir
        tmp_dir="$(mktemp -d /tmp/ohos-sign-XXXXXX)"
        output_file="$tmp_dir/app-profile.p7b"
    fi

    info "Signing profile ($mode) → $(basename "$output_file")"

    java -jar "$tool_jar" sign-profile \
        -mode localSign \
        -keyAlias "$(resolve_profile_key_alias "$mode")" \
        -keyPwd "$SIGN_KEY_PWD" \
        -profileCertFile "$profile_cert" \
        -inFile "$template" \
        -signAlg SHA256withECDSA \
        -keystoreFile "$keystore" \
        -keystorePwd "$SIGN_KEYSTORE_PWD" \
        -outFile "$output_file" \
        >&2

    [ -f "$output_file" ] || die "Profile signing failed: output not created"
    info "Profile signed: $output_file"
    printf '%s' "$output_file"
}

sign_app() {
    local input_hap="$1"
    local profile_p7b="$2"
    local output_file="${3:-}"
    local mode="${4:-$SIGN_MODE}"

    local certs_dir
    certs_dir="$(resolve_sign_certs_dir)"
    local tc_dir
    tc_dir="$(resolve_sign_toolchain)"

    local tool_jar="$tc_dir/hap-sign-tool.jar"
    [ -f "$tool_jar" ] || die "hap-sign-tool.jar not found at $tc_dir"

    local app_cert="$certs_dir/OpenHarmonyApplication.pem"
    [ -f "$app_cert" ] || die "Application certificate not found: $app_cert. Run 'ohos sign init' first."

    local keystore="$certs_dir/OpenHarmony.p12"
    [ -f "$keystore" ] || die "Keystore not found: $keystore"

    [ -f "$input_hap" ] || die "Input HAP not found: $input_hap"
    [ -f "$profile_p7b" ] || die "Profile P7B not found: $profile_p7b"

    if [ -z "$output_file" ]; then
        local base_name
        base_name="$(basename "$input_hap")"
        # Replace -unsigned with -signed, or append -signed
        if [[ "$base_name" == *-unsigned* ]]; then
            output_file="$(dirname "$input_hap")/${base_name/-unsigned/-signed}"
        else
            output_file="$(dirname "$input_hap")/${base_name%.*}-signed.${base_name##*.}"
        fi
    fi

    info "Signing app: $(basename "$input_hap") → $(basename "$output_file")"

    java -jar "$tool_jar" sign-app \
        -mode localSign \
        -keyAlias "$SIGN_KEY_ALIAS_APP" \
        -keyPwd "$SIGN_KEY_PWD" \
        -appCertFile "$app_cert" \
        -profileFile "$profile_p7b" \
        -inFile "$input_hap" \
        -signAlg SHA256withECDSA \
        -keystoreFile "$keystore" \
        -keystorePwd "$SIGN_KEYSTORE_PWD" \
        -outFile "$output_file" \
        -profileSigned "1" \
        -inForm "zip" \
        >&2

    [ -f "$output_file" ] || die "App signing failed: output not created"
    info "App signed: $output_file"
    printf '%s' "$output_file"
}

sign_auto() {
    local input_path="$1"
    local output_file="${2:-}"
    local mode="${3:-$SIGN_MODE}"

    # If directory, find unsigned HAPs
    local hap_files=()
    if [ -d "$input_path" ]; then
        while IFS= read -r -d '' f; do
            hap_files+=("$f")
        done < <(find "$input_path" -name '*-unsigned.hap' -print0 2>/dev/null)
        if [ ${#hap_files[@]} -eq 0 ]; then
            die "No unsigned HAP files found in $input_path"
        fi
        info "Found ${#hap_files[@]} unsigned HAP(s) in $input_path"
    else
        [ -f "$input_path" ] || die "Input not found: $input_path"
        hap_files=("$input_path")
    fi

    # Step 1: sign profile
    local profile_p7b
    profile_p7b="$(sign_profile "$mode")"

    # Step 2: sign each HAP
    local signed_files=()
    for hap in "${hap_files[@]}"; do
        local hap_output=""
        if [ -n "$output_file" ] && [ ${#hap_files[@]} -eq 1 ]; then
            hap_output="$output_file"
        fi
        local signed
        signed="$(sign_app "$hap" "$profile_p7b" "$hap_output" "$mode")"
        signed_files+=("$signed")
    done

    # Cleanup temp profile
    if [[ "$profile_p7b" == /tmp/ohos-sign-* ]]; then
        rm -f "$profile_p7b"
    fi

    info "All done. Signed: ${#signed_files[@]} file(s)"
    for f in "${signed_files[@]}"; do
        info "  → $f"
    done
}

verify_app() {
    local input_hap="$1"

    local tc_dir
    tc_dir="$(resolve_sign_toolchain)"
    local tool_jar="$tc_dir/hap-sign-tool.jar"
    [ -f "$tool_jar" ] || die "hap-sign-tool.jar not found at $tc_dir"
    [ -f "$input_hap" ] || die "Input HAP not found: $input_hap"

    info "Verifying: $input_hap"
    local verify_tmp
    verify_tmp="$(mktemp -d /tmp/ohos-verify-XXXXXX)"
    java -jar "$tool_jar" verify-app \
        -inFile "$input_hap" \
        -outCertChain "$verify_tmp/cert-chain.cer" \
        -outProfile "$verify_tmp/profile.p7b"
    local rc=$?
    if [ $rc -eq 0 ]; then
        info "Signature valid."
        info "  Cert chain: $verify_tmp/cert-chain.cer"
        info "  Profile:   $verify_tmp/profile.p7b"
    else
        err "Signature verification FAILED (exit code: $rc)"
    fi
    return $rc
}

init_certs() {
    local full="${1:-false}"
    local tc_dir
    tc_dir="$(resolve_sign_toolchain)"

    if [ -z "$tc_dir" ]; then
        die "No signing toolchain found. Download SDK first: ohos download sdk"
    fi

    info "Toolchain: $tc_dir"

    # Check what's missing
    local missing=()
    for f in hap-sign-tool.jar OpenHarmony.p12 OpenHarmonyProfileDebug.pem \
             OpenHarmonyProfileRelease.pem UnsgnedDebugProfileTemplate.json \
             UnsgnedReleasedProfileTemplate.json; do
        if [ ! -f "$tc_dir/$f" ]; then
            missing+=("$f")
        fi
    done

    # Check Application.pem separately (often missing from shared tools)
    local app_cert_missing=false
    if [ ! -f "$tc_dir/OpenHarmonyApplication.pem" ]; then
        missing+=("OpenHarmonyApplication.pem")
        app_cert_missing=true
    fi

    if [ ${#missing[@]} -eq 0 ]; then
        info "All signing files present. Nothing to do."
        return 0
    fi

    info "Missing: ${missing[*]}"

    # Try to copy from ohos_root
    local ohos_root
    ohos_root="$(resolve_ohos_root)"
    if [ -n "$ohos_root" ] && [ -d "$ohos_root/developtools/hapsigner/dist" ]; then
        local dist_dir="$ohos_root/developtools/hapsigner/dist"
        info "Copying missing files from $dist_dir"
        for f in "${missing[@]}"; do
            if [ -f "$dist_dir/$f" ]; then
                cp -v "$dist_dir/$f" "$tc_dir/$f"
                info "  Copied: $f"
            else
                warn "  Not found in dist: $f"
            fi
        done
    else
        warn "ohos_root not found. Cannot auto-copy missing files."
        if [ "$app_cert_missing" = true ]; then
            info "To get OpenHarmonyApplication.pem:"
            info "  1. Build OpenHarmony from source, or"
            info "  2. Extract from SDK toolchains zip, or"
            info "  3. Copy from developtools/hapsigner/dist/ if available"
        fi
    fi

    if [ "$full" = "true" ]; then
        info "Full certificate generation not yet implemented."
        info "Use autosign.py from developtools/hapsigner/autosign/ for full cert chain generation."
    fi

    # Summary
    local still_missing=()
    for f in "${missing[@]}"; do
        if [ ! -f "$tc_dir/$f" ]; then
            still_missing+=("$f")
        fi
    done
    if [ ${#still_missing[@]} -gt 0 ]; then
        warn "Still missing: ${still_missing[*]}"
        return 1
    fi
    info "All files ready."
}

# ── Help ─────────────────────────────────────────────────────────────────────

print_sign_help() {
    cat <<'EOF'
Usage: ohos sign <subcommand> [options]

Subcommands:
  init              Prepare signing certificates (copy from ohos_root)
  init --full       Prepare with full certificate chain generation
  profile           Sign a provisioning profile (JSON → P7B)
  app <file|dir>    Sign a HAP file or all unsigned HAPs in directory
  auto <file|dir>   Sign profile + app in one step
  verify <file>     Verify signature of a signed HAP

Options:
  --debug           Use debug certificates (default)
  --release         Use release certificates
  -o, --output FILE Output file path
  --mode MODE       Signing mode: debug|release (default: debug or SIGN_MODE config)
  -h, --help        Show this help

Config variables (ohos.conf):
  SIGN_TOOL_PATH        Path to toolchains/lib/ (auto-detected if empty)
  SIGN_KEYSTORE_PWD     Keystore password (default: 123456)
  SIGN_KEY_PWD          Key password (default: 123456)
  SIGN_MODE             Default mode: debug|release (default: debug)
  SIGN_PROFILE_TEMPLATE Custom profile template JSON path
  SIGN_KEY_ALIAS_APP    App key alias (default: OpenHarmony Application Release)
  SIGN_KEY_ALIAS_PROFILE Profile key alias

Examples:
  ohos sign init
  ohos sign auto ./entry/build/default/outputs/default/entry-default-unsigned.hap
  ohos sign auto ./entry/build/default/outputs/default/ --release
  ohos sign profile --release -o app-profile.p7b
  ohos sign app unsigned.hap --profile app-profile.p7b
  ohos sign verify entry-default-signed.hap
EOF
}

# ── Main dispatch ────────────────────────────────────────────────────────────

cmd_sign() {
    require_java

    if [ $# -eq 0 ]; then
        print_sign_help
        return 0
    fi

    local subcmd="$1"
    shift

    case "$subcmd" in
        help|--help|-h)
            print_sign_help
            ;;
        init)
            local full_init="false"
            if [ "${1:-}" = "--full" ]; then
                full_init="true"
            fi
            init_certs "$full_init"
            ;;
        profile)
            local profile_mode="$SIGN_MODE"
            local profile_output=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --debug)   profile_mode="debug"; shift ;;
                    --release) profile_mode="release"; shift ;;
                    -o|--output) profile_output="$2"; shift 2 ;;
                    *) die "profile: unknown option: $1" ;;
                esac
            done
            sign_profile "$profile_mode" "$profile_output"
            ;;
        app)
            local app_input=""
            local app_profile=""
            local app_output=""
            local app_mode="$SIGN_MODE"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --debug)    app_mode="debug"; shift ;;
                    --release)  app_mode="release"; shift ;;
                    -o|--output) app_output="$2"; shift 2 ;;
                    --profile)  app_profile="$2"; shift 2 ;;
                    --mode)     app_mode="$2"; shift 2 ;;
                    -*)
                        if [ -z "$app_input" ]; then
                            die "app: first positional arg must be the HAP file/directory"
                        fi
                        die "app: unknown option: $1"
                        ;;
                    *)
                        if [ -z "$app_input" ]; then
                            app_input="$1"
                        else
                            die "app: unexpected argument: $1"
                        fi
                        shift
                        ;;
                esac
            done
            [ -n "$app_input" ] || die "app: missing input HAP file or directory"

            if [ -z "$app_profile" ]; then
                info "No --profile specified, generating signed profile..."
                app_profile="$(sign_profile "$app_mode")"
            fi
            sign_app "$app_input" "$app_profile" "$app_output" "$app_mode"
            ;;
        auto)
            local auto_input=""
            local auto_output=""
            local auto_mode="$SIGN_MODE"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --debug)    auto_mode="debug"; shift ;;
                    --release)  auto_mode="release"; shift ;;
                    -o|--output) auto_output="$2"; shift 2 ;;
                    --mode)     auto_mode="$2"; shift 2 ;;
                    -*)
                        if [ -z "$auto_input" ]; then
                            die "auto: first positional arg must be the HAP file/directory"
                        fi
                        die "auto: unknown option: $1"
                        ;;
                    *)
                        if [ -z "$auto_input" ]; then
                            auto_input="$1"
                        else
                            die "auto: unexpected argument: $1"
                        fi
                        shift
                        ;;
                esac
            done
            [ -n "$auto_input" ] || die "auto: missing input HAP file or directory"
            sign_auto "$auto_input" "$auto_output" "$auto_mode"
            ;;
        verify)
            [ $# -ge 1 ] || die "verify: missing input HAP file"
            verify_app "$1"
            ;;
        *)
            die "Unknown sign subcommand: $subcmd"
            ;;
    esac
}

cmd_sign "$@"
