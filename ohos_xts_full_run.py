#!/usr/bin/env python3
"""
ohos_xts_full_run.py — Run ALL ArkUI ACE engine XTS tests across multiple boards
in parallel using the xdevice framework.

Usage:
  ohos device xts-full-run --acts-root /path/to/suites/acts

  ohos device xts-full-run --acts-root /path/to/suites/acts \\
      --boards 6c3800,feb8800,f628800 \\
      --variant static \\
      --label full-run-20260528

Reads board inventory from conf/boards.conf (same as cmd_xts_run).
Falls back to --devices for manual serial lists.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, TextIO


DEFAULT_XDEVICE_TIMEOUT = 14400
DEFAULT_HDC_PATH = os.environ.get("HDC_PATH", "hdc")
DEFAULT_TEST_PATTERN = "ActsAce*"

TEST_VARIANTS = {
    "static": ("StaticTest", "static"),
    "dynamic": ("DynamicTest", "dynamic"),
    "any": ("", ""),
}


_run_log: TextIO | None = None


# ── tmux session management ──────────────────────────────────────────────────

def _is_in_own_tmux(label: str) -> bool:
    """Check if we're inside our own tmux session via env marker."""
    return os.environ.get("XTS_TMUX_SESSION") == label


def _ensure_tmux_session(label: str) -> None:
    """Relaunch self in a dedicated tmux session.

    Always creates a new tmux session named xts-<label>, even if already
    inside another tmux (e.g. Claude Code). This protects the run from
    parent session disconnects. Sets XTS_TMUX_SESSION env var to prevent
    recursive relaunch.
    """
    if _is_in_own_tmux(label):
        return  # Already in our dedicated session
    if not shutil.which("tmux"):
        print(f"[WARN] tmux not available. Run may not survive terminal disconnect.")
        print(f"[WARN] Consider: nohup python3 ohos_xts_full_run.py ... &")
        return
    session = re.sub(r'[^a-zA-Z0-9_.-]', '-', f"xts-{label}")[:256]
    # Set env marker so re-launched process knows it's in the right session
    env = os.environ.copy()
    env["XTS_TMUX_SESSION"] = label
    # Build command with absolute paths so it works regardless of cwd in tmux
    argv_abs = [sys.executable, str(Path(sys.argv[0]).resolve())] + sys.argv[1:]
    cmd = " ".join(shlex.quote(a) for a in argv_abs)
    # Kill stale session if exists, then create fresh
    subprocess.run(["tmux", "kill-session", "-t", session],
                   capture_output=True, timeout=5)
    # Use env to pass XTS_TMUX_SESSION into the new tmux session
    r = subprocess.run(
        ["tmux", "new-session", "-d", "-s", session,
         f"export XTS_TMUX_SESSION={shlex.quote(label)} && {cmd}"],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        print(f"[INFO] Launched in tmux session: {session}")
        print(f"[INFO] Attach:  tmux attach -t {session}")
        print(f"[INFO] Status:  ohos status")
        sys.exit(0)
    else:
        print(f"[WARN] tmux session failed: {r.stderr.strip()}")
        print(f"[WARN] Continuing in foreground")


def _remote_has_tmux(target: str) -> bool:
    """Check if tmux is available on remote server."""
    try:
        r = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target, "which tmux"],
            capture_output=True, text=True, timeout=10,
        )
        return r.returncode == 0
    except Exception:
        return False


def utc_now_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def info(msg: str) -> None:
    print(f"[INFO] {msg}")
    if _run_log:
        _run_log.write(f"[{utc_now_str()}] INFO {msg}\n")
        _run_log.flush()


def warn(msg: str) -> None:
    print(f"[WARN] {msg}", file=sys.stderr)
    if _run_log:
        _run_log.write(f"[{utc_now_str()}] WARN {msg}\n")
        _run_log.flush()


def err(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr)
    if _run_log:
        _run_log.write(f"[{utc_now_str()}] ERROR {msg}\n")
        _run_log.flush()


def die(msg: str, code: int = 1) -> None:
    err(msg)
    sys.exit(code)


# ---------------------------------------------------------------------------
# Board inventory (conf/boards.conf parsing)
# ---------------------------------------------------------------------------

def parse_boards_conf(conf_path: Path) -> list[dict[str, str]]:
    """Parse boards.conf into a list of board dicts."""
    boards = []
    i = 1
    while True:
        prefix = f"BOARD_{i}_"
        entry = {}
        for line in conf_path.read_text().splitlines():
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


def resolve_boards(
    conf_dir: Path | None,
    board_shorts: list[str] | None,
    device_serials: list[str] | None,
) -> list[dict[str, str]]:
    """Resolve board list from conf/boards.conf, --boards, or --devices."""
    conf_path = conf_dir / "boards.conf" if conf_dir else Path("conf/boards.conf")
    all_boards = parse_boards_conf(conf_path) if conf_path.exists() else []

    if device_serials:
        resolved = []
        for s in device_serials:
            server = ""
            if all_boards:
                match = next((b for b in all_boards if b.get("serial") == s), None)
                if match:
                    server = match.get("server", "")
            resolved.append({"serial": s, "short": s[-12:] if len(s) >= 12 else s,
                             "server": server, "status": "OK"})
        return resolved

    if not all_boards:
        die("No boards found in boards.conf")

    if board_shorts:
        filtered = []
        for b in all_boards:
            short = b.get("short", "")
            serial = b.get("serial", "")
            if short in board_shorts or any(s in serial for s in board_shorts):
                filtered.append(b)
        if not filtered:
            die(f"No matching boards for: {board_shorts}")
        return filtered

    return [b for b in all_boards if b.get("status", "OK") == "OK"]


# ---------------------------------------------------------------------------
# HDC utilities
# ---------------------------------------------------------------------------

def find_hdc(hdc_path: str | None) -> str:
    if hdc_path:
        candidate = Path(hdc_path).expanduser()
        if candidate.is_file():
            return str(candidate.resolve())
        die(f"HDC binary not found at {hdc_path}")
    if Path(DEFAULT_HDC_PATH).is_file():
        return DEFAULT_HDC_PATH
    candidate = shutil.which("hdc")
    if candidate:
        return candidate
    die("HDC not found. Use --hdc to specify path.")


def check_hdc_connectivity(hdc_bin: str, devices: list[str]) -> dict[str, bool]:
    result = {}
    try:
        out = subprocess.check_output(
            [hdc_bin, "list", "targets", "-v"],
            timeout=10, stderr=subprocess.STDOUT,
        ).decode("utf-8", errors="replace")
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as e:
        warn(f"Failed to list HDC targets: {e}")
        return {d: False for d in devices}
    connected = set()
    for line in out.splitlines():
        line = line.strip()
        if not line or line == "[Empty]":
            continue
        parts = line.split()
        if parts:
            connected.add(parts[0])
    for d in devices:
        result[d] = d in connected
    return result


def hdc_tconn(hdc_bin: str, device: str, timeout: int = 20) -> bool:
    try:
        subprocess.check_call(
            [hdc_bin, "tconn", device],
            timeout=timeout, stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        )
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False


def hdc_wait_online(hdc_bin: str, device: str, max_wait: int = 30) -> bool:
    for _ in range(max_wait):
        try:
            out = subprocess.check_output(
                [hdc_bin, "-t", device, "shell", "echo", "online"],
                timeout=5, stderr=subprocess.DEVNULL,
            ).decode("utf-8", errors="replace").strip()
            if "online" in out:
                return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        time.sleep(1)
    return False


def _hdc_remote(hdc_bin: str, device: str, server: str, cmd: str,
                timeout: int = 15) -> bool:
    if not server:
        return False
    ssh_user = os.environ.get("OHOS_SSH_USER", os.environ.get("USER", ""))
    target = f"{ssh_user}@{server}" if ssh_user else server
    try:
        subprocess.run(
            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
             f"{hdc_bin} -t {device} {cmd}"],
            capture_output=True, text=True, timeout=timeout,
        )
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False


def init_boards(boards: list[dict], hdc_bin: str) -> None:
    info("Rebooting boards for clean state...")
    for b in boards:
        sn = b["serial"]
        server = b.get("server", "")
        _hdc_remote(hdc_bin, sn, server, "shell reboot", timeout=10)
    info("Waiting for boards to come back online...")
    time.sleep(40)
    for b in boards:
        sn = b["serial"]
        short = b.get("short", sn[-6:])
        server = b.get("server", "")
        # Wait for board to respond
        online = False
        for _ in range(30):
            if _hdc_remote(hdc_bin, sn, server, "shell echo ok", timeout=5):
                online = True
                break
            time.sleep(2)
        if not online:
            warn(f"  {short}: still offline after reboot, skipping init")
            continue
        # Match scripts/remote/init-board.sh.template exactly
        _hdc_remote(hdc_bin, sn, server, "shell power-shell wakeup")
        time.sleep(0.5)
        _hdc_remote(hdc_bin, sn, server, "shell power-shell timeout -o 86400000")
        _hdc_remote(hdc_bin, sn, server, "shell power-shell setmode 602")
        time.sleep(0.5)
        _hdc_remote(hdc_bin, sn, server, "shell uitest uiInput dircFling 2")
        time.sleep(0.3)
        _hdc_remote(hdc_bin, sn, server, "shell uitest uiInput click 350 800")
        time.sleep(0.3)
        _hdc_remote(hdc_bin, sn, server, "shell aa force-stop com.usb.right")
        info(f"  {short}: initialized")

def discover_xdevice_packages(acts_root: Path) -> list[Path]:
    candidates = []
    seen = set()
    bases = [acts_root, *list(acts_root.parents[:4])]
    for base in bases:
        tools_dir = base / "tools"
        if not tools_dir.is_dir():
            continue
        for pkg in sorted(tools_dir.glob("xdevice*.tar.gz")):
            resolved = pkg.resolve()
            key = str(resolved)
            if key in seen:
                continue
            seen.add(key)
            candidates.append(resolved)

    def sort_key(path: Path) -> tuple:
        name = path.name.lower()
        if name.startswith("xdevice-"):
            return (0, name)
        if "ohos" in name:
            return (1, name)
        if "devicetest" in name:
            return (2, name)
        return (3, name)

    return sorted(candidates, key=sort_key)


def bootstrap_xdevice(acts_root: Path) -> str:
    packages = discover_xdevice_packages(acts_root)
    if not packages:
        die(f"No xdevice packages found under {acts_root}/tools/")

    digest = hashlib.sha256(str(acts_root.resolve()).encode("utf-8")).hexdigest()[:12]
    bootstrap_dir = Path(os.environ.get("TMPDIR", "/tmp")) / "ohos_xts_xdevice" / digest
    bootstrap_pkg_dir = bootstrap_dir / "xdevice"
    home_dir = bootstrap_dir / "home"

    if bootstrap_pkg_dir.is_dir():
        # Revalidate: check runner script is functional
        runner_check = bootstrap_dir / "_xts_runner.sh"
        if runner_check.is_file():
            info(f"xdevice already bootstrapped at {bootstrap_dir}")
        else:
            warn(f"Stale bootstrap at {bootstrap_dir}, re-installing...")
            shutil.rmtree(bootstrap_dir, ignore_errors=True)
    if not bootstrap_pkg_dir.is_dir():
        info(f"Bootstrapping xdevice in {bootstrap_dir} ...")
        install_args = [
            sys.executable, "-m", "pip", "install",
            "--no-deps", "--disable-pip-version-check",
            "--target", str(bootstrap_dir),
        ] + [str(p) for p in packages]
        subprocess.check_call(install_args, timeout=120)
        info("xdevice bootstrapped")

    env = os.environ.copy()
    env["HOME"] = str(home_dir)
    env["PYTHONPATH"] = str(bootstrap_dir)
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    home_dir.mkdir(parents=True, exist_ok=True)

    runner_script = bootstrap_dir / "_xts_runner.sh"
    runner_script.write_text(
        "#!/bin/bash\n"
        f'export HOME={shlex.quote(str(home_dir))}\n'
        f'export PYTHONPATH={shlex.quote(str(bootstrap_dir))}\n'
        f'exec {sys.executable} -m xdevice "$@"\n'
    )
    runner_script.chmod(0o755)
    return str(runner_script)


# ---------------------------------------------------------------------------
# Test discovery
# ---------------------------------------------------------------------------

def list_ace_test_modules(
    testcases_dir: Path, pattern: str = "ActsAce*", variant: str = "any",
) -> list[str]:
    modules = set()
    variant_suffix, _ = TEST_VARIANTS.get(variant, ("", ""))
    for json_file in sorted(testcases_dir.glob(f"{pattern}.json")):
        if json_file.name.endswith(".syscap.json"):
            continue
        name = json_file.stem
        if variant == "static" and variant_suffix not in name:
            continue
        if variant == "dynamic" and variant_suffix not in name:
            continue
        modules.add(name)
    return sorted(modules)


def _load_duration_cache() -> dict[str, float]:
    """Load per-module duration from cycle1 analysis (best-effort)."""
    cache_path = Path(
        os.environ.get("XTS_DURATION_CACHE", "")
    )
    if not cache_path.exists():
        return {}
    try:
        import json as _json
        with open(cache_path) as f:
            data = _json.load(f)
        result = {}
        for hap_name, info in data.items():
            mod_name = hap_name.replace(".hap", "")
            result[mod_name] = float(info.get("duration_sec", 0))
        return result
    except Exception:
        return {}


def partition_tests(modules: list[str], num_shards: int) -> list[list[str]]:
    """Distribute modules across shards by measured duration (longest-job-first).

    Uses cycle1_hap_analysis.json for duration data. Falls back to round-robin
    if no data available. This ensures shards finish at roughly the same time.
    """
    durations = _load_duration_cache()

    if not durations or not any(m in durations for m in modules):
        # No data — fall back to round-robin
        shards = [[] for _ in range(num_shards)]
        for i, mod in enumerate(modules):
            shards[i % num_shards].append(mod)
        return shards

    # Sort by duration descending (longest first) for greedy bin-packing
    weighted = sorted(
        modules,
        key=lambda m: durations.get(m, 60),  # default 60s for unknown
        reverse=True,
    )

    shard_times = [0.0] * num_shards
    shard_modules: list[list[str]] = [[] for _ in range(num_shards)]
    for mod in weighted:
        dur = durations.get(mod, 60)
        # Assign to shard with smallest total time
        min_idx = min(range(num_shards), key=lambda i: shard_times[i])
        shard_modules[min_idx].append(mod)
        shard_times[min_idx] += dur

    # Sort modules within each shard alphabetically for readability
    for s in shard_modules:
        s.sort()

    return shard_modules


# ---------------------------------------------------------------------------
# Shard suite creation (xdevice config files)
# ---------------------------------------------------------------------------

def write_user_config_xml(config_dir: Path, device_sn: str) -> Path:
    root = ET.Element("user_config")
    env_elem = ET.SubElement(root, "environment")
    support = ET.SubElement(env_elem, "support_device")
    ET.SubElement(support, "device").text = "true"
    dev = ET.SubElement(env_elem, "device", type="usb-hdc")
    ET.SubElement(dev, "ip")
    ET.SubElement(dev, "port")
    ET.SubElement(dev, "sn").text = device_sn
    tc = ET.SubElement(root, "testcases")
    ET.SubElement(tc, "dir")
    res = ET.SubElement(root, "resource")
    ET.SubElement(res, "dir")
    config_path = config_dir / "user_config.xml"
    tree = ET.ElementTree(root)
    tree.write(str(config_path), xml_declaration=True, encoding="UTF-8")
    return config_path


def write_acts_json(config_dir: Path, template_path: Path | None = None) -> Path:
    if template_path and template_path.exists():
        shutil.copy2(template_path, config_dir / "acts.json")
        return config_dir / "acts.json"
    config = {
        "description": "ArkUI ACE engine XTS full run",
        "kits": [
            {
                "type": "PropertyCheckKit",
                "property-name": "ro.build.type",
                "expected-value": "user",
                "throw-error": "false",
            },
            {
                "type": "ShellKit",
                "run-command": [
                    "remount",
                    "mkdir /data/data/resource",
                    "chmod -R 777 /data/data/resource",
                    "settings put global verifier_verify_hdc_installs 0",
                    "settings put secure hdc_install_need_confirm 0",
                    "settings put secure smart_suggestion_enable 1",
                ],
                "teardown-command": [
                    "remount",
                    "rm -rf /data/data/resource",
                ],
            },
        ],
    }
    config_path = config_dir / "acts.json"
    config_path.write_text(json.dumps(config, indent=2))
    return config_path


def create_shard_suite(
    acts_root: Path,
    shard_dir: Path,
    module_names: list[str],
    device_sn: str,
) -> Path:
    testcases_src = acts_root / "testcases"
    testcases_dst = shard_dir / "testcases"
    config_dst = shard_dir / "config"

    testcases_dst.mkdir(parents=True, exist_ok=True)
    config_dst.mkdir(parents=True, exist_ok=True)

    missing = []
    for mod in module_names:
        json_src = testcases_src / f"{mod}.json"
        hap_src = testcases_src / f"{mod}.hap"
        if not json_src.exists():
            missing.append(f"{mod}.json")
            continue
        for ext in (".json", ".hap", ".moduleInfo", ".syscap.json"):
            src = testcases_src / f"{mod}{ext}"
            if src.exists():
                shutil.copy2(src, testcases_dst / f"{mod}{ext}")
        if not hap_src.exists():
            warn(f"Module {mod}: .json found but .hap missing — xdevice may fail")

    if missing:
        die(f"Missing required files for {len(missing)} module(s): {', '.join(missing[:5])}")

    write_user_config_xml(config_dst, device_sn)

    template_acts_json = acts_root / "config" / "acts.json"
    write_acts_json(config_dst, template_acts_json if template_acts_json.exists() else None)

    template_validator = acts_root / "config" / "validator.json"
    if template_validator.exists():
        shutil.copy2(template_validator, config_dst / "validator.json")

    tools_src = acts_root / "tools"
    if tools_src.exists() and tools_src.is_dir():
        tools_dst = shard_dir / "tools"
        if tools_dst.exists():
            shutil.rmtree(tools_dst)
        shutil.copytree(tools_src, tools_dst, symlinks=True)

    return shard_dir


# ---------------------------------------------------------------------------
# Shard execution
# ---------------------------------------------------------------------------

def _ssh_run(server: str, *cmd: str, timeout: int = 30) -> subprocess.CompletedProcess:
    ssh_user = os.environ.get("OHOS_SSH_USER", os.environ.get("USER", ""))
    target = f"{ssh_user}@{server}" if ssh_user else server
    return subprocess.run(
        ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target, *cmd],
        capture_output=True, text=True, timeout=timeout,
    )


def _all_modules_unavailable(report_dir: Path) -> bool:
    """Check if all modules in the summary report are unavailable (device allocation failure)."""
    summary = report_dir / "summary_report.xml"
    if not summary.exists():
        return False
    try:
        tree = ET.parse(summary)
        root = tree.getroot()
        total = int(root.get("modules", "0"))
        unavailable = int(root.get("unavailable", "0"))
        run_modules = int(root.get("runmodules", "0"))
        return total > 0 and unavailable == total and run_modules == 0
    except (ET.ParseError, ValueError):
        return False


def run_xdevice_shard(
    runner_script: str,
    shard_dir: Path,
    module_names: list[str],
    device_sn: str,
    report_root: Path,
    timeout: int = DEFAULT_XDEVICE_TIMEOUT,
    server: str = "",
) -> dict[str, Any]:
    shard_label = shard_dir.name
    report_dir = report_root / shard_label
    report_dir.mkdir(parents=True, exist_ok=True)

    tc_path = shard_dir / "testcases"
    config_path = shard_dir / "config"

    user_config = config_path / "user_config.xml"
    args = [runner_script, "run", "acts"]
    if user_config.exists():
        args += ["-c", "config/user_config.xml"]
    args += [
        "-tcpath", "testcases",
        "-rp", shard_label,
        "-sn", device_sn,
        "-l", ";".join(module_names),
    ]

    start_time = time.time()
    result: dict[str, Any] = {
        "shard": shard_label,
        "module_count": len(module_names),
        "modules": module_names,
        "started_at": utc_now_str(),
        "exit_code": -1,
        "duration_s": 0.0,
        "report_dir": str(report_dir),
        "success": False,
        "errors": [],
    }

    info(f"[{shard_label}] Running {len(module_names)} modules on {device_sn}")
    try:
        if server:
            result = _run_shard_remote(
                server, args, shard_dir, shard_label,
                report_dir, result, timeout,
            )
        else:
            result = _run_shard_local(
                args, shard_dir, shard_label,
                report_dir, result, timeout,
            )

    except subprocess.TimeoutExpired:
        result["errors"].append(f"Timed out after {timeout}s")
        result["exit_code"] = -2
    except Exception as e:
        result["errors"].append(str(e))
        result["exit_code"] = -3

    # Retry once if all modules were unavailable (device allocation race condition)
    if _all_modules_unavailable(report_dir) and module_names:
        warn(f"[{shard_label}] All {len(module_names)} modules unavailable — "
             "retrying after 30s (device allocation race condition)")
        time.sleep(30)
        result["errors"] = []
        result["exit_code"] = -1
        try:
            if server:
                result = _run_shard_remote(
                    server, args, shard_dir, shard_label,
                    report_dir, result, timeout,
                )
            else:
                result = _run_shard_local(
                    args, shard_dir, shard_label,
                    report_dir, result, timeout,
                )
        except subprocess.TimeoutExpired:
            result["errors"].append(f"Timed out after {timeout}s")
            result["exit_code"] = -2
        except Exception as e:
            result["errors"].append(str(e))
            result["exit_code"] = -3

    result["duration_s"] = round(time.time() - start_time, 1)
    result["finished_at"] = utc_now_str()

    return result


def _run_shard_local(
    args: list[str],
    shard_dir: Path,
    shard_label: str,
    report_dir: Path,
    result: dict[str, Any],
    timeout: int,
) -> dict[str, Any]:
    run_env = os.environ.copy()
    canonical_hdc = Path(DEFAULT_HDC_PATH)
    if canonical_hdc.is_file():
        run_env["PATH"] = str(canonical_hdc.parent) + os.pathsep + run_env.get("PATH", "")
    proc = subprocess.run(
        args,
        timeout=timeout,
        capture_output=True, text=True,
        cwd=str(shard_dir),
        env=run_env,
    )
    result["exit_code"] = proc.returncode
    result["success"] = proc.returncode == 0

    xdevice_report_src = shard_dir / "reports" / shard_label
    if xdevice_report_src.exists():
        shutil.copytree(str(xdevice_report_src), str(report_dir),
                        dirs_exist_ok=True)

    (report_dir / "xdevice_stdout.log").write_text(proc.stdout or "")
    (report_dir / "xdevice_stderr.log").write_text(proc.stderr or "")

    if not result["success"]:
        result["errors"].append(f"xdevice exited code {proc.returncode}")

    result["failure_details"] = _extract_failures_from_reports(report_dir)

    return result


def _run_shard_remote(
    server: str,
    args: list[str],
    shard_dir: Path,
    shard_label: str,
    report_dir: Path,
    result: dict[str, Any],
    timeout: int,
) -> dict[str, Any]:
    ssh_user = os.environ.get("OHOS_SSH_USER", os.environ.get("USER", ""))
    target = f"{ssh_user}@{server}" if ssh_user else server
    remote_base = f"/tmp/xts_shard_{shard_label}"
    remote_shard = f"{remote_base}/shard"
    remote_reports = f"{remote_shard}/reports/{shard_label}"
    # Quote all remote paths for safe shell interpolation
    q_base = shlex.quote(remote_base)
    q_shard = shlex.quote(remote_shard)

    # Resolve xdevice bootstrap dir (same as bootstrap_xdevice produces)
    runner_script_path = Path(args[0])

    # Bootstrap is on NFS — accessible from all servers, no rsync needed

    # 1. Create remote shard dir, clean old reports, and rsync contents
    subprocess.run(
        ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
         f"mkdir -p {q_shard} && rm -rf {q_shard}/reports"],
        capture_output=True, text=True, timeout=30,
    )
    rsync_proc = subprocess.run(
        ["rsync", "-az", "--delete", f"{shard_dir}/", f"{target}:{remote_shard}/"],
        capture_output=True, text=True, timeout=120,
    )
    if rsync_proc.returncode != 0:
        result["errors"].append(f"rsync failed: {rsync_proc.stderr}")
        return result

    # 2. Ensure hdc daemon is running on remote server before xdevice starts.
    #    Multiple xdevice instances on the same server can race to init the daemon,
    #    causing device allocation failures ("0 devices found").
    tools_dir = os.environ.get("OHOS_TOOLS_DIR", "")
    path_export = f"export PATH={tools_dir}:$PATH && " if tools_dir else ""
    prestart = (
        f"{path_export}"
        "hdc -l5 start 2>/dev/null; sleep 2"
    )
    subprocess.run(
        ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
         f"bash -c {shlex.quote(prestart)}"],
        capture_output=True, text=True, timeout=30,
    )

    # 3. Run xdevice on remote server, then rsync reports back even on timeout
    tmux_session = f"xts-{shard_label}"
    q_session = shlex.quote(tmux_session)
    path_prefix = f"export PATH={tools_dir}:$PATH && " if tools_dir else ""
    remote_cmd = (
        f"{path_prefix}"
        f"cd {q_shard} && "
        + " ".join(shlex.quote(a) for a in args)
    )
    proc_stdout = ""
    proc_stderr = ""

    try:
        if _remote_has_tmux(target):
            # --- tmux path: resilient to SSH disconnects ---
            info(f"[{shard_label}] Starting in tmux session: {tmux_session}")
            remote_cmd_wrapped = (
                f"{remote_cmd} > {q_base}/stdout.log 2> {q_base}/stderr.log; "
                f"echo $? > {q_base}/exit_code"
            )
            tmux_start = (
                f"tmux kill-session -t {q_session} 2>/dev/null; "
                f"tmux new-session -d -s {q_session} {shlex.quote(remote_cmd_wrapped)}"
            )
            try:
                subprocess.run(
                    ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
                     f"bash -c {shlex.quote(tmux_start)}"],
                    capture_output=True, text=True, timeout=30,
                )
            except Exception as e:
                result["errors"].append(f"tmux start failed: {e}")
                result["exit_code"] = -4

            # Poll until tmux session ends or timeout
            if not result["errors"]:
                t0 = time.time()
                while time.time() - t0 < timeout:
                    try:
                        chk = subprocess.run(
                            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
                             f"tmux has-session -t {q_session} 2>/dev/null"],
                            capture_output=True, timeout=15,
                        )
                        if chk.returncode != 0:
                            break  # session gone = xdevice finished
                    except Exception:
                        pass  # SSH blip — keep polling
                    time.sleep(30)
                else:
                    # Timeout — kill tmux session
                    try:
                        subprocess.run(
                            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
                             f"tmux kill-session -t {q_session} 2>/dev/null"],
                            capture_output=True, timeout=15,
                        )
                    except Exception:
                        pass
                    result["errors"].append(f"Timed out after {timeout}s")
                    result["exit_code"] = -2

            # Read exit code and logs from remote
            if not result["errors"]:
                try:
                    ec = subprocess.run(
                        ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
                         f"cat {q_base}/exit_code 2>/dev/null"],
                        capture_output=True, text=True, timeout=10,
                    )
                    exit_code = int(ec.stdout.strip()) if ec.stdout.strip() else -1
                    result["exit_code"] = exit_code
                    result["success"] = exit_code == 0
                    if not result["success"]:
                        result["errors"].append(f"xdevice exited code {exit_code}")
                except Exception as e:
                    result["errors"].append(f"Failed to read exit code: {e}")

            try:
                so = subprocess.run(
                    ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
                     f"cat {q_base}/stdout.log 2>/dev/null"],
                    capture_output=True, text=True, timeout=10,
                )
                proc_stdout = so.stdout or ""
                se = subprocess.run(
                    ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
                     f"cat {q_base}/stderr.log 2>/dev/null"],
                    capture_output=True, text=True, timeout=10,
                )
                proc_stderr = se.stdout or ""
            except Exception:
                pass

        else:
            # --- fallback: direct synchronous SSH (same as before) ---
            warn(f"[{shard_label}] tmux not available on {server}, using direct SSH")
            proc = subprocess.run(
                ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
                 f"bash -c {shlex.quote(remote_cmd)}"],
                capture_output=True, text=True, timeout=timeout,
            )
            result["exit_code"] = proc.returncode
            result["success"] = proc.returncode == 0
            proc_stdout = proc.stdout or ""
            proc_stderr = proc.stderr or ""
            if not result["success"]:
                result["errors"].append(f"xdevice exited code {proc.returncode}")

    except subprocess.TimeoutExpired:
        result["errors"].append(f"Timed out after {timeout}s")
        result["exit_code"] = -2
        raise
    finally:
        # 4. Always copy reports back from remote, even after timeout
        try:
            if report_dir.exists():
                for f in report_dir.iterdir():
                    if f.is_file():
                        f.unlink()
            subprocess.run(
                ["rsync", "-az", f"{target}:{remote_reports}/", f"{report_dir}/"],
                capture_output=True, text=True, timeout=120,
            )
        except Exception:
            pass
        try:
            (report_dir / "xdevice_stdout.log").write_text(proc_stdout)
            (report_dir / "xdevice_stderr.log").write_text(proc_stderr)
        except Exception:
            pass

    result["failure_details"] = _extract_failures_from_reports(report_dir)

    # 5. Cleanup remote shard + tmux session
    subprocess.run(
        ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", target,
         f"tmux kill-session -t {q_session} 2>/dev/null; rm -rf {q_base}"],
        capture_output=True, text=True, timeout=30,
    )

    return result


def _extract_failures_from_reports(report_dir: Path) -> list[dict[str, str]]:
    """Parse result XMLs and hilog to extract failure details for failed tests."""
    failures: list[dict[str, str]] = []
    for xml_file in sorted(report_dir.glob("result/*.xml")):
        try:
            tree = ET.parse(xml_file)
        except ET.ParseError:
            continue
        module_name = tree.getroot().get("name", xml_file.stem)
        for tc in tree.iter("testcase"):
            if tc.get("result") == "false":
                failures.append({
                    "module": module_name,
                    "test": tc.get("name", ""),
                    "class": tc.get("classname", ""),
                    "message": tc.get("message", ""),
                    "time": tc.get("time", ""),
                })
    return failures


# ---------------------------------------------------------------------------
# Report merging
# ---------------------------------------------------------------------------

def merge_reports(
    shard_results: list[dict[str, Any]],
    shard_info: list[tuple[str, Path, list[str], str, str]],
    output_dir: Path,
    label: str,
    total_modules: int,
    total_wall_s: float,
) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "run_label": label,
        "started_at": min(r.get("started_at", "") for r in shard_results),
        "finished_at": max(r.get("finished_at", "") for r in shard_results),
        "total_modules": total_modules,
        "device_count": len(shard_info),
        "devices": {},
        "aggregate": {
            "successful": 0,
            "failed": 0,
            "timed_out": 0,
            "total_duration_s": 0.0,
        },
    }

    # Map shard names to (serial, server) for safe async result matching
    shard_meta = {name: (serial, server) for name, _, _, serial, server in shard_info}

    for r in shard_results:
        shard_name = r["shard"]
        meta = shard_meta.get(shard_name)
        if not meta:
            continue
        device_sn, server = meta

        if device_sn not in summary["devices"]:
            summary["devices"][device_sn] = {
                "host": server,
                "serial": device_sn,
                "module_count": 0,
                "success": True,
                "duration_s": 0.0,
                "exit_code": 0,
                "errors": [],
            }
        dev_entry = summary["devices"][device_sn]
        dev_entry["module_count"] += r["module_count"]
        dev_entry["duration_s"] = max(dev_entry["duration_s"], r["duration_s"])

        if not r["success"]:
            dev_entry["success"] = False
            dev_entry["exit_code"] = r["exit_code"]
            dev_entry["errors"].extend(r.get("errors", []))

    for device_sn, dev in summary["devices"].items():
        if dev["success"]:
            summary["aggregate"]["successful"] += 1
        elif dev["exit_code"] == -2:
            summary["aggregate"]["timed_out"] += 1
        else:
            summary["aggregate"]["failed"] += 1
        summary["aggregate"]["total_duration_s"] = max(
            summary["aggregate"]["total_duration_s"], dev["duration_s"]
        )

    summary["total_wall_clock_s"] = total_wall_s
    summary["output_dir"] = str(output_dir)

    report_path = output_dir / "full_run_report.json"
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(summary, indent=2))
    summary["report_path"] = str(report_path)
    return summary


def print_summary(report: dict[str, Any]) -> None:
    sep = "=" * 72
    agg = report["aggregate"]
    print(f"\n{sep}")
    print(f"  ARKUI ACE ENGINE XTS FULL RUN: {report.get('run_label', 'unnamed')}")
    print(sep)
    print(f"  Total modules:    {report['total_modules']}")
    print(f"  Devices:          {report['device_count']}")
    print(f"  Successful:       {agg['successful']}")
    print(f"  Failed:           {agg['failed']}")
    print(f"  Timed out:        {agg['timed_out']}")
    print(f"  Wall duration:    {agg['total_duration_s']:.0f}s")
    print(f"  Output:           {report.get('output_dir', '?')}")
    print(sep)

    for serial, dev in report["devices"].items():
        status = "PASS" if dev["success"] else "FAIL"
        short = serial[-6:]
        err_line = ""
        if dev["errors"]:
            err_count = len(dev["errors"])
            first = dev["errors"][0]
            err_line = f" | {first}"
            if err_count > 1:
                err_line += f" (+{err_count - 1} more)"
        print(f"  [{status}] {short} ({dev['host']}): {dev['module_count']} modules, "
              f"{dev['duration_s']:.0f}s{err_line}")
    print(sep)
    print(f"  Full report: {report.get('report_path', 'N/A')}")
    print(sep)
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run all ArkUI ACE engine XTS tests across multiple boards using xdevice.",
    )
    parser.add_argument(
        "--acts-root", required=True,
        help="Path to ACTS suite root (testcases/, config/, tools/)",
    )
    parser.add_argument(
        "--boards",
        help="Comma-separated board short serials from boards.conf (e.g. 6c3800,feb8800)",
    )
    parser.add_argument(
        "--devices",
        help="Comma-separated device serials (overrides boards.conf)",
    )
    parser.add_argument(
        "--conf-dir",
        default=None,
        help="Config directory (default: conf/ relative to script)",
    )
    parser.add_argument(
        "--shards", type=int, default=0,
        help="Number of shards (default: one per device)",
    )
    parser.add_argument(
        "--label", default=f"full-run-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
        help="Run label for reporting",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Output directory (default: ./xts_full_runs/<label>)",
    )
    parser.add_argument(
        "--hdc", default=None,
        help="Path to HDC binary",
    )
    parser.add_argument(
        "--pattern", default=DEFAULT_TEST_PATTERN,
        help="Glob pattern for test modules (default: ActsAce*)",
    )
    parser.add_argument(
        "--modules",
        default=None,
        help="Comma-separated list of exact module names (bypasses discovery)",
    )
    parser.add_argument(
        "--variant", choices=list(TEST_VARIANTS), default="any",
        help="Test variant: static, dynamic, any (default: any)",
    )
    parser.add_argument(
        "--parallel", type=int, default=0,
        help="Max parallel shards (default: equal to shard count)",
    )
    parser.add_argument(
        "--timeout", type=int, default=DEFAULT_XDEVICE_TIMEOUT,
        help=f"Per-shard timeout in seconds (default: {DEFAULT_XDEVICE_TIMEOUT})",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print plan without executing",
    )
    parser.add_argument(
        "--skip-connect", action="store_true",
        help="Skip HDC connection checks",
    )
    parser.add_argument(
        "--skip-init", action="store_true",
        help="Skip board initialization (screen wake, USB dialog dismiss)",
    )

    args = parser.parse_args()

    acts_root = Path(args.acts_root).expanduser().resolve()
    if not (acts_root / "testcases").is_dir():
        # Common mistake: user points to extracted/ instead of extracted/suites/acts/acts/
        alt = acts_root / "suites" / "acts" / "acts"
        if (alt / "testcases").is_dir():
            die(f"Invalid ACTS root: {acts_root}/testcases/ not found. Did you mean:\n  --acts-root {alt}")
        die(f"Invalid ACTS root: {acts_root}/testcases/ not found")

    _ensure_tmux_session(args.label) if not args.dry_run else None

    script_dir = Path(__file__).resolve().parent
    conf_dir = Path(args.conf_dir) if args.conf_dir else script_dir / "conf"

    device_serials = [d.strip() for d in args.devices.split(",") if d.strip()] if args.devices else None
    board_shorts = [b.strip() for b in args.boards.split(",") if b.strip()] if args.boards else None

    boards = resolve_boards(conf_dir, board_shorts, device_serials)
    if not boards:
        die("No boards available. Configure conf/boards.conf or use --devices")

    devices = [b["serial"] for b in boards]
    num_shards = args.shards if args.shards > 0 else len(devices)
    parallel = args.parallel if args.parallel > 0 else num_shards

    output_dir = Path(args.output_dir) if args.output_dir else script_dir / "xts_full_runs" / args.label

    info(f"ACTS root:  {acts_root}")
    info(f"Devices:    {len(devices)} ({', '.join(b.get('short', s[-6:]) for b, s in zip(boards, devices))})")
    info(f"Shards:     {num_shards}")
    info(f"Parallel:   {parallel}")
    info(f"Output:     {output_dir}")
    info(f"Label:      {args.label}")

    if args.modules:
        test_modules = [m.strip() for m in args.modules.split(",") if m.strip()]
        info(f"Using {len(test_modules)} explicitly specified modules")
    else:
        test_modules = list_ace_test_modules(acts_root / "testcases", args.pattern, args.variant)
    if not test_modules:
        die(f"No test modules matching '{args.pattern}' (variant={args.variant}) in {acts_root}/testcases/")
    info(f"Found {len(test_modules)} test modules (variant={args.variant})")

    if args.dry_run:
        shards = partition_tests(test_modules, num_shards)
        for i, shard in enumerate(shards):
            b = boards[i % len(boards)]
            print(f"  Shard {i+1} ({b.get('short', '?')}, {b['serial'][-6:]}): {len(shard)} modules")
            for m in shard[:5]:
                print(f"    - {m}")
            if len(shard) > 5:
                print(f"    ... and {len(shard) - 5} more")
        return 0

    output_dir.mkdir(parents=True, exist_ok=True)
    global _run_log
    _run_log = open(output_dir / "run.log", "a", encoding="utf-8")

    hdc_bin = find_hdc(args.hdc)

    if not args.skip_connect:
        info("Checking HDC connectivity...")
        connectivity = check_hdc_connectivity(hdc_bin, devices)
        offline = [d for d, online in connectivity.items() if not online]
        if offline:
            info(f"Connecting offline devices: {[d[-6:] for d in offline]}")
            for dev in offline:
                if hdc_tconn(hdc_bin, dev):
                    info(f"  {dev[-6:]}: tconn initiated, waiting...")
                    if hdc_wait_online(hdc_bin, dev):
                        info(f"  {dev[-6:]}: ONLINE")
                    else:
                        warn(f"  {dev[-6:]}: still offline, will try anyway")
                else:
                    warn(f"  {dev[-6:]}: tconn failed, will try anyway")
        else:
            info("All devices connected")

    if not args.skip_init:
        info("Initializing boards (screen, USB dialog)...")
        init_boards(boards, hdc_bin)

    info("Bootstrapping xdevice...")
    runner_script = bootstrap_xdevice(acts_root)

    shards = partition_tests(test_modules, num_shards)
    durations = _load_duration_cache()
    for i, shard in enumerate(shards):
        if not shard:
            warn(f"Shard {i+1} is empty. Reduce --shards.")
            continue
        est = sum(durations.get(m, 60) for m in shard)
        info(f"  Shard {i+1}: {len(shard)} modules, ~{est:.0f}s estimated")

    temp_dir = Path(tempfile.mkdtemp(prefix="xts_full_run_"))
    info(f"Creating shard suites in {temp_dir}")

    shard_info = []  # (name, dir, modules, serial, server)
    for i, shard_modules in enumerate(shards):
        if not shard_modules:
            continue
        b = boards[i % len(boards)]
        dev = b["serial"]
        server = b.get("server", "")
        short = b.get("short", dev[-12:])
        shard_name = f"shard-{i+1:02d}-{short}"
        shard_dir = temp_dir / shard_name

        info(f"  {shard_name}: {len(shard_modules)} modules on {short}")
        create_shard_suite(acts_root, shard_dir, shard_modules, dev)
        shard_info.append((shard_name, shard_dir, shard_modules, dev, server))

    report_root = output_dir / "reports"
    report_root.mkdir(parents=True, exist_ok=True)

    info(f"\nRunning {len(shard_info)} shards ({parallel} parallel)...")
    shard_results = []
    start_wall = time.time()

    with ThreadPoolExecutor(max_workers=parallel) as executor:
        fut_to_shard = {}
        for shard_name, shard_dir, shard_modules, dev, server in shard_info:
            fut = executor.submit(
                run_xdevice_shard,
                runner_script,
                shard_dir,
                shard_modules,
                dev,
                report_root,
                args.timeout,
                server,
            )
            fut_to_shard[fut] = shard_name

        for fut in as_completed(fut_to_shard):
            shard_name = fut_to_shard[fut]
            try:
                result = fut.result()
                shard_results.append(result)
                status = "PASS" if result["success"] else "FAIL"
                info(f"[{shard_name}] {status}: {result['module_count']} modules, {result['duration_s']:.0f}s")
                if result.get("errors"):
                    for e in result["errors"][:2]:
                        warn(f"  {shard_name}: {e[:200]}")
                for fd in result.get("failure_details", []):
                    warn(f"  {shard_name} FAIL: {fd['module']}#{fd['test']}: {fd['message'][:120]}")
            except Exception as e:
                err(f"[{shard_name}] Execution failed: {e}")
                shard_results.append({
                    "shard": shard_name,
                    "module_count": 0,
                    "modules": [],
                    "started_at": utc_now_str(),
                    "exit_code": -99,
                    "duration_s": 0.0,
                    "report_dir": "",
                    "success": False,
                    "errors": [str(e)],
                    "finished_at": utc_now_str(),
                })

    total_wall = round(time.time() - start_wall, 1)
    info(f"All shards completed in {total_wall}s")

    report_shard_info = [(n, d, m, s, sv) for n, d, m, s, sv in shard_info]

    merged = merge_reports(shard_results, report_shard_info, output_dir, args.label,
                           len(test_modules), total_wall)

    # Clean up temporary shard directories
    try:
        shutil.rmtree(temp_dir)
        info(f"Cleaned up temp dir: {temp_dir}")
    except OSError:
        warn(f"Failed to clean up temp dir: {temp_dir}")

    print_summary(merged)

    has_failures = merged["aggregate"]["failed"] or merged["aggregate"]["timed_out"]
    return 1 if has_failures else 0


if __name__ == "__main__":
    sys.exit(main())
