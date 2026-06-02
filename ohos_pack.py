#!/usr/bin/env python3
"""
Pack build artifacts into a version-stamped archive.

Usage:
  ohos_pack.py firmware --product rk3568 --output /tmp/out
  ohos_pack.py xts --product rk3568
  ohos_pack.py libs --product rk3568
  ohos_pack.py all

Artifact types:
  firmware   - Boot images (system.img, vendor.img, boot_linux.img, etc.)
  xts        - XTS test suites (suites/acts/)
  libs       - Shared libraries (out/<product>/libs/)
  all        - Everything above

Archive name: {product}-{type}-{date}-{version}.tar.gz
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import date
from pathlib import Path


def find_repo_root(start: Path) -> Path:
    """Walk up from start to find .repo directory (OHOS repo root)."""
    for parent in [start] + list(start.parents):
        if (parent / ".repo").is_dir():
            return parent
    return start


def get_repo_version(repo_root: Path) -> str:
    """Get a short version string from the OHOS repo."""
    tag = subprocess.run(
        ["git", "describe", "--tags", "--always", "--dirty"],
        cwd=repo_root,
        capture_output=True, text=True, timeout=10
    ).stdout.strip()
    if tag:
        return tag

    # Fallback: manifest pinned revision
    manifest = repo_root / ".repo" / "manifest.xml"
    if manifest.exists():
        for line in manifest.read_text().splitlines():
            if 'revision="' in line:
                rev = line.split('revision="')[1].split('"')[0]
                return rev[:12]
    return "unknown"


def get_short_hash(repo_root: Path) -> str:
    """Get short commit hash from the manifest or product git."""
    if not repo_root:
        return "unknown"
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=repo_root,
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return "unknown"


def default_output_dir() -> Path:
    """Default output directory: .runtime/ in the workspace root."""
    return Path.home() / ".cache" / "ohos-pack"


def discover_artifacts(product: str, artifact_type: str, repo_root: Path) -> list[tuple[str, str]]:
    """
    Return list of (archive_path, source_path) tuples.
    archive_path is the path inside the tar.gz, source_path is on disk.
    """
    out_dir = repo_root / "out" / product
    artifacts: list[tuple[str, str]] = []

    if artifact_type in ("firmware", "all"):
        images_dir = out_dir / "packages" / "phone" / "images"
        if images_dir.is_dir():
            for f in sorted(images_dir.iterdir()):
                if f.is_file():
                    artifacts.append((f"firmware/{f.name}", str(f)))

    if artifact_type in ("xts", "all"):
        suites_dir = out_dir / "suites"
        if suites_dir.is_dir():
            for entry in suites_dir.rglob("*"):
                if entry.is_file():
                    rel = entry.relative_to(suites_dir)
                    artifacts.append((str(Path("xts") / rel), str(entry)))

    if artifact_type in ("libs", "all"):
        libs_dir = out_dir / "libs"
        if libs_dir.is_dir():
            for entry in libs_dir.rglob("*"):
                if entry.is_file():
                    rel = entry.relative_to(libs_dir)
                    artifacts.append((str(Path("libs") / rel), str(entry)))

    if artifact_type == "all":
        for extra_dir in ("module_info.json", "build.ninja"):
            f = out_dir / extra_dir
            if f.is_file():
                artifacts.append((f.name, str(f)))

    return artifacts


def discover_firmware_images(product: str, repo_root: Path) -> list[tuple[str, str]]:
    """Convenience: list firmware images without archiving."""
    return discover_artifacts(product, "firmware", repo_root)


def print_artifacts_table(artifacts: list[tuple[str, str]]):
    """Print artifacts in a compact table."""
    if not artifacts:
        print("  (no artifacts found)")
        return
    for archive_path, source_path in artifacts:
        size = os.path.getsize(source_path)
        size_str = format_size(size)
        print(f"  {archive_path:60s} {size_str:>8s}")


def format_size(size: int) -> str:
    if size < 1024:
        return f"{size}B"
    elif size < 1024**2:
        return f"{size // 1024}KB"
    elif size < 1024**3:
        return f"{size / 1024**2:.1f}MB"
    else:
        return f"{size / 1024**3:.2f}GB"


def create_archive(artifacts: list[tuple[str, str]], output_path: Path):
    """Create a tar.gz archive from the artifact list."""
    with tarfile.open(str(output_path), "w:gz") as tar:
        for archive_path, source_path in artifacts:
            tar.add(source_path, arcname=archive_path, recursive=False)
    return output_path


def _pack_type(args, artifact_type: str, label: str, not_found_msg: str) -> int:
    """Shared pack logic for all artifact types."""
    repo_root = find_repo_root(Path.cwd())
    product = args.product
    artifacts = discover_artifacts(product, artifact_type, repo_root)

    if args.dry_run or args.list:
        print(f"{label} for {product}:")
        print_artifacts_table(artifacts)
        return 0

    if not artifacts:
        print(not_found_msg)
        return 1

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    version = get_short_hash(repo_root) if args.version == "auto" else args.version
    today = date.today().strftime("%Y%m%d")
    name = args.name or f"{product}-{artifact_type}-{today}-{version}"
    output_path = output_dir / f"{name}.tar.gz"

    create_archive(artifacts, output_path)
    size = format_size(output_path.stat().st_size)
    print(f"Created: {output_path} ({size})")
    return 0


def cmd_firmware(args) -> int:
    return _pack_type(args, "firmware", "Firmware images",
                      f"No firmware images found in out/{args.product}/packages/phone/images/")


def cmd_xts(args) -> int:
    return _pack_type(args, "xts", "XTS suites",
                      f"No XTS suites found in out/{args.product}/suites/")


def cmd_libs(args) -> int:
    return _pack_type(args, "libs", "Libraries",
                      f"No libraries found in out/{args.product}/libs/")


def cmd_all(args) -> int:
    return _pack_type(args, "all", "All artifacts",
                      f"No artifacts found for product {args.product}")


def cmd_list(args) -> int:
    """List available artifacts for a product without creating archive."""
    repo_root = find_repo_root(Path.cwd())
    product = args.product
    for atype in ("firmware", "xts", "libs"):
        artifacts = discover_artifacts(product, atype, repo_root)
        if artifacts:
            print(f"\n{atype.upper()}:")
            print_artifacts_table(artifacts)
    return 0


def detect_built_types(product: str, repo_root: Path) -> list[str]:
    """Auto-detect which artifact types are available after a build."""
    out_dir = repo_root / "out" / product
    found = []
    images_dir = out_dir / "packages" / "phone" / "images"
    if images_dir.is_dir() and any(images_dir.iterdir()):
        found.append("firmware")
    suites_dir = out_dir / "suites"
    if suites_dir.is_dir() and any(suites_dir.rglob("*")):
        found.append("xts")
    libs_dir = out_dir / "libs"
    if libs_dir.is_dir() and any(libs_dir.iterdir()):
        found.append("libs")
    return found


TYPE_DESCRIPTIONS = {
    "firmware": "Boot images for flashing (system.img, vendor.img, boot_linux.img, etc.)",
    "xts": "XTS test suites (acts test cases, metadata, resources)",
    "libs": "Shared libraries (.z.so, .so) for testing or redistribution",
}


def _prompt_type_selection(types: list[str], product: str, repo_root: Path) -> list[str]:
    """Interactive menu to select which detected artifact types to pack."""
    print(f"\nDetected build artifacts for {product}:")
    print()
    for i, atype in enumerate(types, 1):
        artifacts = discover_artifacts(product, atype, repo_root)
        count = len(artifacts)
        total = sum(os.path.getsize(s) for _, s in artifacts)
        total_str = format_size(total)
        desc = TYPE_DESCRIPTIONS.get(atype, "")
        print(f"  [{i}]  [*] {atype.upper():12s} {count:>4d} files  {total_str:>8s}")
        print(f"       {desc}")
    print()
    selected = list(types)
    while True:
        print()
        for i, atype in enumerate(types, 1):
            mark = "*" if atype in selected else " "
            print(f"       [{i}]  [{mark}] {atype.upper():12s}")
        prompt = (f"  Toggle numbers (space-separated), [a]ll, [n]one, "
                  f"[d]escribe, [Enter] to pack: ")
        try:
            raw = input(prompt).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if raw == "":
            break
        if raw == "a":
            selected = list(types)
            continue
        if raw == "n":
            selected = []
            continue
        if raw == "d":
            for atype in sorted(set(types)):
                desc = TYPE_DESCRIPTIONS.get(atype, atype)
                print(f"    {atype}: {desc}")
            continue
        for token in raw.split():
            if token.isdigit():
                idx = int(token) - 1
                if 0 <= idx < len(types):
                    t = types[idx]
                    if t in selected:
                        selected.remove(t)
                    else:
                        selected.append(t)
    return selected


def cmd_auto(args) -> int:
    """Auto-detect and package everything available."""
    repo_root = find_repo_root(Path.cwd())
    product = args.product
    types = detect_built_types(product, repo_root)
    if not types:
        out_dir = repo_root / "out" / product
        if not out_dir.is_dir():
            print(f"Nothing found in out/{product}/ — no build output detected")
            return 1
        print(f"out/{product}/ exists but no known artifacts found (partial build?)")
        return 1

    if args.dry_run or args.list:
        print(f"Detected build artifacts for {product}:")
        for atype in types:
            artifacts = discover_artifacts(product, atype, repo_root)
            print(f"\n{atype.upper()}:")
            print_artifacts_table(artifacts)
        return 0

    if len(types) > 1 and not args.dry_run and not args.list:
        types = _prompt_type_selection(types, product, repo_root)
        if not types:
            print("Nothing selected, skipping")
            return 0

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    version = get_short_hash(repo_root) if args.version == "auto" else args.version
    today = date.today().strftime("%Y%m%d")
    packed = 0

    for atype in types:
        artifacts = discover_artifacts(product, atype, repo_root)
        if not artifacts:
            continue
        name = args.name or f"{product}-{atype}-{today}-{version}"
        output_path = output_dir / f"{name}.tar.gz"
        create_archive(artifacts, output_path)
        size = format_size(output_path.stat().st_size)
        print(f"  {output_path} ({size})")
        packed += 1

    if packed == 0:
        print("No artifacts found to pack")
        return 1
    return 0


def _add_shared_args(parser: argparse.ArgumentParser):
    parser.add_argument("--product", default="rk3568", help="Product name (default: rk3568)")
    parser.add_argument("--output", "-o", default=str(default_output_dir()), help=f"Output directory (default: {default_output_dir()})")
    parser.add_argument("--name", "-n", help="Custom archive name (auto-generated by default)")
    parser.add_argument("--version", default="auto", help="Version string (default: auto = git short hash)")
    parser.add_argument("--dry-run", "-d", action="store_true", help="Show what would be packaged without creating archive")
    parser.add_argument("--list", "-l", action="store_true", help="List artifacts and exit")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Pack OHOS build artifacts")
    _add_shared_args(parser)

    sub = parser.add_subparsers(dest="subcommand")

    p_fw = sub.add_parser("firmware", help="Package firmware images for flashing")
    p_fw.set_defaults(func=cmd_firmware)

    p_xts = sub.add_parser("xts", help="Package XTS test suites")
    p_xts.set_defaults(func=cmd_xts)

    p_libs = sub.add_parser("libs", help="Package shared libraries")
    p_libs.set_defaults(func=cmd_libs)

    p_all = sub.add_parser("all", help="Package all known artifact types")
    p_all.set_defaults(func=cmd_all)

    p_list = sub.add_parser("list", help="List available artifacts")
    p_list.set_defaults(func=cmd_list)

    p_auto = sub.add_parser("auto", help="Auto-detect and pack available artifacts")
    p_auto.set_defaults(func=cmd_auto)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if not hasattr(args, "func") or args.subcommand is None:
        args.func = cmd_auto
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
