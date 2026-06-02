#!/bin/bash
# ohos-shared-env.sh — shared umask + group for multi-user environments
# Sourced by ohos.sh, ohos_device.sh, ohos_download.sh after ohos.conf.
#
# Applies OHOS_SHARED_UMASK and switches the primary group to OHOS_SHARED_GROUP
# via `sg` re-exec (no sudo needed). Guarded by _OHOS_SG_DONE to prevent loops.

# --- umask --------------------------------------------------------------------
if [ -n "${OHOS_SHARED_UMASK:-}" ]; then
    umask "$OHOS_SHARED_UMASK"
fi

# --- primary group switch via sg ----------------------------------------------
if [ -n "${OHOS_SHARED_GROUP:-}" ] && [ "${_OHOS_SG_DONE:-0}" != "1" ]; then
    _target_gid=""
    if command -v getent >/dev/null 2>&1; then
        _target_gid="$(getent group "$OHOS_SHARED_GROUP" 2>/dev/null | cut -d: -f3)" || true
    fi

    if [ -n "$_target_gid" ]; then
        _current_gid="$(id -g 2>/dev/null || true)"
        if [ -n "$_current_gid" ] && [ "$_current_gid" != "$_target_gid" ]; then
            if command -v sg >/dev/null 2>&1; then
                export _OHOS_SG_DONE=1
                # shellcheck disable=SC2086
                exec sg "$OHOS_SHARED_GROUP" -c "$0 $*"
            else
                echo "[ohos-shared-env] WARNING: sg command not found; cannot switch group to '$OHOS_SHARED_GROUP'" >&2
            fi
        fi
    else
        echo "[ohos-shared-env] WARNING: group '$OHOS_SHARED_GROUP' not found on this system" >&2
    fi
fi

unset _target_gid _current_gid 2>/dev/null || true
