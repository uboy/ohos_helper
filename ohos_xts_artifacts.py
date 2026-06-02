#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
ARKUI_XTS_SELECTOR_DIR = Path(
    os.environ.get("ARKUI_XTS_SELECTOR_DIR") or (SCRIPT_DIR / "arkui-xts-selector")
).expanduser().resolve()
SELECTOR_SRC_DIR = ARKUI_XTS_SELECTOR_DIR / "src"
DEFAULT_REPORT_FILE = "arkui_xts_selector_report.json"

if str(SELECTOR_SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SELECTOR_SRC_DIR))

from arkui_xts_selector.daily_prebuilt import (  # noqa: E402
    DEFAULT_DAILY_CACHE_ROOT,
    DEFAULT_DAILY_COMPONENT,
    DEFAULT_FIRMWARE_COMPONENT,
    DEFAULT_FIRMWARE_CACHE_ROOT,
    DEFAULT_SDK_COMPONENT,
    DEFAULT_SDK_CACHE_ROOT,
    PreparedDailyArtifact,
    PreparedDailyPrebuilt,
    derive_date_from_tag,
    fetch_available_components,
    is_placeholder_metadata,
    list_daily_tags,
    prepare_daily_firmware,
    prepare_daily_generic,
    prepare_daily_prebuilt,
    prepare_daily_sdk,
    resolve_daily_build,
)
from arkui_xts_selector.utility_modes import write_and_render_utility_report as _render_report  # noqa: E402

# ---------------------------------------------------------------------------
# Artifact type registry
# ---------------------------------------------------------------------------
# Each entry maps a CLI download type to:
#   component_default — DCP API component name
#   role              — component_role for resolve_daily_build
#   prepare           — "prebuilt" | "sdk" | "firmware" | "generic"
#   cache_default     — default cache root

ARTIFACT_TYPES: dict[str, dict[str, Any]] = {
    "tests": {
        "component_default": DEFAULT_DAILY_COMPONENT,
        "role": "xts",
        "prepare": "prebuilt",
        "cache_default": DEFAULT_DAILY_CACHE_ROOT,
    },
    "xts-acts": {
        "component_default": "dayu200_xts_acts",
        "role": "generic",
        "prepare": "generic",
        "cache_default": DEFAULT_DAILY_CACHE_ROOT,
    },
    "sdk": {
        "component_default": DEFAULT_SDK_COMPONENT,
        "role": "sdk",
        "prepare": "sdk",
        "cache_default": DEFAULT_SDK_CACHE_ROOT,
    },
    "firmware": {
        "component_default": DEFAULT_FIRMWARE_COMPONENT,
        "role": "firmware",
        "prepare": "firmware",
        "cache_default": DEFAULT_FIRMWARE_CACHE_ROOT,
    },
    "host-tools": {
        "component_default": "ohos-host",
        "role": "generic",
        "prepare": "generic",
        "cache_default": DEFAULT_DAILY_CACHE_ROOT,
    },
}

ALL_DOWNLOAD_TYPES = tuple(ARTIFACT_TYPES.keys())


def emit_progress(enabled: bool, message: str) -> None:
    if not enabled:
        return
    text = " ".join(str(message).strip().split())
    if text:
        print(f"phase: {text}")


def emit_subprogress(enabled: bool, label: str, message: str) -> None:
    if not enabled:
        return
    text = " ".join(str(message).strip().split())
    if text:
        print(f"{label}: {text}")


# ---------------------------------------------------------------------------
# list-components
# ---------------------------------------------------------------------------

def run_list_components_mode(args: argparse.Namespace) -> int:
    build_date = args.date or None
    branch = args.branch or "master"
    print(f"Available CI components (branch={branch}, date={build_date or 'today'}):")
    try:
        components = fetch_available_components(
            branch=branch,
            build_date=build_date,
        )
    except Exception as exc:
        print(f"error: failed to fetch component list: {exc}", file=sys.stderr)
        return 2

    if not components:
        print("  (no components found)")
        return 0

    for comp in components:
        flags = []
        if comp["has_package"]:
            flags.append("package")
        if comp["has_image"]:
            flags.append("image")
        flag_str = f"  [{', '.join(flags)}]" if flags else ""
        tag_str = f"  latest: {comp['tag']}" if comp["tag"] else ""
        ver_str = f"  v={comp['version_name']}" if comp["version_name"] else ""
        print(f"  {comp['component']}{flag_str}{ver_str}{tag_str}")
    return 0


# ---------------------------------------------------------------------------
# list-tags
# ---------------------------------------------------------------------------

def run_list_tags_mode(args: argparse.Namespace) -> int:
    tag_type = (args.tag_type or "tests").lower().strip()

    if tag_type not in ARTIFACT_TYPES:
        print(f"error: unknown tag type '{tag_type}'. Choose from: {', '.join(ALL_DOWNLOAD_TYPES)}", file=sys.stderr)
        return 2

    info = ARTIFACT_TYPES[tag_type]

    if tag_type == "sdk":
        component = args.sdk_component
        branch = args.sdk_branch
    elif tag_type == "firmware":
        component = args.firmware_component
        branch = args.firmware_branch
    else:
        # tests uses daily argparse defaults; generic types use registry defaults
        if tag_type == "tests":
            component = args.daily_component
        else:
            component = info["component_default"]
        # Allow --component override for any type
        if hasattr(args, "component_override") and args.component_override:
            component = args.component_override
        branch = args.daily_branch

    label = tag_type
    component_role = info["role"]

    count = max(1, args.list_tags_count)
    after_date = args.list_tags_after or None
    before_date = args.list_tags_before or None
    lookback = max(1, args.list_tags_lookback)

    date_range_note = ""
    if after_date or before_date:
        date_range_note = f", date filter: {after_date or '...'} – {before_date or 'today'}"
    print(f"Listing {count} most recent {label} tags (component={component}, branch={branch}{date_range_note}):")
    try:
        builds = list_daily_tags(
            component=component,
            branch=branch,
            count=count,
            after_date=after_date,
            before_date=before_date,
            lookback_days=lookback,
            component_role=component_role,
        )
    except Exception as exc:
        print(f"error: failed to fetch tag list: {exc}", file=sys.stderr)
        return 2

    if not builds:
        print("  (no builds found in the specified date range)")
        return 0

    for build in builds:
        extra = []
        if not is_placeholder_metadata(build.version_name):
            extra.append(build.version_name)
        if not is_placeholder_metadata(build.hardware_board):
            extra.append(build.hardware_board)
        suffix = f"  [{', '.join(extra)}]" if extra else ""
        print(f"  {build.tag}{suffix}")
    return 0


# ---------------------------------------------------------------------------
# download — specialized prepare functions (backward compatible)
# ---------------------------------------------------------------------------

def prepare_tests_from_args(args: argparse.Namespace) -> PreparedDailyPrebuilt:
    build = resolve_daily_build(
        component=args.daily_component,
        build_tag=args.daily_build_tag,
        branch=args.daily_branch,
        build_date=args.daily_date,
        component_role="xts",
    )
    return prepare_daily_prebuilt(
        build=build,
        cache_root=args.daily_cache_root or DEFAULT_DAILY_CACHE_ROOT,
    )


def prepare_sdk_from_args(args: argparse.Namespace) -> PreparedDailyArtifact:
    if not args.sdk_build_tag and not args.sdk_date:
        raise ValueError("sdk build tag or sdk date is required; provide --sdk-build-tag or --sdk-date")
    build = resolve_daily_build(
        component=args.sdk_component,
        build_tag=args.sdk_build_tag,
        branch=args.sdk_branch,
        build_date=args.sdk_date,
        component_role="sdk",
    )
    return prepare_daily_sdk(
        build=build,
        cache_root=args.sdk_cache_root or DEFAULT_SDK_CACHE_ROOT,
    )


def prepare_firmware_from_args(args: argparse.Namespace) -> PreparedDailyArtifact:
    if not args.firmware_build_tag and not args.firmware_date:
        raise ValueError("firmware build tag or firmware date is required; provide --firmware-build-tag or --firmware-date")
    build = resolve_daily_build(
        component=args.firmware_component,
        build_tag=args.firmware_build_tag,
        branch=args.firmware_branch,
        build_date=args.firmware_date,
        component_role="firmware",
    )
    return prepare_daily_firmware(
        build=build,
        cache_root=args.firmware_cache_root or DEFAULT_FIRMWARE_CACHE_ROOT,
    )


def prepare_generic_from_args(args: argparse.Namespace, download_type: str) -> PreparedDailyArtifact:
    info = ARTIFACT_TYPES[download_type]
    build_tag = args.daily_build_tag
    build_date = args.daily_date
    component = getattr(args, "component_override", None) or info["component_default"]

    if not build_tag and not build_date:
        raise ValueError(f"{download_type} build tag or date is required; provide --daily-build-tag or --daily-date")

    build = resolve_daily_build(
        component=component,
        build_tag=build_tag,
        branch=args.daily_branch,
        build_date=build_date,
        component_role=info["role"],
    )
    return prepare_daily_generic(
        build=build,
        cache_root=args.daily_cache_root or info["cache_default"],
        role=download_type,
    )


def resolve_local_firmware_root(path_value: str | Path) -> Path:
    candidate = Path(path_value).expanduser().resolve()
    if not candidate.exists():
        raise FileNotFoundError(f"firmware path does not exist: {candidate}")
    if candidate.is_dir():
        required = ("config.cfg", "parameter.txt")
        if all((candidate / name).exists() for name in required):
            return candidate
        discovered = sorted(path for path in candidate.rglob("config.cfg") if (path.parent / "parameter.txt").exists())
        if discovered:
            return discovered[0].parent.resolve()
    raise ValueError("firmware path must point to an unpacked image bundle root or a directory containing one")


# ---------------------------------------------------------------------------
# download dispatch
# ---------------------------------------------------------------------------

def run_download_mode(args: argparse.Namespace) -> int:
    report: dict[str, Any] = {"mode": "utility", "operations": {}}
    exit_code = 0
    download_type = args.download_type

    try:
        if download_type == "tests":
            emit_progress(args.progress, f"downloading daily tests {args.daily_build_tag or ''}".strip())
            prepared = prepare_tests_from_args(args)
            report["operations"]["download_daily_tests"] = {
                **prepared.to_dict(),
                "role": "tests",
                "package_kind": "full",
                "status": "ready" if prepared.acts_out_root else "extracted",
                "primary_root": str(prepared.acts_out_root) if prepared.acts_out_root else "",
            }
        elif download_type == "sdk":
            emit_progress(args.progress, f"downloading daily sdk {args.sdk_build_tag or ''}".strip())
            report["operations"]["download_daily_sdk"] = prepare_sdk_from_args(args).to_dict()
        elif download_type == "firmware":
            emit_progress(args.progress, f"downloading daily firmware {args.firmware_build_tag or ''}".strip())
            report["operations"]["download_daily_firmware"] = prepare_firmware_from_args(args).to_dict()
        else:
            # All generic types
            tag = args.daily_build_tag or ""
            emit_progress(args.progress, f"downloading daily {download_type} {tag}".strip())
            report["operations"][f"download_daily_{download_type}"] = prepare_generic_from_args(args, download_type).to_dict()
    except (OSError, ValueError, FileNotFoundError, urllib.error.URLError) as exc:
        report["operations"][f"download_daily_{download_type}"] = {"status": "failed", "error": str(exc)}
        exit_code = 2

    _render_report(report, json_to_stdout=args.json, json_output_path=args.json_out)
    return exit_code


# ---------------------------------------------------------------------------
# argparse
# ---------------------------------------------------------------------------

def add_common_daily_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--daily-build-tag")
    parser.add_argument("--daily-component", default=DEFAULT_DAILY_COMPONENT)
    parser.add_argument("--daily-branch", default="master")
    parser.add_argument("--daily-date")
    parser.add_argument("--daily-cache-root", type=Path, default=DEFAULT_DAILY_CACHE_ROOT)
    parser.add_argument("--sdk-build-tag")
    parser.add_argument("--sdk-component", default=DEFAULT_SDK_COMPONENT)
    parser.add_argument("--sdk-branch", default="master")
    parser.add_argument("--sdk-date")
    parser.add_argument("--sdk-cache-root", type=Path, default=DEFAULT_SDK_CACHE_ROOT)
    parser.add_argument("--firmware-build-tag")
    parser.add_argument("--firmware-component", default=DEFAULT_FIRMWARE_COMPONENT)
    parser.add_argument("--firmware-branch", default="master")
    parser.add_argument("--firmware-date")
    parser.add_argument("--firmware-cache-root", type=Path, default=DEFAULT_FIRMWARE_CACHE_ROOT)
    parser.add_argument("--component", dest="component_override",
                        help="Override the DCP component name for any download type")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--progress", dest="progress", action="store_true", default=True)
    parser.add_argument("--no-progress", dest="progress", action="store_false")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download daily artifacts and flash firmware without routing through the selector CLI."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # download <type>
    download_parser = subparsers.add_parser("download", help="download daily build artifacts")
    add_common_daily_options(download_parser)
    download_parser.add_argument("download_type", choices=ALL_DOWNLOAD_TYPES)

    # list-tags [type]
    list_parser = subparsers.add_parser("list-tags", help="list recent daily build tags")
    add_common_daily_options(list_parser)
    list_parser.add_argument("tag_type", nargs="?", default="tests", choices=ALL_DOWNLOAD_TYPES)
    list_parser.add_argument("--list-tags-count", type=int, default=15)
    list_parser.add_argument("--list-tags-after")
    list_parser.add_argument("--list-tags-before")
    list_parser.add_argument("--list-tags-lookback", type=int, default=30)

    # list-components
    lc_parser = subparsers.add_parser("list-components", help="list available CI components")
    lc_parser.add_argument("--date", help="Date to query (YYYYMMDD or YYYY-MM-DD, default: today)")
    lc_parser.add_argument("--branch", default="master")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "download":
        return run_download_mode(args)
    if args.command == "list-tags":
        return run_list_tags_mode(args)
    if args.command == "list-components":
        return run_list_components_mode(args)
    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
