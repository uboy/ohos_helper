import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


BRIDGE_TOOL = Path("/data/shared/common/scripts/ohos_xts_bridge.py")


def run_cmd(cmd, cwd, check=True):
    return subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        capture_output=True,
        check=check,
    )


class OhosXtsBridgeTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)

    def test_package_windows_bundle_includes_bridge_and_ready_tests(self):
        report_path = self.root / "selector_report.json"
        report_path.write_text(
            json.dumps(
                {
                    "execution_overview": {
                        "selected_target_keys": [
                            "test/xts/acts/arkui/button_static/Test.json"
                        ]
                    },
                    "results": [
                        {
                            "changed_file": "foundation/arkui/ace_engine/frameworks/core/components_ng/pattern/button/button_pattern.cpp",
                            "run_targets": [
                                {
                                    "target_key": "test/xts/acts/arkui/button_static/Test.json",
                                    "test_json": "test/xts/acts/arkui/button_static/Test.json",
                                    "project": "test/xts/acts/arkui/button_static",
                                    "bundle_name": "com.example.button",
                                    "driver_module_name": "entry",
                                    "selected_for_execution": True,
                                }
                            ],
                        }
                    ],
                    "symbol_queries": [],
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        output_zip = self.root / "bundle.zip"

        result = run_cmd(
            [
                "python3",
                str(BRIDGE_TOOL),
                "package-windows",
                "--server-host",
                "tsnnlx12bs01",
                "--server-user",
                "dmazur",
                "--selector-report",
                str(report_path),
                "--output",
                str(output_zip),
            ],
            cwd=self.root,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output_zip.is_file())

        with zipfile.ZipFile(output_zip) as archive:
            names = set(archive.namelist())
            self.assertIn("README.txt", names)
            self.assertIn("bridge-config.json", names)
            self.assertIn("server-endpoint.txt", names)
            self.assertIn("start_hdc_bridge.ps1", names)
            self.assertIn("stop_hdc_bridge.ps1", names)
            self.assertIn("check_local_device.ps1", names)
            self.assertIn("selector_report.json", names)
            self.assertIn("aa_test_targets.json", names)
            self.assertIn("run_selected_aa_tests.ps1", names)

            readme = archive.read("README.txt").decode("utf-8")
            self.assertIn("127.0.0.1:28710", readme)
            self.assertIn("ohos xts run last --hdc-endpoint 127.0.0.1:28710", readme)

            aa_targets = json.loads(archive.read("aa_test_targets.json").decode("utf-8"))
            self.assertEqual(len(aa_targets), 1)
            self.assertEqual(aa_targets[0]["bundle_name"], "com.example.button")
            self.assertTrue(aa_targets[0]["is_static"])


if __name__ == "__main__":
    unittest.main()
