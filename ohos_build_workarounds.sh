#!/bin/bash
# ohos_build_workarounds.sh — apply/revert PR patches for build targets
# Sourced by ohos.sh. Provides cmd_build_workarounds().
#
# Config: build-workarounds.yaml in the same directory.
# Each workaround is a PR to fetch+merge before building a target.

if [ -z "${BASH_VERSION:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

WORKAROUNDS_CONF="${WORKAROUNDS_CONF:-${OHOS_CONF_DIR:-${SCRIPT_DIR}/conf}/build-workarounds.yaml}"
WORKAROUNDS_STATE_DIR="${WORKAROUNDS_STATE_DIR:-${TMPDIR:-/tmp}/ohos-workarounds-state}"

# Parse YAML-like config to extract per-target workarounds.
# Returns line-based: repo|pr|remote|description per entry.
_parse_workarounds_for_target() {
    local target="$1"
    local in_target=false
    local repo="" pr="" remote="" desc="" optional="false"

    while IFS= read -r line; do
        local trimmed
        trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$trimmed" ] && continue
        [ "${trimmed:0:1}" = "#" ] && continue

        # Detect new YAML list item (starts with "- ") — emit previous entry
        if [ "$in_target" = true ] && [[ "$trimmed" == -* ]] && [ -n "$repo" ]; then
            printf '%s|%s|%s|%s|%s\n' "$repo" "$pr" "$remote" "$desc" "$optional"
            repo=""; pr=""; remote=""; desc=""; optional="false"
        fi

        # Detect target key line (e.g. "xts-static:") — capture group BEFORE any other =~
        local matched_target=""
        if [[ "$trimmed" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
            matched_target="${BASH_REMATCH[1]}"
        fi
        if [ -n "$matched_target" ] && [[ ! "$trimmed" =~ :\  ]]; then
            if [ "$in_target" = true ] && [ -n "$repo" ]; then
                printf '%s|%s|%s|%s|%s\n' "$repo" "$pr" "$remote" "$desc" "$optional"
                repo=""; pr=""; remote=""; desc=""; optional="false"
            fi
            in_target=false
            [ "$matched_target" = "$target" ] && in_target=true
            continue
        fi

        if [ "$in_target" = true ]; then
            local t="$trimmed"
            [[ "$t" == -* ]] && t="${t#- }"
            case "$t" in
                repo:*) repo="$(printf '%s' "$t" | sed 's/^repo:[[:space:]]*//')" ;;
                pr:*) pr="$(printf '%s' "$t" | sed 's/^pr:[[:space:]]*//')" ;;
                remote:*) remote="$(printf '%s' "$t" | sed 's/^remote:[[:space:]]*//')" ;;
                description:*) desc="$(printf '%s' "$t" | sed 's/^description:[[:space:]]*//;s/^"//;s/"$//')" ;;
                optional:*) optional="$(printf '%s' "$t" | sed 's/^optional:[[:space:]]*//')" ;;
            esac
        fi
    done < "$WORKAROUNDS_CONF"

    # Last entry
    if [ -n "$repo" ]; then
        printf '%s|%s|%s|%s|%s\n' "$repo" "$pr" "$remote" "$desc" "$optional"
    fi
}

# Apply workarounds for a build target.
apply_build_workarounds() {
    local target="$1"
    local repo_root="${2:-$(pwd)}"
    local applied=0
    local skipped=0
    local failed=0
    local save_cwd
    save_cwd="$(pwd)"

    [ -f "$WORKAROUNDS_CONF" ] || { info "No workarounds config at $WORKAROUNDS_CONF"; return 0; }

    # Initialize state directory
    mkdir -p "$WORKAROUNDS_STATE_DIR"
    local state_file="${WORKAROUNDS_STATE_DIR}/${target}.state"
    : > "$state_file"

    info "Applying build workarounds for target: $target"

    while IFS='|' read -r repo pr remote desc optional; do
        [ -z "$repo" ] && continue
        local repo_path="${repo_root}/${repo}"

        if [ ! -d "$repo_path/.git" ]; then
            if [ "$optional" = "true" ]; then
                warn "Workaround repo $repo not found (optional), skipping"
                skipped=$((skipped + 1))
                continue
            else
                err "Workaround repo $repo not found"
                failed=$((failed + 1))
                continue
            fi
        fi

        local ref_name="pr_${pr}"

        # Enter repo, do git work, then return to saved CWD
        cd "$repo_path" 2>/dev/null || continue

        # Check if PR is already applied
        if git log --oneline -1 "$ref_name" 2>/dev/null | grep -q .; then
            info "  PR #$pr in $repo — already fetched"
            if git merge-base --is-ancestor "$ref_name" HEAD 2>/dev/null; then
                info "  PR #$pr in $repo — already merged, skipping"
                cd "$save_cwd"
                skipped=$((skipped + 1))
                continue
            fi
        fi

        info "  Fetching PR #$pr → $repo..."
        if ! git fetch "$remote" "+refs/merge-requests/${pr}/head:${ref_name}" 2>&1 | tail -1; then
            cd "$save_cwd"
            if [ "$optional" = "true" ]; then
                warn "  Failed to fetch PR #$pr in $repo (optional), skipping"
                skipped=$((skipped + 1))
                continue
            else
                err "  Failed to fetch PR #$pr in $repo"
                failed=$((failed + 1))
                continue
            fi
        fi

        # Save pre-merge state for revert
        local pre_sha
        pre_sha="$(git rev-parse HEAD 2>/dev/null)"
        echo "${repo}|${pre_sha}" >> "$state_file"

        info "  Merging PR #$pr → $repo..."
        if ! git merge "$ref_name" --no-edit 2>&1 | tail -1; then
            git merge --abort 2>/dev/null || true
            cd "$save_cwd"
            if [ "$optional" = "true" ]; then
                warn "  Failed to merge PR #$pr in $repo (optional), skipping"
                skipped=$((skipped + 1))
                continue
            else
                err "  Failed to merge PR #$pr in $repo"
                failed=$((failed + 1))
                continue
            fi
        fi

        info "  ✓ PR #$pr applied in $repo"
        applied=$((applied + 1))
        cd "$save_cwd"
    done < <(_parse_workarounds_for_target "$target")

    info "Workarounds: $applied applied, $skipped skipped, $failed failed"
    [ "$failed" -gt 0 ] && return 1
    return 0
}

# Revert workarounds using saved state.
revert_build_workarounds() {
    local target="$1"
    local repo_root="${2:-$(pwd)}"
    local state_file="${WORKAROUNDS_STATE_DIR}/${target}.state"
    local save_cwd
    save_cwd="$(pwd)"

    [ -f "$state_file" ] || { info "No state to revert for target: $target"; return 0; }

    info "Reverting build workarounds for target: $target"

    while IFS='|' read -r repo pre_sha; do
        [ -z "$repo" ] && continue
        local repo_path="${repo_root}/${repo}"
        [ ! -d "$repo_path/.git" ] && continue

        cd "$repo_path" 2>/dev/null || continue
        local current_sha
        current_sha="$(git rev-parse HEAD 2>/dev/null)"

        if [ "$current_sha" != "$pre_sha" ]; then
            info "  Resetting $repo to $pre_sha..."
            git reset --hard "$pre_sha" 2>&1 | tail -1
            info "  ✓ Reverted $repo"
        else
            info "  $repo already at saved state, skipping"
        fi

        cd "$save_cwd"
    done < "$state_file"

    rm -f "$state_file"
    info "Workarounds reverted"
}

# Restore original prebuilts hvigor if it was swapped.
# Call this during revert to undo the CI hvigor swap.
restore_hvigor_orig() {
    local hv_dst="$(pwd)/prebuilts/command-line-tools/hvigor"
    local hv_orig="$(pwd)/prebuilts/command-line-tools/hvigor.orig"

    if [ -L "$hv_dst" ] && [ -d "$hv_orig" ]; then
        info "Restoring original hvigor..."
        rm -f "$hv_dst"
        mv "$hv_orig" "$hv_dst"
        info "Original hvigor restored"
    fi
}


# Swap prebuilts hvigor with the CI hvigor from debug2 branch.
# CI preCompile does: git clone -b debug2 https://gitcode.com/li-ke1067/hvigor0702.git
# The debug2 branch has critical fixes:
#   - compileSdkVersion accepts string or number (fixes schema validation)
#   - ETS1_1="dynamic", ETS1_2="static" (correct SDK dir mapping)
#   - process-profile.js rewrite (+266 lines)
# Saves the original as hvigor.orig; safe to re-apply.
swap_hvigor_ci() {
    local hv_src="${OHOS_TOOLS_DIR:-}/hvigor-ci/hvigor"
    local hv_dst="$(pwd)/prebuilts/command-line-tools/hvigor"
    local hv_orig="$(pwd)/prebuilts/command-line-tools/hvigor.orig"

    [ -d "$hv_src" ] || { info "CI hvigor (debug2) not found at $hv_src, skipping"; return 0; }
    [ -d "$hv_dst" ] || { info "hvigor target missing at $hv_dst, skipping"; return 0; }

    if [ -L "$hv_dst" ] && [ "$(readlink "$hv_dst")" = "$hv_src" ]; then
        info "CI hvigor (debug2) already in place, skipping"
        return 0
    fi

    info "Swapping prebuilts hvigor with CI hvigor (debug2 branch)..."
    if [ ! -d "$hv_orig" ]; then
        mv "$hv_dst" "$hv_orig"
    else
        rm -rf "$hv_dst"
    fi
    ln -sf "$hv_src" "$hv_dst"
    info "CI hvigor (debug2) swapped in"
}


cmd_build_workarounds() {
    local subcmd="${1:-help}"
    [ $# -gt 0 ] && shift

    case "$subcmd" in
        help|--help|-h|"")
            cat <<HELP
build-workarounds - manage PR patches required for build targets

Subcommands:
  list                          Show all targets and their PR workarounds
  apply <target> [--repo-root <path>]  Apply workarounds for a build target
  revert <target> [--repo-root <path>] Revert workarounds for a build target

Config file: $WORKAROUNDS_CONF

Examples:
  ohos build-workarounds list
  ohos build-workarounds apply xts-static
  ohos build-workarounds revert xts-static
HELP
            ;;
        list)
            echo "Build workarounds config: $WORKAROUNDS_CONF"
            echo ""
            local current_target=""
            local line repo pr desc
            for target in $(grep -oP '^[a-zA-Z0-9_-]+(?=:)' "$WORKAROUNDS_CONF"); do
                echo "  [$target]"
                _parse_workarounds_for_target "$target" 2>/dev/null | while IFS='|' read -r r p _ d _; do
                    echo "    PR #$p → $r"
                    [ -n "$d" ] && echo "      $d"
                done
                echo ""
            done
            ;;
        apply)
            local target=""
            local repo_root="$(pwd)"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --repo-root) shift; repo_root="${1:-}"; shift || true ;;
                    *) target="$1"; shift ;;
                esac
            done
            [ -z "$target" ] && { err "apply requires a target"; return 1; }
            require_ohos_repo
            apply_build_workarounds "$target" "$repo_root"
            if [ "$target" = "xts-static" ]; then
                swap_hvigor_ci
            fi
            ;;
        revert)
            local target=""
            local repo_root="$(pwd)"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --repo-root) shift; repo_root="${1:-}"; shift || true ;;
                    *) target="$1"; shift ;;
                esac
            done
            [ -z "$target" ] && { err "revert requires a target"; return 1; }
            require_ohos_repo
            revert_build_workarounds "$target" "$repo_root"
            ;;
        *)
            err "build-workarounds: unknown subcommand: $subcmd"
            return 1
            ;;
    esac
}
