#!/usr/bin/env python3
from __future__ import annotations

import argparse
import atexit
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
ARKUI_XTS_SELECTOR_DIR = Path(
    os.environ.get("ARKUI_XTS_SELECTOR_DIR") or (SCRIPT_DIR / "arkui-xts-selector")
).expanduser().resolve()
SELECTOR_SRC_DIR = ARKUI_XTS_SELECTOR_DIR / "src"
if str(SELECTOR_SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SELECTOR_SRC_DIR))

from arkui_xts_selector.hdc_transport import (  # noqa: E402
    build_hdc_command,
    build_hdc_env,
    ensure_hdc_wrapper,
    render_shell_command,
    resolve_hdc_binary,
    resolve_hdc_library_dir,
)


def _device_wrapper_dir(
    *,
    hdc_path: str | None,
    hdc_endpoint: str | None,
    device: str | None,
) -> Path | None:
    if not hdc_path and not hdc_endpoint and not device:
        return None
    resolved_hdc = resolve_hdc_binary(hdc_path)
    if not resolved_hdc:
        return None
    tmp_dir = Path(tempfile.mkdtemp(prefix="ohos_tdd_hdc_")).resolve()
    atexit.register(shutil.rmtree, str(tmp_dir), ignore_errors=True)
    wrapper = tmp_dir / "hdc"
    command = [resolved_hdc]
    lines = [
        "#!/usr/bin/env bash",
        "set -e",
        'args=("$@")',
        "translated=()",
        "i=0",
        "has_target=0",
        "while [ $i -lt ${#args[@]} ]; do",
        '  arg="${args[$i]}"',
        '  if [ "$arg" = "-t" ] && [ $((i + 1)) -lt ${#args[@]} ]; then',
        '    translated+=("$arg" "${args[$((i + 1))]}")',
        "    has_target=1",
        "    i=$((i + 2))",
        "    continue",
        "  fi",
        '  if [ "$arg" = "-s" ] && [ $((i + 1)) -lt ${#args[@]} ]; then',
        '    next="${args[$((i + 1))]}"',
        '    case "$next" in',
        '      *:*) translated+=("$arg" "$next") ;;',
        '      *) translated+=("-t" "$next"); has_target=1 ;;',
        "    esac",
        "    i=$((i + 2))",
        "    continue",
        "  fi",
        '  translated+=("$arg")',
        "  i=$((i + 1))",
        "done",
    ]
    if device:
        lines.extend(
            [
                'if [ "$has_target" -eq 0 ]; then',
                f'  translated=("-t" {shlex.quote(device)} "${{translated[@]}}")',
                "fi",
            ]
        )
    exec_cmd = render_shell_command(command)
    if hdc_endpoint:
        lines.append(f'exec {exec_cmd} -s {shlex.quote(str(hdc_endpoint))} "${{translated[@]}}"')
    else:
        lines.append(f'exec {exec_cmd} "${{translated[@]}}"')
    wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
    wrapper.chmod(0o755)
    return tmp_dir


def _build_run_env(
    *,
    repo_root: Path,
    hdc_path: str | None,
    hdc_endpoint: str | None,
    device: str | None,
) -> dict[str, str]:
    env = build_hdc_env(hdc_path=hdc_path)
    wrapper_dir: Path | None = None
    if device:
        wrapper_dir = _device_wrapper_dir(
            hdc_path=hdc_path,
            hdc_endpoint=hdc_endpoint,
            device=device,
        )
    elif hdc_path or hdc_endpoint:
        try:
            wrapper_dir = ensure_hdc_wrapper(repo_root, hdc_path=hdc_path, hdc_endpoint=hdc_endpoint)
        except PermissionError:
            wrapper_dir = _device_wrapper_dir(
                hdc_path=hdc_path,
                hdc_endpoint=hdc_endpoint,
                device=None,
            )
    if wrapper_dir:
        existing_path = str(env.get("PATH") or os.environ.get("PATH") or "")
        env["PATH"] = f"{wrapper_dir}:{existing_path}" if existing_path else str(wrapper_dir)
    if hdc_endpoint and ":" in hdc_endpoint:
        env["OHOS_HDC_SERVER_PORT"] = hdc_endpoint.rsplit(":", 1)[1]
    return env


def _check_device_connected(*, hdc_path: str | None, hdc_endpoint: str | None, device: str | None) -> tuple[bool, str]:
    cmd = build_hdc_command(["list", "targets"], hdc_path=hdc_path, hdc_endpoint=hdc_endpoint)
    result = subprocess.run(
        cmd,
        env=build_hdc_env(hdc_path=hdc_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    output = (result.stdout or "").strip()
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if result.returncode != 0 or not lines or output == "[Empty]":
        return False, output
    if device:
        matches = [line for line in lines if line.split()[0] == device]
        return bool(matches), output
    return True, output


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="ohos_tdd_runner",
        description="Run developer_test UT with optional HDC endpoint/device routing.",
    )
    parser.add_argument("--repo-root", required=True, metavar="PATH", help="OHOS repository root")
    parser.add_argument("--runner-path", default="", metavar="PATH", help="Path to developer_test start.sh")
    parser.add_argument("--hdc-path", default="", metavar="PATH", help="Path to hdc binary")
    parser.add_argument("--hdc-endpoint", default="", metavar="HOST:PORT", help="Remote HDC endpoint")
    parser.add_argument("--device", default="", metavar="SERIAL", help="Target device serial")
    parser.add_argument("--dry-run", action="store_true", help="Print resolved command without execution")
    parser.add_argument("--framework-args", nargs=argparse.REMAINDER, default=[], help="Args after start.sh run")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).expanduser().resolve()
    runner_path = Path(args.runner_path).expanduser().resolve() if args.runner_path else (repo_root / "test" / "testfwk" / "developer_test" / "start.sh")
    if not runner_path.is_file():
        print(f"[ohos-tdd] error: developer_test runner not found: {runner_path}", file=sys.stderr)
        return 1

    hdc_path = str(args.hdc_path).strip() or None
    hdc_endpoint = str(args.hdc_endpoint).strip() or None
    device = str(args.device).strip() or None
    framework_args = [str(item) for item in (args.framework_args or []) if str(item).strip()]
    cmd = [str(runner_path), "run", *framework_args]

    if args.dry_run:
        print("[ohos-tdd] command:")
        print("  " + " ".join(shlex.quote(part) for part in cmd))
        if hdc_path:
            print(f"[ohos-tdd] hdc_path: {hdc_path}")
        if hdc_endpoint:
            print(f"[ohos-tdd] hdc_endpoint: {hdc_endpoint}")
        if device:
            print(f"[ohos-tdd] device: {device}")
        library_dir = resolve_hdc_library_dir(hdc_path)
        if library_dir:
            print(f"[ohos-tdd] hdc_library_path: {library_dir}")
        return 0

    ok, output = _check_device_connected(hdc_path=hdc_path, hdc_endpoint=hdc_endpoint, device=device)
    if not ok:
        print("[ohos-tdd] error: no reachable device for developer_test run.", file=sys.stderr)
        if output:
            print(output, file=sys.stderr)
        return 1

    env = _build_run_env(
        repo_root=repo_root,
        hdc_path=hdc_path,
        hdc_endpoint=hdc_endpoint,
        device=device,
    )
    return subprocess.run(cmd, cwd=str(repo_root), env=env).returncode


if __name__ == "__main__":
    raise SystemExit(main())
