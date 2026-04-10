#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
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
    DEFAULT_SDK_COMPONENT,
    PreparedDailyArtifact,
    PreparedDailyPrebuilt,
    derive_date_from_tag,
    is_placeholder_metadata,
    list_daily_tags,
    prepare_daily_firmware,
    prepare_daily_prebuilt,
    prepare_daily_sdk,
    resolve_daily_build,
)
from arkui_xts_selector.flashing import flash_image_bundle  # noqa: E402


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


def resolve_json_output_path(path_value: str | None) -> Path:
    if path_value:
        return Path(path_value).expanduser().resolve()
    return (Path.cwd() / DEFAULT_REPORT_FILE).resolve()


def write_json_report(report: dict[str, Any], json_to_stdout: bool, json_output_path: Path | None) -> Path | None:
    if json_to_stdout:
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return None

    target = resolve_json_output_path(str(json_output_path) if json_output_path else None)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return target


def write_and_render_utility_report(
    report: dict[str, Any],
    *,
    json_to_stdout: bool,
    json_output_path: Path | None,
) -> None:
    written_json_path = write_json_report(report, json_to_stdout=json_to_stdout, json_output_path=json_output_path)
    if json_to_stdout:
        return
    print("utility_mode: daily_artifacts")
    for name, payload in report.get("operations", {}).items():
        status = payload.get("status", "")
        print(f"{name}: {status}")
        if payload.get("error"):
            print(f"  error: {payload['error']}")
        for key in ("tag", "component", "role", "package_kind", "archive_path", "extracted_root", "primary_root"):
            value = payload.get(key)
            if value:
                print(f"  {key}: {value}")
        if payload.get("output_tail"):
            print("  output_tail:")
            for line in str(payload["output_tail"]).splitlines():
                print(f"    {line}")
    if written_json_path is not None:
        print(f"json_output_path: {written_json_path}")


def run_list_tags_mode(args: argparse.Namespace) -> int:
    tag_type = (args.tag_type or "tests").lower().strip()
    if tag_type == "sdk":
        component = args.sdk_component
        branch = args.sdk_branch
        label = "SDK"
    elif tag_type == "firmware":
        component = args.firmware_component
        branch = args.firmware_branch
        label = "firmware"
    else:
        component = args.daily_component
        branch = args.daily_branch
        label = "XTS tests"

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
        cache_root=args.sdk_cache_root or DEFAULT_DAILY_CACHE_ROOT,
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
        cache_root=args.firmware_cache_root or DEFAULT_DAILY_CACHE_ROOT,
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


def run_download_mode(args: argparse.Namespace) -> int:
    report: dict[str, Any] = {"mode": "utility", "operations": {}}
    exit_code = 0

    try:
        if args.download_type == "tests":
            emit_progress(args.progress, f"downloading daily tests {args.daily_build_tag or ''}".strip())
            prepared = prepare_tests_from_args(args)
            report["operations"]["download_daily_tests"] = {
                **prepared.to_dict(),
                "role": "tests",
                "package_kind": "full",
                "status": "ready" if prepared.acts_out_root else "extracted",
                "primary_root": str(prepared.acts_out_root) if prepared.acts_out_root else "",
            }
        elif args.download_type == "sdk":
            emit_progress(args.progress, f"downloading daily sdk {args.sdk_build_tag or ''}".strip())
            report["operations"]["download_daily_sdk"] = prepare_sdk_from_args(args).to_dict()
        else:
            emit_progress(args.progress, f"downloading daily firmware {args.firmware_build_tag or ''}".strip())
            report["operations"]["download_daily_firmware"] = prepare_firmware_from_args(args).to_dict()
    except (OSError, ValueError, FileNotFoundError, urllib.error.URLError) as exc:
        report["operations"][f"download_daily_{args.download_type}"] = {"status": "failed", "error": str(exc)}
        exit_code = 2

    write_and_render_utility_report(report, json_to_stdout=args.json, json_output_path=args.json_out)
    return exit_code


def run_flash_mode(args: argparse.Namespace) -> int:
    report: dict[str, Any] = {"mode": "utility", "operations": {}}
    exit_code = 0
    firmware_prepared: PreparedDailyArtifact | None = None

    try:
        if args.flash_firmware_path:
            emit_progress(args.progress, f"flashing local firmware {args.flash_firmware_path}")
            image_root = resolve_local_firmware_root(args.flash_firmware_path)
            flash_result = flash_image_bundle(
                image_root=image_root,
                flash_py_path=args.flash_py_path,
                hdc_path=args.hdc_path,
                device=args.device,
                progress_callback=(lambda message: emit_subprogress(args.progress, "flash", message)),
            )
            report["operations"]["flash_local_firmware"] = {
                **flash_result.to_dict(),
                "requested_path": str(args.flash_firmware_path),
            }
            if flash_result.status != "completed":
                exit_code = 1
        else:
            emit_progress(args.progress, f"downloading daily firmware {args.firmware_build_tag or ''}".strip())
            firmware_prepared = prepare_firmware_from_args(args)
            report["operations"]["download_daily_firmware"] = firmware_prepared.to_dict()

            emit_progress(args.progress, "flashing daily firmware")
            if firmware_prepared.primary_root is None:
                raise ValueError("no flashable image root was discovered in the firmware package")
            flash_result = flash_image_bundle(
                image_root=firmware_prepared.primary_root,
                flash_py_path=args.flash_py_path,
                hdc_path=args.hdc_path,
                device=args.device,
                progress_callback=(lambda message: emit_subprogress(args.progress, "flash", message)),
            )
            report["operations"]["flash_daily_firmware"] = flash_result.to_dict()
            if flash_result.status != "completed":
                exit_code = 1
    except (OSError, ValueError, FileNotFoundError, RuntimeError, subprocess.TimeoutExpired, urllib.error.URLError) as exc:
        operation_name = "flash_local_firmware" if args.flash_firmware_path else "flash_daily_firmware"
        payload: dict[str, Any] = {"status": "failed", "error": str(exc)}
        if args.flash_firmware_path:
            payload["requested_path"] = str(args.flash_firmware_path)
        report["operations"][operation_name] = payload
        exit_code = 2

    write_and_render_utility_report(report, json_to_stdout=args.json, json_output_path=args.json_out)
    return exit_code


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
    parser.add_argument("--sdk-cache-root", type=Path, default=DEFAULT_DAILY_CACHE_ROOT)
    parser.add_argument("--firmware-build-tag")
    parser.add_argument("--firmware-component", default=DEFAULT_FIRMWARE_COMPONENT)
    parser.add_argument("--firmware-branch", default="master")
    parser.add_argument("--firmware-date")
    parser.add_argument("--firmware-cache-root", type=Path, default=DEFAULT_DAILY_CACHE_ROOT)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--progress", dest="progress", action="store_true", default=True)
    parser.add_argument("--no-progress", dest="progress", action="store_false")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download daily artifacts and flash firmware without routing through the selector CLI."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    download_parser = subparsers.add_parser("download", help="download daily tests, SDK, or firmware")
    add_common_daily_options(download_parser)
    download_parser.add_argument("download_type", choices=("tests", "sdk", "firmware"))

    list_parser = subparsers.add_parser("list-tags", help="list recent daily build tags")
    add_common_daily_options(list_parser)
    list_parser.add_argument("tag_type", nargs="?", default="tests", choices=("tests", "sdk", "firmware"))
    list_parser.add_argument("--list-tags-count", type=int, default=10)
    list_parser.add_argument("--list-tags-after")
    list_parser.add_argument("--list-tags-before")
    list_parser.add_argument("--list-tags-lookback", type=int, default=30)

    flash_parser = subparsers.add_parser("flash", help="download and flash firmware, or flash a local image bundle")
    add_common_daily_options(flash_parser)
    flash_parser.add_argument("--flash-firmware-path")
    flash_parser.add_argument("--flash-py-path")
    flash_parser.add_argument("--hdc-path")
    flash_parser.add_argument("--device")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "download":
        return run_download_mode(args)
    if args.command == "list-tags":
        return run_list_tags_mode(args)
    if args.command == "flash":
        return run_flash_mode(args)
    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
