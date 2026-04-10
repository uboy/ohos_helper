#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_RUN_STORE_ROOT = SCRIPT_DIR / "arkui-xts-selector" / ".runs"


def normalize_name(value: str | None, fallback: str = "bridge") -> str:
    raw = (value or "").strip().lower()
    raw = re.sub(r"[^a-z0-9._-]+", "-", raw)
    raw = re.sub(r"-{2,}", "-", raw).strip("-.")
    return raw or fallback


def compact_token(value: str | None) -> str:
    return "".join(ch for ch in str(value or "").lower() if ch.isalnum())


def load_selector_report(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"selector report is not a JSON object: {path}")
    return payload


def find_latest_selector_report(run_store_root: Path) -> Path:
    candidates = sorted(
        run_store_root.expanduser().resolve().rglob("selector_report.json"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise FileNotFoundError(f"no selector_report.json found under {run_store_root}")
    return candidates[0]


def collect_aa_test_targets(report: dict[str, Any]) -> list[dict[str, Any]]:
    selected_keys = set(report.get("execution_overview", {}).get("selected_target_keys", []))
    records: dict[str, dict[str, Any]] = {}
    for section_key in ("results", "symbol_queries"):
        for entry in report.get(section_key, []):
            for target in entry.get("run_targets", []):
                key = str(target.get("target_key") or target.get("test_json") or target.get("project") or "")
                if not key or not target.get("bundle_name"):
                    continue
                if selected_keys and key not in selected_keys and not target.get("selected_for_execution"):
                    continue
                records.setdefault(
                    key,
                    {
                        "target_key": key,
                        "project": str(target.get("project") or ""),
                        "bundle_name": str(target.get("bundle_name") or ""),
                        "module_name": str(target.get("driver_module_name") or "entry"),
                        "is_static": "static" in compact_token(target.get("project")),
                        "name": normalize_name(
                            target.get("xdevice_module_name")
                            or target.get("build_target")
                            or target.get("project")
                            or key,
                            fallback="aa-test",
                        ),
                    },
                )
    return [records[key] for key in sorted(records)]


def _ps_single_quoted(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def _bundle_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _readme_text(
    *,
    bridge_name: str,
    server_host: str,
    server_user: str,
    server_ssh_port: int,
    server_hdc_port: int,
    windows_hdc_port: int,
    selector_report_name: str | None,
    aa_target_count: int,
) -> str:
    local_run_note = ""
    if selector_report_name and aa_target_count > 0:
        local_run_note = (
            "\n5. To run the packaged aa_test targets directly on Windows:\n"
            "   powershell -ExecutionPolicy Bypass -File .\\run_selected_aa_tests.ps1\n"
        )
    return f"""Windows RK3568 bridge bundle: {bridge_name}

This archive helps with two flows:

1. expose the USB-attached RK3568 device from this Windows PC to the Linux server over SSH + HDC
2. optionally run the packaged aa_test targets locally on Windows

Server-side endpoint after the bridge starts:
  127.0.0.1:{server_hdc_port}

Server-side examples:
  ohos xts select <pr-or-query> --hdc-endpoint 127.0.0.1:{server_hdc_port}
  ohos xts run last --hdc-endpoint 127.0.0.1:{server_hdc_port}

What you need on Windows:

- OpenSSH client (`ssh`) available in PATH
- `hdc.exe` available in PATH or placed next to these scripts
- the RK3568 device connected locally by USB

How to use:

1. If this Windows PC already has an `hdc.exe` server or a stale bridge from an earlier run:
   powershell -ExecutionPolicy Bypass -File .\\stop_hdc_bridge.ps1 -StopHdcServer

2. Start the HDC bridge and SSH reverse tunnel:
   powershell -ExecutionPolicy Bypass -File .\\start_hdc_bridge.ps1

   The start script already stops the previously tracked bridge and restarts
   the local HDC server on 127.0.0.1:{windows_hdc_port} by default.

3. Check that the local Windows HDC server sees the device:
   powershell -ExecutionPolicy Bypass -File .\\check_local_device.ps1

4. On the Linux server, run your XTS flow with:
   --hdc-endpoint 127.0.0.1:{server_hdc_port}
{local_run_note}
Bridge defaults:

- server host: {server_host}
- server user: {server_user}
- server ssh port: {server_ssh_port}
- server hdc port: {server_hdc_port}
- windows local hdc port: {windows_hdc_port}
- packaged selector report: {selector_report_name or "not included"}
- packaged aa_test targets: {aa_target_count}
"""


def _bridge_config_payload(
    *,
    bridge_name: str,
    server_host: str,
    server_user: str,
    server_ssh_port: int,
    server_hdc_port: int,
    windows_hdc_port: int,
    selector_report_name: str | None,
    aa_targets: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "generated_at": _bundle_timestamp(),
        "bridge_name": bridge_name,
        "server_host": server_host,
        "server_user": server_user,
        "server_ssh_port": server_ssh_port,
        "server_hdc_port": server_hdc_port,
        "windows_hdc_port": windows_hdc_port,
        "server_hdc_endpoint": f"127.0.0.1:{server_hdc_port}",
        "selector_report_name": selector_report_name,
        "aa_target_count": len(aa_targets),
    }


def _start_bridge_script(config: dict[str, Any]) -> str:
    return f"""param(
  [string]$ServerHost = {_ps_single_quoted(config["server_host"])},
  [string]$ServerUser = {_ps_single_quoted(config["server_user"])},
  [int]$ServerSshPort = {int(config["server_ssh_port"])},
  [int]$ServerHdcPort = {int(config["server_hdc_port"])},
  [int]$WindowsHdcPort = {int(config["windows_hdc_port"])},
  [string]$HdcPath = 'hdc.exe',
  [switch]$SkipTrackedBridgeStop,
  [switch]$SkipHdcRestart
)

$ErrorActionPreference = 'Stop'
$statePath = Join-Path $PSScriptRoot '.bridge-state.json'

function Resolve-Tool([string]$Tool) {{
  if (Test-Path $Tool) {{
    return (Resolve-Path $Tool).Path
  }}
  $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
  if ($cmd) {{
    return $cmd.Source
  }}
  throw "Unable to find $Tool. Put hdc.exe next to this script or add it to PATH."
}}

function Stop-TrackedBridgeProcesses([string]$StatePath) {{
  if (!(Test-Path $StatePath)) {{
    return
  }}
  $state = Get-Content $StatePath -Raw | ConvertFrom-Json
  foreach ($prop in @('ssh_process_id', 'hdc_process_id')) {{
    $pidValue = [int]($state.$prop)
    if ($pidValue -gt 0) {{
      Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
    }}
  }}
  Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
  Write-Host 'Stopped tracked bridge processes from the previous run.'
}}

$hdcEndpoint = "127.0.0.1:$WindowsHdcPort"
if (-not $SkipTrackedBridgeStop) {{
  Stop-TrackedBridgeProcesses $statePath
}}

$hdc = Resolve-Tool $HdcPath
if (-not $SkipHdcRestart) {{
  Write-Host "Restarting the local HDC server on $hdcEndpoint"
  & $hdc -s $hdcEndpoint kill | Out-Host
}}
$hdcArgs = @('-s', $hdcEndpoint, '-m')
$hdcProcess = Start-Process -FilePath $hdc -ArgumentList $hdcArgs -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
& $hdc -s $hdcEndpoint list targets | Out-Host

$sshArgs = @(
  '-NT',
  '-o', 'ExitOnForwardFailure=yes',
  '-o', 'ServerAliveInterval=30',
  '-o', 'ServerAliveCountMax=3',
  '-R', "127.0.0.1:$ServerHdcPort`:127.0.0.1:$WindowsHdcPort",
  '-p', "$ServerSshPort",
  "$ServerUser@$ServerHost"
)
$sshProcess = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -PassThru

$state = @{{
  generated_at = {_ps_single_quoted(config["generated_at"])};
  bridge_name = {_ps_single_quoted(config["bridge_name"])};
  hdc_process_id = $hdcProcess.Id;
  ssh_process_id = $sshProcess.Id;
  server_host = $ServerHost;
  server_user = $ServerUser;
  server_ssh_port = $ServerSshPort;
  server_hdc_port = $ServerHdcPort;
  windows_hdc_port = $WindowsHdcPort
}}
$state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
Write-Host "Bridge started. Linux-side HDC endpoint: 127.0.0.1:$ServerHdcPort"
"""


def _stop_bridge_script() -> str:
    return """param(
  [string]$HdcPath = 'hdc.exe',
  [int]$WindowsHdcPort = 8710,
  [switch]$StopHdcServer
)

$ErrorActionPreference = 'Stop'
$statePath = Join-Path $PSScriptRoot '.bridge-state.json'
function Resolve-Tool([string]$Tool) {
  if (Test-Path $Tool) {
    return (Resolve-Path $Tool).Path
  }
  $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }
  throw "Unable to find $Tool. Put hdc.exe next to this script or add it to PATH."
}

$hadState = Test-Path $statePath
if ($hadState) {
  $state = Get-Content $statePath -Raw | ConvertFrom-Json
  foreach ($prop in @('ssh_process_id', 'hdc_process_id')) {
    $pidValue = [int]($state.$prop)
    if ($pidValue -gt 0) {
      Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
    }
  }
  Remove-Item $statePath -Force -ErrorAction SilentlyContinue
  Write-Host 'Bridge processes were stopped.'
}

if ($StopHdcServer) {
  $hdc = Resolve-Tool $HdcPath
  $hdcEndpoint = "127.0.0.1:$WindowsHdcPort"
  Write-Host "Stopping the local HDC server on $hdcEndpoint"
  & $hdc -s $hdcEndpoint kill | Out-Host
}

if (!$hadState -and -not $StopHdcServer) {
  Write-Host 'No bridge state file found.'
}
"""


def _check_device_script(windows_hdc_port: int) -> str:
    return f"""param(
  [int]$WindowsHdcPort = {int(windows_hdc_port)},
  [string]$HdcPath = 'hdc.exe'
)

$ErrorActionPreference = 'Stop'
function Resolve-Tool([string]$Tool) {{
  if (Test-Path $Tool) {{
    return (Resolve-Path $Tool).Path
  }}
  $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
  if ($cmd) {{
    return $cmd.Source
  }}
  throw "Unable to find $Tool. Put hdc.exe next to this script or add it to PATH."
}}

$hdc = Resolve-Tool $HdcPath
& $hdc -s "127.0.0.1:$WindowsHdcPort" list targets
"""


def _run_selected_aa_tests_script(windows_hdc_port: int) -> str:
    return f"""param(
  [int]$WindowsHdcPort = {int(windows_hdc_port)},
  [string]$HdcPath = 'hdc.exe',
  [string]$Device = '',
  [switch]$ContinueOnFailure
)

$ErrorActionPreference = 'Stop'
$targetsPath = Join-Path $PSScriptRoot 'aa_test_targets.json'
$logsDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

function Resolve-Tool([string]$Tool) {{
  if (Test-Path $Tool) {{
    return (Resolve-Path $Tool).Path
  }}
  $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
  if ($cmd) {{
    return $cmd.Source
  }}
  throw "Unable to find $Tool. Put hdc.exe next to this script or add it to PATH."
}}

$hdc = Resolve-Tool $HdcPath
$targets = Get-Content $targetsPath -Raw | ConvertFrom-Json
if (!$targets -or $targets.Count -eq 0) {{
  Write-Host 'No packaged aa_test targets were found.'
  exit 0
}}

foreach ($target in $targets) {{
  $args = @('-s', "127.0.0.1:$WindowsHdcPort")
  if ($Device) {{
    $args += @('-t', $Device)
  }}
  $args += @('shell', 'aa', 'test')
  if ($target.is_static) {{
    $moduleName = if ($target.module_name) {{ $target.module_name }} else {{ 'entry' }}
    $args += @('-b', $target.bundle_name, '-m', $moduleName, '-s', 'unittest', 'OpenHarmonyTestRunner')
  }} else {{
    $args += @('-p', $target.bundle_name, '-b', $target.bundle_name, '-s', 'unittest', 'OpenHarmonyTestRunner')
  }}
  $logPath = Join-Path $logsDir ($target.name + '.log')
  Write-Host ('Running ' + $target.target_key)
  & $hdc @args 2>&1 | Tee-Object -FilePath $logPath
  if ($LASTEXITCODE -ne 0 -and -not $ContinueOnFailure) {{
    Write-Error ('aa_test failed for ' + $target.target_key + '. See ' + $logPath)
    exit $LASTEXITCODE
  }}
}}
"""


def default_output_path(output_dir: Path, bridge_name: str) -> Path:
    timestamp = _bundle_timestamp()
    filename = f"{normalize_name(bridge_name, 'rk3568-bridge')}_{timestamp}.zip"
    return (output_dir.expanduser().resolve() / filename).resolve()


def package_windows_bundle(
    *,
    output_path: Path,
    bridge_name: str,
    server_host: str,
    server_user: str,
    server_ssh_port: int,
    server_hdc_port: int,
    windows_hdc_port: int,
    selector_report: Path | None,
) -> Path:
    report_payload: dict[str, Any] | None = None
    selector_report_name: str | None = None
    aa_targets: list[dict[str, Any]] = []
    if selector_report is not None:
        report_payload = load_selector_report(selector_report)
        selector_report_name = selector_report.name
        aa_targets = collect_aa_test_targets(report_payload)

    config = _bridge_config_payload(
        bridge_name=bridge_name,
        server_host=server_host,
        server_user=server_user,
        server_ssh_port=server_ssh_port,
        server_hdc_port=server_hdc_port,
        windows_hdc_port=windows_hdc_port,
        selector_report_name=selector_report_name,
        aa_targets=aa_targets,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("README.txt", _readme_text(
            bridge_name=bridge_name,
            server_host=server_host,
            server_user=server_user,
            server_ssh_port=server_ssh_port,
            server_hdc_port=server_hdc_port,
            windows_hdc_port=windows_hdc_port,
            selector_report_name=selector_report_name,
            aa_target_count=len(aa_targets),
        ))
        archive.writestr("bridge-config.json", json.dumps(config, indent=2, ensure_ascii=False) + "\n")
        archive.writestr("server-endpoint.txt", f"127.0.0.1:{server_hdc_port}\n")
        archive.writestr("start_hdc_bridge.ps1", _start_bridge_script(config))
        archive.writestr("stop_hdc_bridge.ps1", _stop_bridge_script())
        archive.writestr("check_local_device.ps1", _check_device_script(windows_hdc_port))
        if report_payload is not None:
            archive.writestr(selector_report_name or "selector_report.json", json.dumps(report_payload, indent=2, ensure_ascii=False) + "\n")
            archive.writestr("aa_test_targets.json", json.dumps(aa_targets, indent=2, ensure_ascii=False) + "\n")
            archive.writestr("run_selected_aa_tests.ps1", _run_selected_aa_tests_script(windows_hdc_port))
    return output_path


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a Windows helper bundle for RK3568 over SSH + HDC.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    package = subparsers.add_parser("package-windows", help="Create a Windows ZIP bundle for HDC bridge setup and optional aa_test execution.")
    package.add_argument("--bridge-name", default="rk3568-bridge", help="Friendly bundle name. Default: rk3568-bridge.")
    package.add_argument("--server-host", required=True, help="Linux server hostname or IP reached by Windows SSH.")
    package.add_argument("--server-user", required=True, help="Linux server user for the SSH reverse tunnel.")
    package.add_argument("--server-ssh-port", type=int, default=22, help="Linux SSH port. Default: 22.")
    package.add_argument("--server-hdc-port", type=int, default=28710, help="Linux-side forwarded HDC port. Default: 28710.")
    package.add_argument("--windows-hdc-port", type=int, default=8710, help="Windows-side local HDC service port. Default: 8710.")
    package.add_argument("--selector-report", type=Path, help="Optional selector_report.json to embed and convert into local aa_test commands.")
    package.add_argument("--last-report", action="store_true", help="Embed the latest selector_report.json from the run store.")
    package.add_argument("--run-store-root", type=Path, default=DEFAULT_RUN_STORE_ROOT, help=f"Run-store root used with --last-report. Default: {DEFAULT_RUN_STORE_ROOT}")
    package.add_argument("--output", type=Path, help="Explicit ZIP output path.")
    package.add_argument("--output-dir", type=Path, default=Path.cwd(), help="Directory used for the default ZIP name. Default: current directory.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    selector_report = args.selector_report
    if args.last_report:
        selector_report = find_latest_selector_report(args.run_store_root)
    if selector_report is not None:
        selector_report = selector_report.expanduser().resolve()
        if not selector_report.is_file():
            print(f"selector report not found: {selector_report}", file=sys.stderr)
            return 2
    output_path = args.output.expanduser().resolve() if args.output else default_output_path(args.output_dir, args.bridge_name)
    package_windows_bundle(
        output_path=output_path,
        bridge_name=args.bridge_name,
        server_host=args.server_host,
        server_user=args.server_user,
        server_ssh_port=args.server_ssh_port,
        server_hdc_port=args.server_hdc_port,
        windows_hdc_port=args.windows_hdc_port,
        selector_report=selector_report,
    )
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
