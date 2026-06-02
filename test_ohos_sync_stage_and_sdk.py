import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
OHOS_SH = SCRIPT_DIR / "ohos.sh"


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


class OhosSyncStageAndSdkTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)

        self.root = Path(self.tempdir.name)
        self.repo_root = self.root / "ohos_master"
        self.repo_root.mkdir()
        (self.repo_root / ".repo").mkdir()
        (self.repo_root / "build").mkdir()

        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.home_dir = self.root / "home"
        self.home_dir.mkdir()
        self.shared_prebuilts = self.root / "shared_prebuilts"
        self.shared_prebuilts.mkdir()
        self.prebuilts_args_file = self.root / "prebuilts_args.txt"

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}:{self.env['PATH']}"
        self.env["HOME"] = str(self.home_dir)
        self.env["OHOS_CONF"] = str(self.root / "test-ohos.conf")
        self.env["SHARED_PREBUILTS_DIR"] = str(self.shared_prebuilts)
        self.env["PREBUILTS_SYMLINK_NAME"] = "openharmony_prebuilts"
        self.env["PREBUILTS_ARGS_FILE"] = str(self.prebuilts_args_file)

        write_executable(
            self.bin_dir / "npm",
            "#!/bin/bash\nexit 0\n",
        )
        write_executable(
            self.bin_dir / "script",
            """#!/bin/bash
set -euo pipefail
cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    -qefc)
      shift
      cmd="${1:-}"
      shift || true
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$cmd" ] || exit 2
FAKE_TTY=1 bash -lc "$cmd"
""",
        )
        write_executable(
            self.repo_root / "build" / "prebuilts_download.sh",
            """#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" > "${PREBUILTS_ARGS_FILE:?}"
exit 0
""",
        )

    def run_sync(self, *args):
        return run_cmd(
            ["bash", str(OHOS_SH), "sync", *args],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

    def run_help_sync(self):
        return run_cmd(
            ["bash", str(OHOS_SH), "help", "sync"],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

    def write_fake_repo(self) -> None:
        write_executable(
            self.bin_dir / "repo",
            """#!/bin/bash
set -euo pipefail
case "${1:-}" in
  list)
    for i in $(seq 1 3); do
      echo "proj_$i"
    done
    ;;
  sync)
    if [ "${FAKE_TTY:-0}" = "1" ]; then
      cat <<'EOF'
Fetching projects:  33% (1/3)
Fetching projects: 100% (3/3), done.
EOF
    fi
    ;;
  forall)
    if [ "${FAKE_TTY:-0}" = "1" ]; then
      for i in $(seq 1 3); do
        echo "project path/proj_$i"
      done
    fi
    ;;
  *)
    echo "unexpected repo subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
""",
        )

    def test_sync_prints_stage_completion_and_passes_download_sdk_to_prebuilts(self):
        self.write_fake_repo()

        result = self.run_sync("--download-sdk")
        output = (result.stdout + result.stderr).replace("\r", "\n")
        prebuilts_args = self.prebuilts_args_file.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, output)
        self.assertIn("Stage completed: [1/3] repo sync", output)
        self.assertIn("======== [2/3] git lfs fetch + checkout", output)
        self.assertIn("Stage completed: [2/3] git lfs fetch + checkout", output)
        self.assertIn("======== [3/3] prebuilts_download.sh", output)
        self.assertIn("Stage completed: [3/3] prebuilts_download.sh", output)
        self.assertIn("--download-sdk", prebuilts_args)
        self.assertRegex(output, re.compile(r"repo sync: .*\(3/3\)"))
        self.assertRegex(output, re.compile(r"git lfs: .*\(3/3\)"))

    def test_help_sync_mentions_download_sdk_and_stage_visibility(self):
        self.write_fake_repo()

        result = self.run_help_sync()
        output = result.stdout + result.stderr

        self.assertEqual(result.returncode, 0, output)
        self.assertIn("--download-sdk", output)
        self.assertIn("repo-local OHOS SDK prebuilts", output)
        self.assertIn("prints an explicit completion line", output)


if __name__ == "__main__":
    unittest.main()
