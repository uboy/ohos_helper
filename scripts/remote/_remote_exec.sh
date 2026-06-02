#!/bin/bash
# _remote_exec.sh — remote script template execution helper
# Sourced by ohos_device.sh. Provides _remote_exec() for executing
# template-based scripts on local or remote servers with safe variable
# substitution (no inline SSH quoting issues).
#
# Usage:
#   _remote_exec <server> <template_name> [key=value]...
#     server        — "local" for local execution, hostname for SSH
#     template_name — filename in scripts/remote/ without .sh.template
#     key=value     — placeholder substitutions (e.g., SERIAL=abc123)

_REMOTE_EXEC_TEMPLATE_DIR="${SCRIPT_DIR}/scripts/remote"

_remote_exec() {
    local server="$1"; shift
    local template_name="$1"; shift

    local template_file="${_REMOTE_EXEC_TEMPLATE_DIR}/${template_name}.sh.template"

    if [ ! -f "$template_file" ]; then
        err "Template not found: $template_file"
        return 1
    fi

    local work_file
    work_file="$(mktemp /tmp/ohos-remote-XXXXXX.sh)"

    # Copy template to work file
    cp "$template_file" "$work_file"

    # Apply substitutions — use | as sed delimiter (safe for paths)
    local kv
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        # Escape sed special chars in value (only & and \ matter in replacement)
        local escaped_val
        escaped_val="$(printf '%s' "$val" | sed 's/[&/|\\]/\\&/g')"
        sed -i "s|{{${key}}}|${escaped_val}|g" "$work_file"
    done

    # Verify no unresolved placeholders remain
    if grep -q '{{[A-Z_]*}}' "$work_file" 2>/dev/null; then
        err "Unresolved placeholders in $template_name:"
        grep '{{[A-Z_]*}}' "$work_file" >&2
        rm -f "$work_file"
        return 1
    fi

    chmod +x "$work_file"
    local rc=0

    if [ "$server" = "local" ]; then
        bash "$work_file" || rc=$?
    else
        local ssh_user="${OHOS_SSH_USER:-${USER:-$(whoami 2>/dev/null)}}"
        # Pipe script to remote bash via stdin — no file left on remote
        ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${server}" 'bash -s' < "$work_file" || rc=$?
    fi

    rm -f "$work_file"
    return $rc
}

# _remote_exec_out — same as _remote_exec but captures stdout
# Usage: result=$(_remote_exec_out <server> <template> [key=value]...)
_remote_exec_out() {
    local server="$1"; shift
    local template_name="$1"; shift

    local template_file="${_REMOTE_EXEC_TEMPLATE_DIR}/${template_name}.sh.template"

    if [ ! -f "$template_file" ]; then
        err "Template not found: $template_file"
        return 1
    fi

    local work_file
    work_file="$(mktemp /tmp/ohos-remote-XXXXXX.sh)"
    cp "$template_file" "$work_file"

    local kv
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        local escaped_val
        escaped_val="$(printf '%s' "$val" | sed 's/[&/|\\]/\\&/g')"
        sed -i "s|{{${key}}}|${escaped_val}|g" "$work_file"
    done

    chmod +x "$work_file"

    local output
    if [ "$server" = "local" ]; then
        output="$(bash "$work_file")"
    else
        local ssh_user="${OHOS_SSH_USER:-${USER:-$(whoami 2>/dev/null)}}"
        output="$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${server}" 'bash -s' < "$work_file")"
    fi

    local rc=$?
    rm -f "$work_file"
    printf '%s' "$output"
    return $rc
}

# _remote_exec_nfs — execute template on NFS, result to file
#
# Like _remote_exec_out but designed for NFS-first execution:
#   1. Substituted script written to NFS (accessible from both local and remote)
#   2. Executed as: ssh server "bash /nfs/path/script.sh"
#   3. Result read from NFS file (no stdout capture, no pipe blocking)
#
# Usage: _remote_exec_nfs <server> <template> <result_file> [key=value]...
#   result_file — NFS path where template writes its result
_remote_exec_nfs() {
    local server="$1"; shift
    local template_name="$1"; shift
    local result_file="$1"; shift

    local template_file="${_REMOTE_EXEC_TEMPLATE_DIR}/${template_name}.sh.template"

    if [ ! -f "$template_file" ]; then
        err "Template not found: $template_file"
        return 1
    fi

    # Write substituted script to NFS, next to result file
    local script_file="${result_file%.result.txt}.exec.sh"
    cp "$template_file" "$script_file"

    # Apply substitutions
    local kv
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        local escaped_val
        escaped_val="$(printf '%s' "$val" | sed 's/[&/|\\]/\\&/g')"
        sed -i "s|{{${key}}}|${escaped_val}|g" "$script_file"
    done

    # Verify no unresolved placeholders
    if grep -q '{{[A-Z_]*}}' "$script_file" 2>/dev/null; then
        err "Unresolved placeholders in $template_name:"
        grep '{{[A-Z_]*}}' "$script_file" >&2
        rm -f "$script_file"
        return 1
    fi

    chmod +x "$script_file"

    local rc=0

    if [ "$server" = "local" ]; then
        bash "$script_file" || rc=$?
    else
        local ssh_user="${OHOS_SSH_USER:-${USER:-$(whoami 2>/dev/null)}}"
        # Execute script via NFS path — no stdin pipe, no stdout capture
        ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${server}" "bash '$script_file'" || rc=$?
    fi

    # Cleanup script (keep result file for caller to read)
    rm -f "$script_file"

    return $rc
}
