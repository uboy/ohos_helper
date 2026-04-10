import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


OHOS_SH = Path("/data/shared/common/scripts/ohos.sh")


def run_cmd(cmd, cwd, env=None, check=True, input_text=None):
    return subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        input=input_text,
        capture_output=True,
        check=check,
    )


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


class OhosXtsWrapperTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)

        self.root = Path(self.tempdir.name)
        self.repo_root = self.root / "ohos_master"
        self.repo_root.mkdir()
        (self.repo_root / ".repo").mkdir()
        (self.repo_root / "build").mkdir()
        write_executable(self.repo_root / "build" / "prebuilts_download.sh", "#!/bin/bash\nexit 0\n")

        self.selector_dir = self.root / "arkui-xts-selector"
        (self.selector_dir / ".git").mkdir(parents=True)
        package_dir = self.selector_dir / "src" / "arkui_xts_selector"
        package_dir.mkdir(parents=True)
        self.changed_file = (
            self.repo_root
            / "foundation"
            / "arkui"
            / "ace_engine"
            / "frameworks"
            / "bridge"
            / "declarative_frontend"
            / "engine"
            / "jsi"
            / "nativeModule"
            / "arkts_native_common_bridge.cpp"
        )
        self.changed_file.parent.mkdir(parents=True, exist_ok=True)
        self.changed_file.write_text("// test fixture\n", encoding="utf-8")

        self.capture_path = self.root / "selector_capture.json"
        self.helper_capture_path = self.root / "helper_capture.json"
        self.bridge_capture_path = self.root / "bridge_capture.json"
        (package_dir / "__main__.py").write_text(
            (
                "import json\n"
                "import os\n"
                "import sys\n"
                "import time\n"
                "from pathlib import Path\n"
                "fake_tags = [item.strip() for item in os.environ.get('TEST_SELECTOR_FAKE_TAGS', '').split(',') if item.strip()]\n"
                "args = sys.argv[1:]\n"
                "if '--list-daily-tags' in args and fake_tags:\n"
                "  tag_type = args[args.index('--list-daily-tags') + 1] if args.index('--list-daily-tags') + 1 < len(args) else 'tests'\n"
                "  print(f'Listing {len(fake_tags)} most recent {tag_type} tags (component=fake, branch=master):')\n"
                "  for tag in fake_tags:\n"
                "    print(f'  {tag}')\n"
                "  sys.exit(0)\n"
                "sleep_seconds = float(os.environ.get('TEST_SELECTOR_SLEEP', '0') or '0')\n"
                "if sleep_seconds > 0:\n"
                "  time.sleep(sleep_seconds)\n"
                "capture_path = Path(os.environ['TEST_SELECTOR_CAPTURE'])\n"
                "capture_path.write_text(json.dumps({\n"
                "  'argv': args,\n"
                "  'env': {\n"
                "    'ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH': os.environ.get('ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH', ''),\n"
                "    'LD_LIBRARY_PATH': os.environ.get('LD_LIBRARY_PATH', ''),\n"
                "  },\n"
                "}, indent=2), encoding='utf-8')\n"
            ),
            encoding="utf-8",
        )
        self.fake_helper = self.root / "ohos-helper.py"
        write_executable(
            self.fake_helper,
            (
                "#!/usr/bin/env python3\n"
                "import json\n"
                "import os\n"
                "import sys\n"
                "from pathlib import Path\n"
                "capture_path = Path(os.environ['TEST_HELPER_CAPTURE'])\n"
                "capture_path.write_text(json.dumps({'argv': sys.argv[1:]}, indent=2), encoding='utf-8')\n"
            ),
        )
        self.fake_bridge_tool = self.root / "ohos_xts_bridge.py"
        write_executable(
            self.fake_bridge_tool,
            (
                "#!/usr/bin/env python3\n"
                "import json\n"
                "import os\n"
                "import sys\n"
                "import time\n"
                "from pathlib import Path\n"
                "sleep_seconds = float(os.environ.get('TEST_BRIDGE_SLEEP', '0') or '0')\n"
                "if sleep_seconds > 0:\n"
                "  time.sleep(sleep_seconds)\n"
                "capture_path = Path(os.environ['TEST_BRIDGE_CAPTURE'])\n"
                "capture_path.write_text(json.dumps({'argv': sys.argv[1:]}, indent=2), encoding='utf-8')\n"
            ),
        )

        self.hdc_lib_dir = self.root / "toolchains"
        self.hdc_lib_dir.mkdir()
        (self.hdc_lib_dir / "libusb_shared.so").write_text("", encoding="utf-8")
        self.fake_bin_dir = self.root / "fake-bin"
        self.fake_bin_dir.mkdir()
        write_executable(
            self.fake_bin_dir / "hostname",
            """#!/bin/bash
case "${1:-}" in
  -I)
    echo "10.55.0.9 127.0.0.1"
    ;;
  -f)
    echo "buildmonster1.example.net"
    ;;
  *)
    echo "buildmonster1"
    ;;
esac
""",
        )

        self.working_hdc = self.hdc_lib_dir / "hdc"
        write_executable(
            self.working_hdc,
            """#!/bin/bash
if [ "${1:-}" = "-h" ]; then
  echo "OpenHarmony device connector(HDC)"
  exit 0
fi
if [ "${1:-}" = "list" ] && [ "${2:-}" = "targets" ]; then
  echo "SER1"
  exit 0
fi
exit 0
""",
        )

        self.broken_hdc = self.root / "broken-hdc"
        write_executable(
            self.broken_hdc,
            """#!/bin/bash
echo "error while loading shared libraries: libusb_shared.so: cannot open shared object file: No such file or directory" >&2
exit 127
""",
        )

        self.conf_path = self.root / "test-ohos.conf"
        self.conf_path.write_text(
            "\n".join(
                [
                    f'FLASH_PY_PATH="{self.root / "broken_flash.py"}"',
                    f'HDC_PATH="{self.broken_hdc}"',
                    'HDC_LIBRARY_PATH=""',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        write_executable(self.root / "broken_flash.py", "#!/usr/bin/env python3\n")
        self.working_flash_root = self.root / "bin" / "linux"
        self.working_flash_root.mkdir(parents=True)
        write_executable(self.working_flash_root / "flash.py", "#!/usr/bin/env python3\n")
        (self.working_flash_root / "bin").mkdir(parents=True, exist_ok=True)
        write_executable(self.working_flash_root / "bin" / f"flash.{os.uname().machine}", "#!/bin/bash\nexit 0\n")

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.fake_bin_dir}:{self.hdc_lib_dir}:{self.env['PATH']}"
        self.env["HOME"] = str(self.root)
        self.env["OHOS_CONF"] = str(self.conf_path)
        self.env["ARKUI_XTS_SELECTOR_DIR"] = str(self.selector_dir)
        self.env["TEST_SELECTOR_CAPTURE"] = str(self.capture_path)
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.feedback_dir = self.root / "feedback"
        self.env["OHOS_FEEDBACK_DIR"] = str(self.feedback_dir)
        self.env["OHOS_HELPER"] = str(self.fake_helper)
        self.env["TEST_HELPER_CAPTURE"] = str(self.helper_capture_path)
        self.env["OHOS_XTS_BRIDGE_TOOL"] = str(self.fake_bridge_tool)
        self.env["TEST_BRIDGE_CAPTURE"] = str(self.bridge_capture_path)
        self.env["USER"] = "deviceuser"

    def run_and_signal(self, cmd, env, sig):
        proc = subprocess.Popen(
            cmd,
            cwd=self.repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            time.sleep(0.5)
            if sig == signal.SIGINT:
                os.killpg(proc.pid, sig)
            else:
                proc.send_signal(sig)
            stdout, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = proc.communicate(timeout=5)
            self.fail(f"process did not stop after signal {sig}: stdout={stdout!r} stderr={stderr!r}")
        return proc.returncode, stdout, stderr

    def test_xts_flash_prefers_working_hdc_from_path_when_configured_binary_is_broken(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "xts",
                "flash",
                "--firmware-component",
                "dayu200",
                "--firmware-build-tag",
                "20260409_180241",
                "--firmware-date",
                "20260409",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.capture_path.read_text(encoding="utf-8"))
        argv = capture["argv"]
        self.assertIn("--flash-daily-firmware", argv)
        self.assertIn("--flash-py-path", argv)
        self.assertIn("--hdc-path", argv)
        flash_index = argv.index("--flash-py-path")
        self.assertEqual(argv[flash_index + 1], str(self.working_flash_root / "flash.py"))
        hdc_index = argv.index("--hdc-path")
        self.assertEqual(argv[hdc_index + 1], str(self.working_hdc))
        self.assertEqual(capture["env"]["ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH"], str(self.hdc_lib_dir))
        self.assertTrue(capture["env"]["LD_LIBRARY_PATH"].startswith(str(self.hdc_lib_dir)))

    def test_xts_select_infers_changed_file_from_positional_path(self):
        relative_changed_file = f"./{self.changed_file.relative_to(self.repo_root)}"

        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "xts",
                "select",
                relative_changed_file,
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.capture_path.read_text(encoding="utf-8"))
        argv = capture["argv"]
        self.assertIn("--changed-file", argv)
        changed_file_index = argv.index("--changed-file")
        self.assertEqual(argv[changed_file_index + 1], relative_changed_file)
        self.assertNotIn("--pr-url", argv)
        self.assertIn("--top-projects", argv)
        self.assertIn("--run-label", argv)

    def test_feedback_saves_markdown_entry(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "feedback",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
            input_text="Tester\nXTS UX\nPlease make select output shorter.\n.\n",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        saved = sorted(self.feedback_dir.glob("*.md"))
        self.assertEqual(len(saved), 1)
        content = saved[0].read_text(encoding="utf-8")
        self.assertIn("Author: Tester", content)
        self.assertIn("Topic: XTS UX", content)
        self.assertIn("Please make select output shorter.", content)

    def test_help_xts_documents_remote_device_access(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "help",
                "xts",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ohos device help", result.stdout)
        self.assertIn("ohos device bridge help", result.stdout)
        self.assertNotIn("Remote device on another PC:", result.stdout)

    def test_help_device_documents_remote_device_access(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "help",
                "device",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("device - standalone device access and bridge helper", result.stdout)
        self.assertIn("Linux test server:", result.stdout)
        self.assertIn("Device host:", result.stdout)
        self.assertIn("Run on the Linux PC with the USB-connected device:", result.stdout)
        self.assertIn("Run on the Windows PC with the USB-connected device:", result.stdout)
        self.assertIn("auto-detects the Linux test server IP and current user", result.stdout)
        self.assertIn("--hdc-endpoint 127.0.0.1:28710", result.stdout)

    def test_device_bridge_help_explains_host_roles_and_auto_detection(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "device",
                "bridge",
                "help",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Linux test server:", result.stdout)
        self.assertIn("Windows device host:", result.stdout)
        self.assertIn("If '--server-host' is omitted", result.stdout)
        self.assertIn("ohos device bridge package-windows --last-report", result.stdout)

    def test_device_bridge_package_windows_auto_detects_server_host_and_user(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "device",
                "bridge",
                "package-windows",
                "--last-report",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.bridge_capture_path.read_text(encoding="utf-8"))
        argv = capture["argv"]
        self.assertEqual(argv[0], "package-windows")
        self.assertIn("--server-host", argv)
        self.assertIn("--server-user", argv)
        self.assertIn("--output-dir", argv)
        self.assertIn("--run-store-root", argv)
        self.assertIn("--last-report", argv)
        self.assertEqual(argv[argv.index("--server-host") + 1], "10.55.0.9")
        self.assertEqual(argv[argv.index("--server-user") + 1], "deviceuser")
        self.assertIn("Auto-detected Linux test server address: 10.55.0.9", result.stdout)
        self.assertIn("Auto-detected Linux test server user: deviceuser", result.stdout)
        self.assertIn("Run the ZIP on the Windows PC with the USB-connected device", result.stdout)

    def test_download_menu_selects_sdk_and_tag_then_runs_download(self):
        env = self.env.copy()
        env["OHOS_DOWNLOAD_MENU_FORCE"] = "1"
        env["TEST_SELECTOR_FAKE_TAGS"] = "20260410_120537,20260409_120125"

        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "download",
            ],
            cwd=self.repo_root,
            env=env,
            check=False,
            input_text="\x1b[B\n\x1b[B\n",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.capture_path.read_text(encoding="utf-8"))
        argv = capture["argv"]
        self.assertIn("--download-daily-sdk", argv)
        self.assertIn("--sdk-build-tag", argv)
        self.assertEqual(argv[argv.index("--sdk-build-tag") + 1], "20260409_120125")

    def test_download_menu_escape_cancels_cleanly(self):
        env = self.env.copy()
        env["OHOS_DOWNLOAD_MENU_FORCE"] = "1"

        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "download",
            ],
            cwd=self.repo_root,
            env=env,
            check=False,
            input_text="\x1b",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Download cancelled.", result.stdout + result.stderr)
        self.assertFalse(self.capture_path.exists())

    def test_info_file_positional_mode_routes_to_file_helper(self):
        relative_changed_file = f"./{self.changed_file.relative_to(self.repo_root)}"

        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "info",
                "file",
                relative_changed_file,
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.helper_capture_path.read_text(encoding="utf-8"))
        self.assertEqual(capture["argv"], ["file", relative_changed_file])

    def test_info_existing_file_path_routes_to_file_helper(self):
        relative_changed_file = f"./{self.changed_file.relative_to(self.repo_root)}"

        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "info",
                relative_changed_file,
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.helper_capture_path.read_text(encoding="utf-8"))
        self.assertEqual(capture["argv"], ["file", relative_changed_file])

    def test_xts_select_sigterm_prints_clear_stop_message(self):
        relative_changed_file = f"./{self.changed_file.relative_to(self.repo_root)}"
        env = self.env.copy()
        env["TEST_SELECTOR_SLEEP"] = "30"

        returncode, stdout, stderr = self.run_and_signal(
            [
                "bash",
                str(OHOS_SH),
                "xts",
                "select",
                relative_changed_file,
            ],
            env,
            signal.SIGTERM,
        )

        self.assertEqual(returncode, 143, stderr)
        self.assertIn("Script stopped by SIGTERM.", stdout + stderr)

    def test_device_bridge_sigint_prints_clear_stop_message(self):
        env = self.env.copy()
        env["TEST_BRIDGE_SLEEP"] = "30"

        returncode, stdout, stderr = self.run_and_signal(
            [
                "bash",
                str(OHOS_SH),
                "device",
                "bridge",
                "package-windows",
                "--last-report",
            ],
            env,
            signal.SIGINT,
        )

        self.assertEqual(returncode, 130, stderr)
        self.assertIn("Script stopped by Ctrl+C.", stdout + stderr)


if __name__ == "__main__":
    unittest.main()
