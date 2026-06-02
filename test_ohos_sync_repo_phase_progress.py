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


class OhosSyncRepoPhaseProgressTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)

        self.root = Path(self.tempdir.name)
        self.repo_root = self.root / "ohos_manifest"
        self.repo_root.mkdir()
        (self.repo_root / ".repo").mkdir()
        (self.repo_root / "build").mkdir()

        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.home_dir = self.root / "home"
        self.home_dir.mkdir()
        self.shared_prebuilts = self.root / "shared_prebuilts"
        self.shared_prebuilts.mkdir()

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}:{self.env['PATH']}"
        self.env["HOME"] = str(self.home_dir)
        self.env["OHOS_CONF"] = str(self.root / "test-ohos.conf")
        self.env["SHARED_PREBUILTS_DIR"] = str(self.shared_prebuilts)
        self.env["PREBUILTS_SYMLINK_NAME"] = "openharmony_prebuilts"

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
      echo "Fetching projects: 100% (3/3), done."
      sleep 2
      echo "Checking out projects:  33% (1/3) proj_1"
      sleep 2
      echo "Checking out projects: 100% (3/3), done."
    fi
    ;;
  *)
    echo "unexpected repo subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
""",
        )

    def run_sync(self, *args):
        return run_cmd(
            ["bash", str(OHOS_SH), "sync", *args],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

    def test_repo_sync_progress_tracks_fetch_and_checkout_separately(self):
        result = self.run_sync("--repo-only")
        output = (result.stdout + result.stderr).replace("\r", "\n")

        self.assertEqual(result.returncode, 0, output)
        self.assertRegex(output, re.compile(r"repo sync \(fetch\): .*\(3/3\)"))
        self.assertRegex(output, re.compile(r"repo sync \(checkout\): .*\(1/3\)"))
        self.assertRegex(output, re.compile(r"repo sync: .*\(3/3\)"))

    def test_repo_sync_progress_ignores_updating_files_counters_embedded_in_checkout_line(self):
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
      echo "Fetching projects: 100% (3/3), done."
      sleep 2
      printf 'Checking out projects:  33%% (1/3) proj_1Updating files:  65%% (15781/24278)\\n'
      sleep 2
      echo "Checking out projects: 100% (3/3), done."
    fi
    ;;
  *)
    echo "unexpected repo subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
""",
        )

        result = self.run_sync("--repo-only")
        output = (result.stdout + result.stderr).replace("\r", "\n")

        self.assertEqual(result.returncode, 0, output)
        self.assertRegex(output, re.compile(r"repo sync \(checkout\): .*\(1/3\)"))
        self.assertNotRegex(output, re.compile(r"repo sync \(checkout\): .*\(15781/24278\)"))


if __name__ == "__main__":
    unittest.main()
