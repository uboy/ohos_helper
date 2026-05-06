#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fix-mirror-lfs-double-objects.sh
#
# Standalone script to clean up the git-lfs 3.0.2 double-objects path bug on
# the mirror server.  When lfs.storage was set to ".../lfs/objects", git-lfs
# resolved to ".../lfs/objects/objects" internally.  This script moves any
# files that landed in the double-nested path back to the correct single-level
# path.
#
# Usage:
#   sudo bash fix-mirror-lfs-double-objects.sh [/path/to/mirror]
#
# Default mirror root: /data/shared/ohos_mirror
# ---------------------------------------------------------------------------
set -euo pipefail

MIRROR_ROOT="${1:-/data/shared/ohos_mirror}"
REPOS_CLEANED=0
FILES_MOVED=0
ORPHANS=0

if [ ! -d "$MIRROR_ROOT" ]; then
    echo "ERROR: Mirror root does not exist: $MIRROR_ROOT" >&2
    exit 1
fi

echo "Scanning mirror repos under: $MIRROR_ROOT"
echo "---"

find "$MIRROR_ROOT" -type d -name "objects" -path "*/lfs/objects/objects" 2>/dev/null | while read -r double_dir; do
    # Derive the correct parent: strip trailing /objects
    single_dir="${double_dir%/objects}"

    if [ ! -d "$single_dir" ]; then
        echo "WARN: Expected parent directory missing: $single_dir (skipping)"
        ORPHANS=$((ORPHANS + 1))
        continue
    fi

    echo "Processing: $double_dir"
    moved=0
    orphan_files=0

    # Move all files from double_dir into single_dir, preserving structure
    # Using find + mv to handle nested subdirectories
    while IFS= read -r -d '' src_file; do
        rel="${src_file#"$double_dir"/}"
        dest="$single_dir/$rel"
        dest_dir="$(dirname "$dest")"

        if [ -e "$dest" ]; then
            # File already exists at destination — skip, don't overwrite
            echo "  SKIP (exists): $rel"
            orphan_files=$((orphan_files + 1))
            continue
        fi

        mkdir -p "$dest_dir"
        if mv "$src_file" "$dest"; then
            moved=$((moved + 1))
        else
            echo "  FAIL: $rel" >&2
            orphan_files=$((orphan_files + 1))
        fi
    done < <(find "$double_dir" -type f -print0 2>/dev/null)

    # Remove empty double_dir tree if possible
    if [ "$moved" -gt 0 ]; then
        # Remove empty dirs, leave non-empty ones alone
        find "$double_dir" -type d -empty -delete 2>/dev/null || true
    fi

    if [ -d "$double_dir" ]; then
        echo "  Note: double-objects dir still exists (non-empty or has remaining files)"
    fi

    echo "  Moved: $moved files, Skipped: $orphan_files files"
    REPOS_CLEANED=$((REPOS_CLEANED + 1))
    FILES_MOVED=$((FILES_MOVED + moved))
    ORPHANS=$((ORPHANS + orphan_files))
done

echo "---"
echo "Summary:"
echo "  Repos cleaned:  $REPOS_CLEANED"
echo "  Files moved:    $FILES_MOVED"
echo "  Skipped/failed: $ORPHANS"
