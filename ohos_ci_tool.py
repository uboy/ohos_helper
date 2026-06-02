#!/usr/bin/env python3
"""
CI build info and artifact download for GitCode/Gitee PRs.

Parses CI bot comments on PRs, shows build status per target,
and interactively downloads build logs and artifacts.

Usage:
  python3 ohos_ci_tool.py <owner> <repo> <pr_num>
"""

import argparse
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

_UTIL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gitee_util")
sys.path.insert(0, _UTIL_DIR)

from gitee_query import GitCodeQuery

OUT_DIR = Path.home() / ".cache" / "ohos-ci"


def extract_build_info(html: str) -> list[dict]:
    """Parse CI bot HTML comment and extract per-target build info.

    Returns list of dicts with keys: target, status, log_url, artifact_url, dashboard_url.
    """
    results = []
    seen = set()

    log_links = re.finditer(
        r'<a\s+href="([^"]*?/Artifacts/([^/]+)/([^/]+)/log/build\.log)"[^>]*>',
        html, re.I
    )
    for m in log_links:
        log_url = m.group(1)
        target = m.group(2)
        build_id = m.group(3)

        artifact_url = ""
        artifact_m = re.search(
            rf'<a\s+href="([^"]*?/Artifacts/{re.escape(target)}/{re.escape(build_id)}/version/[^"]*?\.tar\.gz)"',
            html, re.I
        )
        if artifact_m:
            artifact_url = artifact_m.group(1)

        status = "unknown"
        status_m = re.search(
            rf'{re.escape(target)}\s*</td>\s*<td[^>]*>\s*(success|failed[^<]*)',
            html, re.I
        )
        if status_m:
            raw = status_m.group(1).strip()
            status = raw

        dashboard_url = ""
        dash_m = re.search(
            r'href="([^"]*?dcp\.openharmony\.cn[^"]*?runlist)"',
            html, re.I
        )
        if dash_m:
            dashboard_url = dash_m.group(1)

        key = (target, build_id)
        if key not in seen:
            seen.add(key)
            results.append({
                "target": target,
                "build_id": build_id,
                "status": status,
                "log_url": log_url,
                "artifact_url": artifact_url,
                "dashboard_url": dashboard_url,
            })

    if not results:
        alt_logs = re.finditer(
            r'<a\s+href="([^"]*?build\.log[^"]*)"[^>]*>',
            html, re.I
        )
        for m in alt_logs:
            log_url = m.group(1)
            results.append({
                "target": "unknown",
                "build_id": "",
                "status": "unknown",
                "log_url": log_url,
                "artifact_url": "",
                "dashboard_url": "",
            })

    return results


def show_status_table(builds: list[dict]):
    """Print build status per target."""
    if not builds:
        print("No CI build information found in PR comments.")
        return

    print()
    print(f"{'Target':<30} {'Status':<35} {'Log':<5} {'Artifact':<5}")
    print("-" * 80)
    for b in builds:
        status_display = b["status"][:34]
        has_log = "✓" if b["log_url"] else ""
        has_artifact = "✓" if b["artifact_url"] else ""
        print(f"{b['target']:<30} {status_display:<35} {has_log:<5} {has_artifact:<5}")
    print()

    if any(b["dashboard_url"] for b in builds):
        print(f"Dashboard: {builds[0]['dashboard_url']}")
        print()


def make_choice_menu(builds: list[dict]) -> list[tuple[dict, list[str]]]:
    """Interactive menu to select which targets and what to download.

    Returns list of (build_info, [download_types]) where download_types
    is a subset of ['log', 'artifact'].
    """
    if not builds:
        return []

    choices = []
    idx = 0
    for b in builds:
        if b["log_url"]:
            choices.append((b, "log", f"logs ({b['target']})"))
        if b["artifact_url"]:
            choices.append((b, "artifact", f"artifacts ({b['target']})"))
        idx += 1

    if not choices:
        print("Nothing available to download.")
        return []

    selected_indices = set()
    while True:
        print("\nWhat do you want to download?")
        print("  Enter numbers separated by space or comma.")
        print("  Enter 'a' to select all, 'n' for none, 'q' to quit.")
        print()

        for i, (_, dtype, label) in enumerate(choices):
            marker = "▶" if i in selected_indices else " "
            print(f"  {marker} [{i+1}] {label}")

        try:
            raw = input(f"\n[{' '.join(str(i+1) for i in sorted(selected_indices)) or 'none'}]> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not raw:
            break

        if raw.lower() in ("q", "quit"):
            return []
        if raw.lower() in ("n", "none"):
            selected_indices = set()
            break
        if raw.lower() in ("a", "all"):
            selected_indices = set(range(len(choices)))
            break

        parts = re.split(r'[,\s]+', raw)
        for p in parts:
            p = p.strip()
            if not p:
                continue
            try:
                num = int(p)
                if 1 <= num <= len(choices):
                    if num - 1 in selected_indices:
                        selected_indices.discard(num - 1)
                    else:
                        selected_indices.add(num - 1)
                else:
                    print(f"  Invalid number: {num}")
            except ValueError:
                print(f"  Invalid input: {p}")

    result_map: dict = {}
    for i in selected_indices:
        build, dtype, _ = choices[i]
        key = id(build)
        if key not in result_map:
            result_map[key] = (build, [])
        result_map[key][1].append(dtype)

    return list(result_map.values())


def download_items(to_download: list[tuple[dict, list[str]]], output_dir: Path):
    """Download selected logs and artifacts."""
    import requests

    if not to_download:
        print("Nothing to download.")
        return

    output_dir.mkdir(parents=True, exist_ok=True)
    session = requests.Session()
    session.headers["User-Agent"] = "ohos-ci-tool/1.0"

    total = sum(len(types) for _, types in to_download)
    downloaded = 0
    failed = 0

    for build, types in to_download:
        target = build["target"]
        for dtype in types:
            if dtype == "log":
                url = build["log_url"]
                label = f"{target} build.log"
            else:
                url = build["artifact_url"]
                label = f"{target} artifact"

            if not url:
                print(f"  SKIP: {label} — no URL available")
                continue

            parsed = urlparse(url)
            filename = os.path.basename(parsed.path) or f"{target}_{dtype}"
            out_path = output_dir / filename

            if out_path.exists():
                print(f"  EXISTS: {label} -> {out_path} ({out_path.stat().st_size / 1024 / 1024:.1f} MB)")
                downloaded += 1
                continue

            try:
                print(f"  DOWNLOAD: {label} ...", end=" ", flush=True)
                r = session.get(url, timeout=(5, 120))
                r.raise_for_status()
                out_path.write_bytes(r.content)
                size_mb = len(r.content) / 1024 / 1024
                print(f"{size_mb:.1f} MB -> {out_path}")
                downloaded += 1
            except Exception as e:
                print(f"FAILED: {e}")
                failed += 1

    print(f"\nDone: {downloaded} downloaded, {failed} failed, {total - downloaded - failed} skipped")
    print(f"Output: {output_dir}")


def cmd_info(args):
    """Show CI build status for a PR."""
    client = GitCodeQuery(args.provider)
    comments = client.get_pr_comments(args.owner, args.repo, args.pr)
    if not comments:
        print(f"No comments on PR #{args.pr}")
        return 1

    ci_bodies = []
    for c in comments:
        user = (c.get("user") or {}).get("login", "")
        if user.lower() in ("openharmony_ci", "openharmony-ci", "ohos_ci"):
            body = c.get("body", "")
            if "Artifacts" in body or "build.log" in body:
                ci_bodies.append(body)

    if not ci_bodies:
        print(f"No CI bot comments with build info found on PR #{args.pr}")
        return 1

    html = "\n".join(ci_bodies)
    builds = extract_build_info(html)

    print(f"\nPR #{args.pr} — CI Build Status ({args.owner}/{args.repo})")
    print("=" * 60)
    show_status_table(builds)

    return 0


def cmd_download(args):
    """Interactive download of CI logs and artifacts."""
    client = GitCodeQuery(args.provider)
    comments = client.get_pr_comments(args.owner, args.repo, args.pr)
    if not comments:
        print(f"No comments on PR #{args.pr}")
        return 1

    ci_bodies = []
    for c in comments:
        user = (c.get("user") or {}).get("login", "")
        if user.lower() in ("openharmony_ci", "openharmony-ci", "ohos_ci"):
            body = c.get("body", "")
            if "Artifacts" in body or "build.log" in body:
                ci_bodies.append(body)

    if not ci_bodies:
        print(f"No CI bot comments with build info found on PR #{args.pr}")
        return 1

    html = "\n".join(ci_bodies)
    builds = extract_build_info(html)

    print(f"\nPR #{args.pr} — CI Build Status ({args.owner}/{args.repo})")
    print("=" * 60)
    show_status_table(builds)

    if args.yes:
        to_download = [(b, ["log", "artifact"]) for b in builds if b["log_url"] or b["artifact_url"]]
    else:
        to_download = make_choice_menu(builds)

    if not to_download:
        print("Nothing selected for download.")
        return 0

    output_dir = Path(args.output) if args.output else OUT_DIR / f"{args.owner}_{args.repo}_pr{args.pr}"
    download_items(to_download, output_dir)
    return 0


def main():
    parser = argparse.ArgumentParser(description="CI build info and artifact download for GitCode/Gitee PRs")
    parser.add_argument("--provider", default="gitcode", choices=["gitcode", "gitee"])
    parser.add_argument("--output", "-o", help="Download directory (default: ~/.cache/ohos-ci/<repo>_pr<num>)")

    sub = parser.add_subparsers(dest="command")

    p_info = sub.add_parser("info", help="Show CI build status summary for a PR")
    p_info.add_argument("owner", default="openharmony", nargs="?")
    p_info.add_argument("repo", default="arkui_ace_engine", nargs="?")
    p_info.add_argument("pr", type=int, help="PR number")
    p_info.set_defaults(func=cmd_info)

    p_dl = sub.add_parser("download", aliases=["dl"], help="Interactive download of CI logs and artifacts")
    p_dl.add_argument("owner", default="openharmony", nargs="?")
    p_dl.add_argument("repo", default="arkui_ace_engine", nargs="?")
    p_dl.add_argument("pr", type=int, help="PR number")
    p_dl.add_argument("--yes", "-y", action="store_true", help="Download all available (non-interactive)")
    p_dl.set_defaults(func=cmd_download)

    args = parser.parse_args()
    if not hasattr(args, "func"):
        parser.print_help()
        sys.exit(1)

    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
