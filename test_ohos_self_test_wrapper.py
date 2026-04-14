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
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


class OhosSelfTestWrapperTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)

        self.root = Path(self.tempdir.name)
        self.repo_root = self.root / "ohos_master"
        self.repo_root.mkdir()
        (self.repo_root / ".repo").mkdir()
        (self.repo_root / "build").mkdir()
        write_executable(
            self.repo_root / "build" / "prebuilts_download.sh",
            "#!/bin/bash\nexit 0\n",
        )

        self.conf_path = self.root / "test-ohos.conf"
        self.conf_path.write_text("", encoding="utf-8")

        self.hdc_capture_path = self.root / "hdc_capture.json"
        self.fake_bin_dir = self.root / "fake-bin"
        self.fake_bin_dir.mkdir()
        write_executable(
            self.fake_bin_dir / "hdc",
            (
                "#!/usr/bin/env python3\n"
                "import json\n"
                "import os\n"
                "import sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "if args == ['-h']:\n"
                "    sys.exit(0)\n"
                "capture_path = os.environ.get('TEST_HDC_CAPTURE')\n"
                "if capture_path:\n"
                "    Path(capture_path).write_text(json.dumps({'argv': args}, indent=2), encoding='utf-8')\n"
                "sys.exit(0)\n"
            ),
        )

        self.ace_root = self.repo_root / "foundation" / "arkui" / "ace_engine"
        self.ace_root.mkdir(parents=True)
        (self.ace_root / "bundle.json").write_text(
            json.dumps(
                {
                    "name": "@ohos/ace_engine",
                    "component": {
                        "name": "ace_engine",
                        "build": {
                            "test": [
                                "//foundation/arkui/ace_engine/test/unittest:unittest",
                                "//foundation/arkui/ace_engine/test/benchmark:benchmark",
                            ]
                        },
                    },
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        bundle_config_path = self.ace_root / "test" / "unittest" / "js" / "config.json"
        bundle_config_path.parent.mkdir(parents=True)
        bundle_config_path.write_text(
            json.dumps(
                {
                    "app": {
                        "bundleName": "com.example.ace.unittest",
                    },
                    "module": {
                        "distro": {
                            "moduleName": "entry",
                        }
                    },
                },
                indent=2,
            ),
            encoding="utf-8",
        )

        self.gn_only_root = self.repo_root / "base" / "sample" / "gn_only"
        self.gn_only_root.mkdir(parents=True)
        (self.gn_only_root / "bundle.json").write_text(
            json.dumps(
                {
                    "component": {
                        "name": "gn_only",
                        "build": {
                            "test": [
                                "//base/sample/gn_only/test/unittest:sample_unittest",
                            ]
                        },
                    }
                },
                indent=2,
            ),
            encoding="utf-8",
        )

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.fake_bin_dir}:{self.env['PATH']}"
        self.env["HOME"] = str(self.root)
        self.env["OHOS_CONF"] = str(self.conf_path)
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.env["TEST_HDC_CAPTURE"] = str(self.hdc_capture_path)

    def test_help_test_documents_discover_and_self_test(self):
        result = run_cmd(
            ["bash", str(OHOS_SH), "help", "test"],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ohos test discover <component|path>", result.stdout)
        self.assertIn("ohos test discover --all", result.stdout)
        self.assertIn("ohos test self-test <component|path>", result.stdout)
        self.assertIn("hdc shell aa test -b <bundle> -m <module>", result.stdout)

    def test_test_discover_component_name_prints_declared_targets_and_bundle_candidate(self):
        result = run_cmd(
            ["bash", str(OHOS_SH), "test", "discover", "ace_engine"],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Component: ace_engine", result.stdout)
        self.assertIn("//foundation/arkui/ace_engine/test/unittest:unittest", result.stdout)
        self.assertIn("//foundation/arkui/ace_engine/test/benchmark:benchmark", result.stdout)
        self.assertIn("com.example.ace.unittest / entry", result.stdout)

    def test_test_discover_all_lists_components_with_counts(self):
        result = run_cmd(
            ["bash", str(OHOS_SH), "test", "discover", "--all"],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Discovered 2 components with declared self-tests:", result.stdout)
        self.assertIn("ace_engine", result.stdout)
        self.assertIn("gn_only", result.stdout)
        self.assertIn("bundle_backed=1", result.stdout)
        self.assertIn("bundle_backed=0", result.stdout)

    def test_test_self_test_explicit_bundle_dry_run_prints_exact_command(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "test",
                "self-test",
                "--bundle",
                "com.example.manual",
                "--module",
                "entry",
                "--dry-run",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Self-test command:", result.stdout)
        self.assertIn("hdc shell aa test -b com.example.manual -m entry -s unittest OpenHarmonyTestRunner", result.stdout)

    def test_test_self_test_component_auto_discovers_bundle_backed_candidate(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "test",
                "self-test",
                "ace_engine",
                "--dry-run",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Auto-discovered bundle-backed self-test metadata", result.stdout)
        self.assertIn("com.example.ace.unittest", result.stdout)
        self.assertIn("hdc shell aa test -b com.example.ace.unittest -m entry -s unittest OpenHarmonyTestRunner", result.stdout)

    def test_test_self_test_gn_only_component_fails_honestly(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "test",
                "self-test",
                "gn_only",
                "--dry-run",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not expose bundle-backed self-test metadata", result.stderr)
        self.assertIn("Run `ohos test discover <component>`", result.stderr)

    def test_test_self_test_executes_hdc_with_device_and_bundle(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "test",
                "self-test",
                "--bundle",
                "com.example.manual",
                "--module",
                "entry",
                "--device",
                "SER123",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.hdc_capture_path.read_text(encoding="utf-8"))
        self.assertEqual(
            capture["argv"],
            [
                "-t",
                "SER123",
                "shell",
                "aa",
                "test",
                "-b",
                "com.example.manual",
                "-m",
                "entry",
                "-s",
                "unittest",
                "OpenHarmonyTestRunner",
            ],
        )


if __name__ == "__main__":
    unittest.main()
