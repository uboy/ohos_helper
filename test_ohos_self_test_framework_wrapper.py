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


class OhosSelfTestFrameworkWrapperTests(unittest.TestCase):
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

        self.developer_test_capture_path = self.root / "developer_test_capture.json"
        self.framework_root = self.root / "developer_test"
        self.framework_runner = self.framework_root / "start.sh"
        write_executable(
            self.framework_runner,
            (
                "#!/usr/bin/env python3\n"
                "import json\n"
                "import os\n"
                "import sys\n"
                "from pathlib import Path\n"
                "capture_path = Path(os.environ['TEST_DEVELOPER_TEST_CAPTURE'])\n"
                "capture_path.write_text(json.dumps({'argv': sys.argv[1:]}, indent=2), encoding='utf-8')\n"
                "summary_path = Path(os.environ.get('TEST_DEVELOPER_TEST_SUMMARY', Path(__file__).resolve().parent / 'reports/latest/summary_report.xml'))\n"
                "summary_path.parent.mkdir(parents=True, exist_ok=True)\n"
                "summary_path.write_text('<testsuites name=\"summary_report\" tests=\"5\" failures=\"1\" errors=\"0\" skipped=\"1\"></testsuites>', encoding='utf-8')\n"
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
                        "subsystem": "arkui",
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
        ace_bundle_config = self.ace_root / "test" / "unittest" / "js" / "config.json"
        ace_bundle_config.parent.mkdir(parents=True)
        ace_bundle_config.write_text(
            json.dumps(
                {
                    "app": {"bundleName": "com.example.ace.unittest"},
                    "module": {"distro": {"moduleName": "entry"}},
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
                        "subsystem": "sample",
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
        self.env["HOME"] = str(self.root)
        self.env["OHOS_CONF"] = str(self.conf_path)
        self.env["OHOS_DEVELOPER_TEST_RUNNER"] = str(self.framework_runner)
        self.env["TEST_DEVELOPER_TEST_CAPTURE"] = str(self.developer_test_capture_path)
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"

    def test_help_test_documents_developer_test_mode(self):
        result = run_cmd(
            ["bash", str(OHOS_SH), "help", "test"],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--framework auto|bundle|developer_test", result.stdout)
        self.assertIn("start.sh run -t UT", result.stdout)
        self.assertIn("--framework developer_test --all", result.stdout)

    def test_test_self_test_auto_falls_back_to_developer_test_for_gn_only_component(self):
        result = run_cmd(
            ["bash", str(OHOS_SH), "test", "self-test", "gn_only", "--dry-run"],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.framework_runner), result.stdout)
        self.assertIn("run -p phone -t UT -ss sample -tp gn_only -tm sample_unittest", result.stdout)
        self.assertIn("Expected summary XML", result.stdout)

    def test_test_self_test_framework_all_dry_run_uses_run_t_ut_without_part(self):
        result = run_cmd(
            ["bash", str(OHOS_SH), "test", "self-test", "--framework", "developer_test", "--all", "--dry-run"],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("run -p phone -t UT", result.stdout)
        self.assertNotIn(" -tp ", result.stdout)

    def test_test_self_test_framework_dry_run_supports_suite_case_coverage_and_repeat(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "test",
                "self-test",
                "ace_engine",
                "--framework",
                "developer_test",
                "--module",
                "unittest",
                "--suite",
                "SmokeSuite",
                "--case",
                "SmokeSuite.case1",
                "--coverage",
                "--repeat",
                "3",
                "--dry-run",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("run -p phone -t UT -ss arkui -tp ace_engine -tm unittest -ts SmokeSuite -tc SmokeSuite.case1 -cov --repeat 3", result.stdout)

    def test_test_self_test_framework_execution_prints_summary(self):
        result = run_cmd(
            ["bash", str(OHOS_SH), "test", "self-test", "gn_only", "--framework", "developer_test"],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.developer_test_capture_path.read_text(encoding="utf-8"))
        self.assertEqual(
            capture["argv"],
            ["run", "-p", "phone", "-t", "UT", "-ss", "sample", "-tp", "gn_only", "-tm", "sample_unittest"],
        )
        self.assertIn("Framework Summary", result.stdout)
        self.assertIn("tests=5", result.stdout)
        self.assertIn("failures=1", result.stdout)
        self.assertIn("summary_report.xml", result.stdout)

    def test_test_self_test_rejects_non_numeric_repeat(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "test",
                "self-test",
                "ace_engine",
                "--framework",
                "developer_test",
                "--repeat",
                "abc",
                "--dry-run",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--repeat expects a non-negative integer", result.stderr)

    def test_test_self_test_rejects_bundle_flag_in_developer_test_mode(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "test",
                "self-test",
                "--framework",
                "developer_test",
                "--bundle",
                "com.example.manual",
                "--dry-run",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--bundle is only valid with bundle mode", result.stderr)


if __name__ == "__main__":
    unittest.main()
