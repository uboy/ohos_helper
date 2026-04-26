import os
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


class OhosChainFailFastTests(unittest.TestCase):
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

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}:{self.env['PATH']}"
        self.env["HOME"] = str(self.home_dir)
        self.env["OHOS_CONF"] = str(self.root / "test-ohos.conf")
        self.env["SHARED_PREBUILTS_DIR"] = str(self.shared_prebuilts)
        self.env["PREBUILTS_SYMLINK_NAME"] = "openharmony_prebuilts"
        self.env["CHAIN_SYNC_MARKER"] = str(self.root / "sync-called")
        self.env["CHAIN_BUILD_MARKER"] = str(self.root / "build-called")

        write_executable(self.bin_dir / "npm", "#!/bin/bash\nexit 0\n")
        write_executable(
            self.repo_root / "build" / "prebuilts_download.sh",
            "#!/bin/bash\nexit 0\n",
        )
        write_executable(
            self.repo_root / "build.sh",
            """#!/bin/bash
set -euo pipefail
printf 'build\\n' > "${CHAIN_BUILD_MARKER:?}"
exit 0
""",
        )

    def combined_output(self, result: subprocess.CompletedProcess) -> str:
        return result.stdout + result.stderr

    def run_in_repo(self, *args):
        return run_cmd(
            ["bash", str(OHOS_SH), *args],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

    def run_in_fresh_dir(self, cwd: Path, *args):
        return run_cmd(
            ["bash", str(OHOS_SH), *args],
            cwd=cwd,
            env=self.env,
            check=False,
        )

    def test_failed_sync_aborts_chain_before_build(self):
        write_executable(
            self.bin_dir / "repo",
            """#!/bin/bash
set -euo pipefail
case "${1:-}" in
  list)
    echo "proj_1"
    ;;
  sync)
    printf 'sync\\n' > "${CHAIN_SYNC_MARKER:?}"
    echo "repo sync failed intentionally" >&2
    exit 9
    ;;
  *)
    echo "unexpected repo subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
""",
        )

        result = self.run_in_repo("sync", "--repo-only", "build", "rk3568")
        output = self.combined_output(result)

        self.assertEqual(result.returncode, 9, output)
        self.assertTrue(Path(self.env["CHAIN_SYNC_MARKER"]).exists())
        self.assertFalse(Path(self.env["CHAIN_BUILD_MARKER"]).exists())
        self.assertIn("Aborting command chain after failed step: sync", output)
        self.assertNotIn("Building: ./build.sh", output)

    def test_failed_init_aborts_chain_before_sync(self):
        fresh_root = self.root / "fresh"
        fresh_root.mkdir()
        (fresh_root / "build").mkdir()
        write_executable(
            fresh_root / "build" / "prebuilts_download.sh",
            "#!/bin/bash\nexit 0\n",
        )
        write_executable(
            fresh_root / "build.sh",
            """#!/bin/bash
set -euo pipefail
printf 'build\\n' > "${CHAIN_BUILD_MARKER:?}"
exit 0
""",
        )
        write_executable(
            self.bin_dir / "repo",
            """#!/bin/bash
set -euo pipefail
case "${1:-}" in
  init)
    echo "repo init failed intentionally" >&2
    exit 7
    ;;
  sync)
    printf 'sync\\n' > "${CHAIN_SYNC_MARKER:?}"
    exit 0
    ;;
  *)
    echo "unexpected repo subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
""",
        )

        result = self.run_in_fresh_dir(
            fresh_root,
            "init",
            "--branch",
            "master",
            "sync",
            "--repo-only",
            "build",
            "rk3568",
        )
        output = self.combined_output(result)

        self.assertEqual(result.returncode, 7, output)
        self.assertFalse(Path(self.env["CHAIN_SYNC_MARKER"]).exists())
        self.assertFalse(Path(self.env["CHAIN_BUILD_MARKER"]).exists())
        self.assertIn("Aborting command chain after failed step: init", output)
        self.assertNotIn("Building: ./build.sh", output)


if __name__ == "__main__":
    unittest.main()
