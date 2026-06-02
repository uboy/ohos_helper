#!/usr/bin/env python3
"""
ohos_status.py — Single-command dashboard for all running OHOS operations.

Usage:
  python3 ohos_status.py              # Full status with remote progress
  python3 ohos_status.py --no-remote  # Instant, skip SSH checks
  python3 ohos_status.py --json       # Machine-readable output
  ohos status                         # Same via CLI integration
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

# ── Color helpers ──────────────────────────────────────────────────────────────

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"
NO_COLOR = not sys.stdout.isatty()


def c(text: str, *codes: str) -> str:
    if NO_COLOR:
        return text
    return "".join(codes) + text + NC


def fmt_duration(seconds: float) -> str:
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    h, m = divmod(s, 3600)
    m, sec = divmod(m, 60)
    if h:
        return f"{h}h {m}m" if sec == 0 else f"{h}h {m}m {sec}s"
    return f"{m}m {sec}s" if sec else f"{m}m"


def fmt_ago(dt_str: str) -> str:
    try:
        dt = datetime.fromisoformat(dt_str.replace("Z", "+00:00"))
        delta = (datetime.now(timezone.utc) - dt).total_seconds()
        if delta < 0:
            return "now"
        if delta < 60:
            return f"{int(delta)}s ago"
        if delta < 3600:
            return f"{int(delta / 60)}m ago"
        if delta < 86400:
            return f"{int(delta / 3600)}h ago"
        return f"{int(delta / 86400)}d ago"
    except (ValueError, TypeError):
        return "?"


def progress_bar(done: int, total: int, width: int = 20) -> str:
    if total == 0:
        return "░" * width
    filled = int(width * done / total)
    return "█" * filled + "░" * (width - filled)


# ── Board config ──────────────────────────────────────────────────────────────

def parse_boards_conf(conf_path: Path) -> list[dict[str, str]]:
    """Parse boards.conf into a list of board dicts."""
    boards: list[dict[str, str]] = []
    i = 1
    text = conf_path.read_text() if conf_path.exists() else ""
    while True:
        prefix = f"BOARD_{i}_"
        entry: dict[str, str] = {}
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key.startswith(prefix):
                field = key[len(prefix):].lower()
                entry[field] = val
        if not entry:
            break
        if entry.get("serial"):
            boards.append(entry)
        i += 1
    return boards


# ── Process detection ─────────────────────────────────────────────────────────

def _ps_aux() -> str:
    try:
        r = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=10)
        return r.stdout
    except Exception:
        return ""


def detect_running_xts(ps_output: str) -> list[dict[str, Any]]:
    """Detect running ohos_xts_full_run.py processes."""
    runs: list[dict[str, Any]] = []
    for line in ps_output.splitlines():
        if "grep" in line or "ohos_xts_full_run.py" not in line:
            continue
        fields = line.split(None, 10)
        if len(fields) < 11:
            continue
        # Only actual python process, not bash wrapper eval'ing the command
        if not fields[10].startswith("python3") and not fields[10].startswith("/usr/bin/python3"):
            continue
        pid = fields[1]
        cmdline = fields[10]

        label_m = re.search(r"--label\s+(\S+)", cmdline)
        devices_m = re.search(r"--devices\s+(\S+)", cmdline)
        boards_m = re.search(r"--boards\s+(\S+)", cmdline)
        variant_m = re.search(r"--variant\s+(\S+)", cmdline)

        label = label_m.group(1) if label_m else f"unknown-{pid}"
        device_str = devices_m.group(1) if devices_m else ""
        board_str = boards_m.group(1) if boards_m else ""
        variant = variant_m.group(1) if variant_m else ""

        device_serials = [d.strip() for d in device_str.split(",") if d.strip()] if device_str else []
        board_shorts = [b.strip() for b in board_str.split(",") if b.strip()] if board_str else []

        # Get process start time
        try:
            r = subprocess.run(
                ["ps", "-o", "etimes=", "-p", pid],
                capture_output=True, text=True, timeout=5,
            )
            elapsed = int(r.stdout.strip()) if r.stdout.strip() else 0
        except Exception:
            elapsed = 0

        runs.append({
            "pid": pid,
            "label": label,
            "device_serials": device_serials,
            "board_shorts": board_shorts,
            "variant": variant,
            "elapsed_s": elapsed,
            "shards": [],
        })
    return runs


def parse_run_log_shards(run_log_path: Path) -> list[dict[str, Any]]:
    """Extract shard info from run.log."""
    shards: list[dict[str, Any]] = []
    if not run_log_path.exists():
        return shards
    text = run_log_path.read_text(errors="replace")

    # Match: [shard-01-69864f628800] Running 111 modules on 150100424a544434520369864f628800
    run_pat = re.compile(
        r"\[.+?\]\s+INFO\s+\[(shard-\d+-\S+)\]\s+Running\s+(\d+)\s+modules\s+on\s+(\S+)"
    )
    for m in run_pat.finditer(text):
        shards.append({
            "name": m.group(1),
            "total": int(m.group(2)),
            "serial": m.group(3),
            "done": None,
            "status": "RUNNING",
        })

    # Match completed: [shard-01-...] PASS: 111 modules, 14404s  or  FAIL: ...
    done_pat = re.compile(
        r"\[.+?\]\s+(?:INFO|WARN)\s+\[(shard-\d+-\S+)\]\s+(PASS|FAIL):\s+(\d+)\s+modules"
    )
    completed = {}
    for m in done_pat.finditer(text):
        completed[m.group(1)] = {"status": m.group(2), "done": int(m.group(3))}

    for s in shards:
        if s["name"] in completed:
            s.update(completed[s["name"]])

    return shards


def check_remote_progress(
    server: str,
    shard_name: str,
    total: int,
) -> int | None:
    """SSH to remote, count XML result files for a shard."""
    ssh_user = os.environ.get("OHOS_SSH_USER", os.environ.get("USER", ""))
    target = f"{ssh_user}@{server}" if ssh_user else server
    remote_dir = f"/tmp/xts_shard_{shard_name}/shard/reports/{shard_name}/result"
    try:
        r = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
             f"find '{remote_dir}' -name '*.xml' 2>/dev/null | wc -l"],
            capture_output=True, text=True, timeout=15,
        )
        count = int(r.stdout.strip())
        return min(count, total)
    except Exception:
        return None


def enrich_shards_with_remote(
    runs: list[dict[str, Any]],
    boards: list[dict[str, str]],
) -> None:
    """Fill shard 'done' and 'server' fields via remote SSH checks."""
    # Build serial -> server lookup
    serial_to_server: dict[str, str] = {}
    for b in boards:
        serial_to_server[b["serial"]] = b.get("server", "")

    # Collect all shards needing remote check
    tasks: list[tuple[int, int, str, str, str, int]] = []  # (run_idx, shard_idx, server, shard_name, serial, total)
    for ri, run in enumerate(runs):
        for si, shard in enumerate(run["shards"]):
            if shard["status"] in ("PASS", "FAIL"):
                shard["done"] = shard["done"] or shard["total"]
                shard["server"] = serial_to_server.get(shard["serial"], "")
                continue
            server = serial_to_server.get(shard["serial"], "")
            shard["server"] = server
            if server:
                tasks.append((ri, si, server, shard["name"], shard["serial"], shard["total"]))

    def _check(args: tuple) -> tuple[int, int, int | None]:
        ri, si, server, name, serial, total = args
        return ri, si, check_remote_progress(server, name, total)

    with ThreadPoolExecutor(max_workers=8) as pool:
        for ri, si, done in pool.map(_check, tasks):
            if done is not None:
                runs[ri]["shards"][si]["done"] = done


# ── Completed runs ────────────────────────────────────────────────────────────

def detect_completed_xts(runs_dir: Path, limit: int = 5) -> list[dict[str, Any]]:
    """Scan for completed full_run_report.json files."""
    results: list[dict[str, Any]] = []
    for report_file in runs_dir.glob("*/full_run_report.json"):
        try:
            data = json.loads(report_file.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        agg = data.get("aggregate", {})
        results.append({
            "label": data.get("run_label", report_file.parent.name),
            "started_at": data.get("started_at", ""),
            "finished_at": data.get("finished_at", ""),
            "total_modules": data.get("total_modules", 0),
            "successful": agg.get("successful", 0),
            "failed": agg.get("failed", 0),
            "timed_out": agg.get("timed_out", 0),
            "total_duration_s": agg.get("total_duration_s", 0),
            "device_count": data.get("device_count", 0),
            "output_dir": data.get("output_dir", str(report_file.parent)),
        })
    results.sort(key=lambda r: r.get("finished_at", ""), reverse=True)
    return results[:limit]


# ── tmux session detection ────────────────────────────────────────────────────

def detect_tmux_sessions() -> list[dict[str, str]]:
    """Detect xts-related tmux sessions."""
    try:
        r = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}"],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode != 0:
            return []
        sessions = []
        for line in r.stdout.strip().splitlines():
            name = line.strip()
            if name.startswith("xts-"):
                sessions.append({"name": name})
        return sessions
    except Exception:
        return []


# ── Flash / Build detection ───────────────────────────────────────────────────

def detect_zombie_xts(runs_dir: Path, active_labels: set[str]) -> list[dict[str, Any]]:
    """Detect runs with run.log + shards but no report.json and no live process."""
    zombies: list[dict[str, Any]] = []
    for run_log in runs_dir.glob("*/run.log"):
        label = run_log.parent.name
        report_json = run_log.parent / "full_run_report.json"
        if label in active_labels:
            continue  # actively running
        if report_json.exists():
            continue  # properly completed
        shards = parse_run_log_shards(run_log)
        if not shards:
            continue  # nothing useful
        # Read start time from first log line
        first_line = run_log.read_text(errors="replace").splitlines()[0] if run_log.exists() else ""
        start_m = re.search(r"\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]", first_line)
        started = start_m.group(1) if start_m else ""
        zombies.append({
            "label": label,
            "started_at": started,
            "shards": shards,
            "path": str(run_log.parent),
        })
    return zombies


def detect_other_ops(ps_output: str) -> dict[str, list[dict[str, str]]]:
    """Detect flash and build operations."""
    result: dict[str, list[dict[str, str]]] = {"flash": [], "build": []}
    for line in ps_output.splitlines():
        if "grep" in line:
            continue
        fields = line.split(None, 10)
        if len(fields) < 11:
            continue
        pid = fields[1]
        cmdline = fields[10]

        if re.search(r"flash\.py|flash_tool|cmd_flash|flash\.amd64", cmdline):
            result["flash"].append({"pid": pid, "cmd": cmdline[:120]})
        if re.search(r"build\.sh\s|ninja\s+-C|gn\s+gen\s", cmdline):
            result["build"].append({"pid": pid, "cmd": cmdline[:120]})
    return result


# ── Board status ──────────────────────────────────────────────────────────────

def compute_board_status(
    boards: list[dict[str, str]],
    runs: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Mark each board as IN-USE or FREE based on running runs."""
    # Collect all serials currently in use
    in_use: dict[str, str] = {}  # serial -> label
    for run in runs:
        for serial in run.get("device_serials", []):
            in_use[serial] = run["label"]
        # Also match via shard serials
        for shard in run.get("shards", []):
            in_use.setdefault(shard.get("serial", ""), run["label"])

    board_status: list[dict[str, Any]] = []
    for b in boards:
        serial = b["serial"]
        board_status.append({
            "label": b.get("label", ""),
            "short": b.get("short", serial[-6:]),
            "serial": serial,
            "server": b.get("server", ""),
            "status": b.get("status", "OK"),
            "in_use_by": in_use.get(serial),
        })
    return board_status


# ── Output rendering ──────────────────────────────────────────────────────────

SEP = "─" * 54


def render_status(
    runs: list[dict[str, Any]],
    completed: list[dict[str, Any]],
    board_status: list[dict[str, Any]],
    other_ops: dict[str, list[dict[str, str]]],
    zombies: list[dict[str, Any]],
    tmux_sessions: list[dict[str, str]],
    no_remote: bool = False,
) -> None:
    # ── Running XTS runs ──
    print(c(f"  RUNNING XTS RUNS ({len(runs)})", BOLD))
    print(f"  {SEP}")
    if not runs:
        print(c("  (none)", DIM))
    for run in runs:
        elapsed = fmt_duration(run["elapsed_s"])
        head = f"  ● {run['label']}  PID {run['pid']}  {c(elapsed, YELLOW)} elapsed"
        print(head)

        # Start time, user, expected end
        started = run.get("started_at", "")
        if started:
            print(c(f"    Started: {started}  by {run.get('user', '?')}", DIM))
        eta = run.get("eta", "")
        if eta:
            print(c(f"    ETA: {eta}", DIM))
        output_dir = run.get("output_dir", "")
        if output_dir:
            print(c(f"    📁 {output_dir}", DIM))

        shards = run.get("shards", [])
        if not shards:
            print(c("    (starting... no shard info yet)", DIM))
            continue

        for shard in shards:
            name = shard["name"]
            total = shard["total"]
            done = shard.get("done")
            status = shard.get("status", "RUNNING")
            server = shard.get("server", "")
            board_label = shard.get("serial", "")[-6:]

            if status == "PASS":
                pct = 100
                bar = progress_bar(total, total)
            elif status == "FAIL":
                pct = 100
                bar = progress_bar(total, total)
            elif done is not None:
                pct = int(100 * done / total) if total else 0
                bar = progress_bar(done, total)
            else:
                pct = 0
                bar = "░" * 20

            # Find board label for this shard's serial
            for bs in board_status:
                if bs["serial"] == shard.get("serial", ""):
                    board_label = bs["label"]
                    break

            done_str = f"{done}" if done is not None else "?"
            line = f"    {name}  {done_str}/{total} {bar}  {pct:3d}%  {board_label}"
            print(line)

    print()

    # ── Completed runs ──
    print(c(f"  COMPLETED (recent {len(completed)})", BOLD))
    print(f"  {SEP}")
    if not completed:
        print(c("  (none)", DIM))
    for cr in completed:
        dur = fmt_duration(cr["total_duration_s"]) if cr["total_duration_s"] else "?"
        ago = fmt_ago(cr["finished_at"]) if cr["finished_at"] else "?"
        ok = cr["successful"]
        fail = cr["failed"]
        tmo = cr["timed_out"]

        if ok and not fail and not tmo:
            icon = c("✔", GREEN)
        else:
            icon = c("✘", RED)

        parts = [f"{ok} pass"]
        if fail:
            parts.append(c(f"{fail} fail", RED))
        if tmo:
            parts.append(c(f"{tmo} t/o", YELLOW))
        summary = " / ".join(parts)

        print(f"  {icon} {cr['label']:<30s} {cr['total_modules']:>3d} mod  {dur:>7s}  {summary}  ({ago})")
        if cr.get("output_dir"):
            print(c(f"    📁 {cr['output_dir']}", DIM))

    print()

    # ── Zombie runs ──
    if zombies:
        print(c(f"  ⚠ ZOMBIE RUNS ({len(zombies)}) — died without report", BOLD, YELLOW))
        print(f"  {SEP}")
        for z in zombies:
            ago = fmt_ago(z["started_at"]) if z["started_at"] else "?"
            shard_summary = []
            for s in z["shards"]:
                st = s["status"]
                if st in ("PASS", "FAIL"):
                    shard_summary.append(f"{s['name'][:20]}:{st}")
                else:
                    shard_summary.append(f"{s['name'][:20]}:???")
            print(f"  {c('☠', RED)} {z['label']:<30s} started {ago}")
            print(f"    shards: {', '.join(shard_summary)}")
            print(f"    path: {z['path']}")
        print()

    # ── tmux sessions ──
    print(c(f"  TMUX SESSIONS ({len(tmux_sessions)})", BOLD))
    print(f"  {SEP}")
    if not tmux_sessions:
        print(c("  (none)", DIM))
    for s in tmux_sessions:
        print(f"  🖥 {s['name']}")
        print(f"    Attach: tmux attach -t {s['name']}")
    print()

    # ── Board status ──
    free_count = sum(1 for b in board_status if not b["in_use_by"])
    print(c(f"  BOARDS ({len(board_status)} total, {free_count} free)", BOLD))
    print(f"  {SEP}")
    for b in board_status:
        status_mark = b.get("status", "OK")
        if status_mark in ("BROKEN", "OFFLINE"):
            icon = c("✖", RED)
            state = c(status_mark, RED)
        elif b["in_use_by"]:
            icon = c("■", YELLOW)
            state = c(f"IN-USE  {b['in_use_by']}", YELLOW)
        else:
            icon = c("□", GREEN)
            state = c("FREE", GREEN)

        label_col = f"{b['label']:<18s}"
        print(f"  {icon} {label_col} {b['server']:<15s} {state}")

    print()

    # ── Other operations ──
    flash_ops = other_ops.get("flash", [])
    build_ops = other_ops.get("build", [])
    print(c("  OTHER OPERATIONS", BOLD))
    print(f"  {SEP}")
    if not flash_ops and not build_ops:
        print(c("  (no flash or build operations running)", DIM))
    for op in flash_ops:
        print(f"  ⚡ FLASH  PID {op['pid']}  {op['cmd'][:80]}")
    for op in build_ops:
        print(f"  🔨 BUILD  PID {op['pid']}  {op['cmd'][:80]}")


def render_json(
    runs: list[dict[str, Any]],
    completed: list[dict[str, Any]],
    board_status: list[dict[str, Any]],
    other_ops: dict[str, list[dict[str, str]]],
    zombies: list[dict[str, Any]],
    tmux_sessions: list[dict[str, str]],
) -> None:
    output = {
        "running_xts": runs,
        "completed_xts": completed,
        "zombie_xts": zombies,
        "tmux_sessions": tmux_sessions,
        "boards": board_status,
        "flash_operations": other_ops.get("flash", []),
        "build_operations": other_ops.get("build", []),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    print(json.dumps(output, indent=2, default=str))


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="OHOS operations status dashboard",
    )
    parser.add_argument("--no-remote", action="store_true",
                        help="Skip SSH progress checks (instant)")
    parser.add_argument("--completed", type=int, default=5,
                        help="Number of recent completed runs to show (default: 5)")
    parser.add_argument("--json", action="store_true",
                        help="Output as JSON")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    conf_dir = script_dir / "conf"
    runs_dir = script_dir / "xts_full_runs"

    # 1. Detect running processes
    ps_output = _ps_aux()
    runs = detect_running_xts(ps_output)

    # 2. Parse board config
    boards = parse_boards_conf(conf_dir / "boards.conf")

    # 3. Parse run.log for each running process to get shard info + metadata
    for run in runs:
        run_log = runs_dir / run["label"] / "run.log"
        run["shards"] = parse_run_log_shards(run_log)
        run["output_dir"] = str(runs_dir / run["label"])

        # Extract started_at, user from run.log first lines
        started_at = ""
        user = os.environ.get("USER", "?")
        if run_log.exists():
            try:
                first_lines = run_log.read_text(errors="replace").splitlines()[:5]
                for line in first_lines:
                    # Match: [2026-06-01T13:41:06Z] INFO ...
                    m = re.match(r"\[(\d{4}-\d{2}-\d{2}T[\d:]+)Z?\]", line)
                    if m:
                        started_at = m.group(1).replace("T", " ")
                        break
            except Exception:
                pass

        # Get process owner from ps
        try:
            r = subprocess.run(
                ["ps", "-o", "user=", "-p", run["pid"]],
                capture_output=True, text=True, timeout=5,
            )
            if r.stdout.strip():
                user = r.stdout.strip()
        except Exception:
            pass

        run["started_at"] = started_at
        run["user"] = user

        # Estimate ETA from total modules and elapsed
        total_mods = sum(s["total"] for s in run["shards"])
        done_mods = sum(s.get("done", 0) or 0 for s in run["shards"])
        if done_mods > 0 and total_mods > 0 and run["elapsed_s"] > 0:
            rate = run["elapsed_s"] / done_mods
            remaining_s = rate * (total_mods - done_mods)
            eta_dt = datetime.now() + timedelta(seconds=int(remaining_s))
            run["eta"] = eta_dt.strftime("%H:%M")
        else:
            run["eta"] = ""

    # 4. Enrich shards with remote progress (unless --no-remote)
    if not args.no_remote and runs:
        enrich_shards_with_remote(runs, boards)

    # 5. Completed runs
    completed = detect_completed_xts(runs_dir, limit=args.completed)

    # 5b. Zombie runs (run.log + shards but no report, no process)
    active_labels = {r["label"] for r in runs}
    zombies = detect_zombie_xts(runs_dir, active_labels)

    # 6. Board status
    board_status = compute_board_status(boards, runs)

    # 7. Other operations
    other_ops = detect_other_ops(ps_output)

    # 8. tmux sessions
    tmux_sessions = detect_tmux_sessions()

    # 9. Render
    if args.json:
        render_json(runs, completed, board_status, other_ops, zombies, tmux_sessions)
    else:
        render_status(runs, completed, board_status, other_ops, zombies, tmux_sessions, no_remote=args.no_remote)

    return 0


if __name__ == "__main__":
    sys.exit(main())
