import json
import signal
from pathlib import Path

from test_ohos_xts_wrapper import OHOS_SH, OhosXtsWrapperTests, run_cmd, write_executable


class OhosXtsRemoteWrapperTests(OhosXtsWrapperTests):
    def setUp(self):
        super().setUp()
        self.ssh_capture_path = self.root / "ssh_capture.json"
        write_executable(
            self.fake_bin_dir / "ssh",
            (
                "#!/usr/bin/env python3\n"
                "import json\n"
                "import os\n"
                "import sys\n"
                "from pathlib import Path\n"
                "Path(os.environ['TEST_SSH_CAPTURE']).write_text(json.dumps({'argv': sys.argv[1:]}, indent=2), encoding='utf-8')\n"
            ),
        )
        self.env["TEST_SSH_CAPTURE"] = str(self.ssh_capture_path)

    def test_xts_run_delegates_to_remote_server_host(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "xts",
                "run",
                "--from-report",
                "/tmp/selector_report.json",
                "--server-host",
                "buildmonster1",
                "--server-user",
                "dmazur",
                "--run-priority",
                "required",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.ssh_capture_path.read_text(encoding="utf-8"))
        self.assertEqual(capture["argv"][0], "dmazur@buildmonster1")
        remote_command = capture["argv"][1]
        self.assertIn("OHOS_XTS_REMOTE_EXEC=1", remote_command)
        self.assertIn("bash\\ /data/shared/common/scripts/ohos.sh\\ xts\\ run", remote_command)
        self.assertIn("--from-report\\ /tmp/selector_report.json", remote_command)
        self.assertIn("--server-host\\ buildmonster1", remote_command)
        self.assertIn("--server-user\\ dmazur", remote_command)
        self.assertFalse(self.capture_path.exists())
        self.assertIn("Delegating 'ohos xts run' to remote execution host", result.stdout + result.stderr)

    def test_xts_select_sighup_prints_clear_stop_message(self):
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
            signal.SIGHUP,
        )

        self.assertEqual(returncode, 129, stderr)
        self.assertIn("Script stopped by SIGHUP.", stdout + stderr)
