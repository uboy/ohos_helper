import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


OHOS_SH = Path("/data/shared/common/scripts/ohos.sh")


def run_cmd(cmd, cwd, env=None, check=True):
    return subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
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

        self.capture_path = self.root / "selector_capture.json"
        (package_dir / "__main__.py").write_text(
            (
                "import json\n"
                "import os\n"
                "import sys\n"
                "from pathlib import Path\n"
                "capture_path = Path(os.environ['TEST_SELECTOR_CAPTURE'])\n"
                "capture_path.write_text(json.dumps({\n"
                "  'argv': sys.argv[1:],\n"
                "  'env': {\n"
                "    'ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH': os.environ.get('ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH', ''),\n"
                "    'LD_LIBRARY_PATH': os.environ.get('LD_LIBRARY_PATH', ''),\n"
                "  },\n"
                "}, indent=2), encoding='utf-8')\n"
            ),
            encoding="utf-8",
        )

        self.hdc_lib_dir = self.root / "toolchains"
        self.hdc_lib_dir.mkdir()
        (self.hdc_lib_dir / "libusb_shared.so").write_text("", encoding="utf-8")

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
                    f'FLASH_PY_PATH="{self.root / "flash.py"}"',
                    f'HDC_PATH="{self.broken_hdc}"',
                    'HDC_LIBRARY_PATH=""',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        write_executable(self.root / "flash.py", "#!/usr/bin/env python3\n")

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.hdc_lib_dir}:{self.env['PATH']}"
        self.env["HOME"] = str(self.root)
        self.env["OHOS_CONF"] = str(self.conf_path)
        self.env["ARKUI_XTS_SELECTOR_DIR"] = str(self.selector_dir)
        self.env["TEST_SELECTOR_CAPTURE"] = str(self.capture_path)
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"

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
        self.assertIn("--hdc-path", argv)
        hdc_index = argv.index("--hdc-path")
        self.assertEqual(argv[hdc_index + 1], str(self.working_hdc))
        self.assertEqual(capture["env"]["ARKUI_XTS_SELECTOR_HDC_LIBRARY_PATH"], str(self.hdc_lib_dir))
        self.assertTrue(capture["env"]["LD_LIBRARY_PATH"].startswith(str(self.hdc_lib_dir)))


if __name__ == "__main__":
    unittest.main()
