#!/usr/bin/env python3
"""Run selector on team-member PRs from openharmony/arkui_ace_engine (2025-01-01..2026-05-01).

Outputs:
  local/pr_results/PR_<number>.log       — full selector stdout+stderr per PR
  local/pr_members_filtered.json         — filtered PR list (members only, in date range)
  local/pr_members_summary.json          — aggregated stats
"""
from __future__ import annotations

import configparser
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
SELECTOR_ROOT = PROJECT_ROOT / "arkui-xts-selector"

LOCAL_DIR = PROJECT_ROOT / "local"
RESULTS_DIR = LOCAL_DIR / "pr_results"
FILTERED_PATH = LOCAL_DIR / "pr_members_filtered.json"
SUMMARY_PATH = LOCAL_DIR / "pr_members_summary.json"

CONFIG_PATH = Path(
    os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
) / "gitee_util" / "config.ini"

REPO_ROOT = Path(
    os.environ.get("OHOS_REPO_ROOT", str(Path.home() / "proj/ohos_master"))
)
XTS_ROOT = REPO_ROOT / "test/xts/acts/arkui"
SDK_ROOT = REPO_ROOT / "interface/sdk-js/api"
GIT_ROOT = REPO_ROOT / "foundation/arkui/ace_engine"
ACTS_OUT = Path.home() / "proj/out/release/suites/acts"
GIT_HOST_CFG = CONFIG_PATH

MEMBERS_FILE = SCRIPT_DIR / "members.txt"

# ── Date range ─────────────────────────────────────────────────────────────
DATE_SINCE = "2025-01-01T00:00:00+08:00"
DATE_UNTIL = "2026-05-01T23:59:59+08:00"

WORKERS = 10
MAX_RETRIES = 3
RETRY_BACKOFF = 5
API_PER_PAGE = 100
API_MAX_PAGES = 60  # up to 6000 PRs


# ── API helpers ────────────────────────────────────────────────────────────
def load_token() -> str:
    cp = configparser.ConfigParser()
    cp.read(str(CONFIG_PATH))
    return cp.get("gitcode", "token")


def load_members() -> set[str]:
    if not MEMBERS_FILE.exists():
        print(f"WARNING: {MEMBERS_FILE} not found, no members to filter")
        return set()
    names = MEMBERS_FILE.read_text(encoding="utf-8").splitlines()
    return {n.strip() for n in names if n.strip() and not n.startswith("#")}


def fetch_prs(token: str) -> list[dict]:
    """Fetch PRs from GitCode API with full pagination."""
    all_prs: list[dict] = []
    base = "https://gitcode.com"
    owner, repo = "openharmony", "arkui_ace_engine"

    for page in range(1, API_MAX_PAGES + 1):
        path = f"/api/v5/repos/{owner}/{repo}/pulls"
        qs = urllib.parse.urlencode({
            "access_token": token,
            "state": "all",
            "per_page": API_PER_PAGE,
            "page": page,
            "sort": "updated",
            "direction": "desc",
        })
        url = f"{base}{path}?{qs}"
        req = urllib.request.Request(url, headers={"Accept": "application/json"})

        print(f"  page {page}...", end="", flush=True)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read())
        except Exception as exc:
            print(f" ERROR: {exc}")
            break

        print(f" {len(data)} PRs", flush=True)
        if not data:
            break
        all_prs.extend(data)
        if len(data) < API_PER_PAGE:
            break
        time.sleep(0.3)

    return all_prs


def filter_prs(prs: list[dict], members: set[str]) -> list[dict]:
    """Keep PRs from team members within the date range."""
    filtered = []
    for pr in prs:
        user = pr.get("user", {})
        login = user.get("login", "") if isinstance(user, dict) else str(user)
        if login not in members:
            continue

        updated = pr.get("updated_at", "")
        if not updated:
            continue
        # Normalize to comparable string (ISO with tz)
        if DATE_SINCE <= updated <= DATE_UNTIL:
            html_url = pr.get("html_url") or ""
            html_url = html_url.replace("/merge_requests/", "/pull/")
            if not html_url:
                html_url = f"https://gitcode.com/openharmony/arkui_ace_engine/pull/{pr['number']}"
            filtered.append({
                "number": pr["number"],
                "title": pr.get("title", ""),
                "state": pr.get("state", ""),
                "url": html_url,
                "user": login,
                "updated_at": updated,
                "changed_files": pr.get("changed_files", 0),
            })

    # Sort by PR number ascending
    filtered.sort(key=lambda p: p["number"])
    return filtered


# ── Selector runner ────────────────────────────────────────────────────────
def _build_selector_cmd(pr_url: str) -> list[str]:
    return [
        sys.executable, "-m", "arkui_xts_selector.cli",
        "--repo-root", str(REPO_ROOT),
        "--xts-root", str(XTS_ROOT),
        "--sdk-api-root", str(SDK_ROOT),
        "--git-root", str(GIT_ROOT),
        "--acts-out-root", str(ACTS_OUT),
        "--json",
        "--pr-url", pr_url,
        "--pr-source", "api",
        "--git-host-config", str(GIT_HOST_CFG),
        "--top-projects", "50",
    ]


def _clean_env() -> dict[str, str]:
    """Return env copy with proxy vars removed."""
    env = os.environ.copy()
    env.pop("http_proxy", None)
    env.pop("https_proxy", None)
    env.pop("HTTP_PROXY", None)
    env.pop("HTTPS_PROXY", None)
    env["PYTHONPATH"] = str(SELECTOR_ROOT / "src")
    return env


def run_selector(pr_info: dict) -> dict:
    """Run selector on a single PR with retries. Returns result dict."""
    pr_number = pr_info["number"]
    pr_url = pr_info["url"]
    cmd = _build_selector_cmd(pr_url)
    env = _clean_env()

    log_path = RESULTS_DIR / f"PR_{pr_number}.log"
    result = {"pr_number": pr_number, "user": pr_info["user"], "status": "unknown"}

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True, check=False,
                env=env, cwd=str(SELECTOR_ROOT), timeout=300,
            )

            # Save full log
            log_content = (
                f"PR #{pr_number} (attempt {attempt})\n"
                f"URL: {pr_url}\n"
                f"Return code: {proc.returncode}\n\n"
                f"=== STDOUT ===\n{proc.stdout}\n\n"
                f"=== STDERR ===\n{proc.stderr}\n"
            )
            log_path.write_text(log_content, encoding="utf-8")

            if proc.returncode != 0:
                result["status"] = "error"
                result["error_snippet"] = proc.stderr[:300]
                if attempt < MAX_RETRIES:
                    time.sleep(RETRY_BACKOFF)
                    continue
                return result

            # Parse JSON output
            stdout = proc.stdout
            json_start = stdout.find("{")
            if json_start < 0:
                result["status"] = "no_json"
                result["stdout_snippet"] = stdout[:200]
                return result

            try:
                # Use raw_decode to handle trailing output after JSON
                report, _ = json.JSONDecoder().raw_decode(stdout[json_start:])
            except json.JSONDecodeError:
                result["status"] = "json_error"
                return result

            # Extract summary metrics from coverage_recommendations.ordered_targets
            coverage = report.get("coverage_recommendations", {})
            ordered = coverage.get("ordered_targets", [])
            targets = [
                {
                    "project": t.get("project", ""),
                    "bucket": t.get("bucket", ""),
                    "score": t.get("score", 0),
                    "variant": t.get("variant", ""),
                    "confidence": t.get("confidence", ""),
                    "build_target": t.get("build_target", ""),
                }
                for t in ordered
            ]

            result["status"] = "ok"
            result["changed_files"] = [
                r.get("changed_file", "") for r in report.get("results", [])
            ]
            result["target_count"] = len(targets)
            result["required_count"] = len(coverage.get("required_target_keys", []))
            result["recommended_count"] = len(coverage.get("recommended_target_keys", []))
            result["recommended_additional_count"] = len(coverage.get("recommended_additional_target_keys", []))
            result["top_targets"] = targets[:10]
            result["buckets"] = {
                b: sum(1 for t in targets if t["bucket"] == b)
                for b in sorted(set(t["bucket"] for t in targets))
            }
            result["estimated_duration_s"] = {
                "required": coverage.get("estimated_required_duration_s"),
                "recommended": coverage.get("estimated_recommended_duration_s"),
                "all": coverage.get("estimated_all_duration_s"),
            }
            return result

        except subprocess.TimeoutExpired:
            result["status"] = "timeout"
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF)
                continue
            log_path.write_text(
                f"PR #{pr_number} — TIMEOUT after {MAX_RETRIES} attempts\n",
                encoding="utf-8",
            )
            return result

        except Exception as exc:
            result["status"] = "exception"
            result["error"] = str(exc)[:300]
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF)
                continue
            return result

    return result


def _run_selector_worker(pr_info: dict) -> dict:
    """Entry point for ProcessPoolExecutor workers."""
    return run_selector(pr_info)


# ── Main ───────────────────────────────────────────────────────────────────
def main() -> None:
    LOCAL_DIR.mkdir(exist_ok=True)
    RESULTS_DIR.mkdir(exist_ok=True)

    members = load_members()
    print(f"Loaded {len(members)} members: {', '.join(sorted(members))}")

    # 1. Fetch PRs
    print(f"\nFetching PRs (date range {DATE_SINCE[:10]}..{DATE_UNTIL[:10]})...")
    token = load_token()
    prs = fetch_prs(token)
    print(f"Total PRs fetched: {len(prs)}")

    # 2. Filter
    filtered = filter_prs(prs, members)
    print(f"Filtered to {len(filtered)} PRs from team members in date range")

    if not filtered:
        print("No matching PRs. Exiting.")
        return

    FILTERED_PATH.write_text(
        json.dumps(filtered, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"Saved filtered list to {FILTERED_PATH}")

    # 3. Run selector in parallel
    print(f"\nRunning selector on {len(filtered)} PRs ({WORKERS} workers)...")
    results: list[dict] = []
    completed = 0

    with ProcessPoolExecutor(max_workers=WORKERS) as pool:
        futures = {
            pool.submit(_run_selector_worker, pr): pr
            for pr in filtered
        }
        for future in as_completed(futures):
            pr_info = futures[future]
            completed += 1
            try:
                result = future.result()
            except Exception as exc:
                result = {
                    "pr_number": pr_info["number"],
                    "user": pr_info["user"],
                    "status": "exception",
                    "error": str(exc)[:300],
                }
            results.append(result)
            print(
                f"  [{completed}/{len(filtered)}] PR #{result['pr_number']}"
                f" ({result.get('user', '?')}): {result['status']}",
                flush=True,
            )

    # Sort results by PR number
    results.sort(key=lambda r: r["pr_number"])

    # 4. Save summary
    ok = sum(1 for r in results if r["status"] == "ok")
    errors = sum(1 for r in results if r["status"] == "error")
    timeouts = sum(1 for r in results if r["status"] == "timeout")
    no_json = sum(1 for r in results if r["status"] == "no_json")
    exceptions = sum(1 for r in results if r["status"] == "exception")

    summary = {
        "generated_at": datetime.now().isoformat(),
        "date_range": f"{DATE_SINCE[:10]}..{DATE_UNTIL[:10]}",
        "total_fetched": len(prs),
        "total_filtered": len(filtered),
        "members": sorted(members),
        "results": {
            "ok": ok,
            "error": errors,
            "timeout": timeouts,
            "no_json": no_json,
            "exception": exceptions,
        },
        "per_pr": results,
    }

    if ok > 0:
        from collections import Counter
        all_buckets: Counter = Counter()
        total_targets = 0
        for r in results:
            if r["status"] != "ok":
                continue
            all_buckets.update(r.get("buckets", {}))
            total_targets += r.get("target_count", 0)
        summary["aggregates"] = {
            "avg_targets_per_pr": round(total_targets / ok, 1),
            "bucket_distribution": dict(all_buckets.most_common()),
        }

    SUMMARY_PATH.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    # 5. Print summary
    print(f"\n{'='*60}")
    print(f"SUMMARY")
    print(f"{'='*60}")
    print(f"Total fetched:     {len(prs)}")
    print(f"Team PRs filtered: {len(filtered)}")
    print(f"  OK:       {ok}")
    print(f"  Errors:   {errors}")
    print(f"  Timeouts: {timeouts}")
    print(f"  No JSON:  {no_json}")
    print(f"  Exception:{exceptions}")
    if ok > 0:
        agg = summary.get("aggregates", {})
        print(f"\nAvg targets/PR: {agg.get('avg_targets_per_pr', 'N/A')}")
        print("Bucket distribution:")
        for bucket, count in agg.get("bucket_distribution", {}).items():
            print(f"  {bucket}: {count}")

    print(f"\nPer-PR logs:   {RESULTS_DIR}/")
    print(f"Filtered list: {FILTERED_PATH}")
    print(f"Summary:       {SUMMARY_PATH}")


if __name__ == "__main__":
    main()
