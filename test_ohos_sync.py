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


class OhosSyncTests(unittest.TestCase):
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
        self.sibling_prebuilts = self.root / "openharmony_prebuilts"
        self.repo_state_file = self.root / "repo_state"

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}:{self.env['PATH']}"
        self.env["HOME"] = str(self.home_dir)
        self.env["OHOS_CONF"] = str(self.root / "test-ohos.conf")
        self.env["SHARED_PREBUILTS_DIR"] = str(self.shared_prebuilts)
        self.env["PREBUILTS_SYMLINK_NAME"] = "openharmony_prebuilts"
        self.env["REPO_STATE_FILE"] = str(self.repo_state_file)

        write_executable(
            self.bin_dir / "npm",
            "#!/bin/bash\nexit 0\n",
        )
        write_executable(
            self.repo_root / "build" / "prebuilts_download.sh",
            "#!/bin/bash\nexit 0\n",
        )

    def combined_output(self, result: subprocess.CompletedProcess) -> str:
        return result.stdout + result.stderr

    def run_sync(self, *args):
        return run_cmd(
            ["bash", str(OHOS_SH), "sync", *args],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

    def write_fake_repo(self, script_body: str) -> None:
        write_executable(self.bin_dir / "repo", script_body)

    def init_git_repo(self, repo_path: Path) -> None:
        repo_path.mkdir(parents=True)
        run_cmd(["git", "init"], cwd=repo_path)
        run_cmd(["git", "config", "user.email", "test@example.com"], cwd=repo_path)
        run_cmd(["git", "config", "user.name", "Test User"], cwd=repo_path)
        (repo_path / "tracked.txt").write_text("clean\n", encoding="utf-8")
        (repo_path / ".gitignore").write_text("ignored.tmp\n", encoding="utf-8")
        run_cmd(["git", "add", "tracked.txt", ".gitignore"], cwd=repo_path)
        run_cmd(["git", "commit", "-m", "init"], cwd=repo_path)

    def test_sync_force_backs_up_conflicting_prebuilts_dir(self):
        self.write_fake_repo(
            """#!/bin/bash
set -euo pipefail
case "${1:-}" in
  sync|forall)
    exit 0
    ;;
  *)
    echo "unexpected repo subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
"""
        )

        self.sibling_prebuilts.mkdir()
        (self.sibling_prebuilts / "marker.txt").write_text("old data\n", encoding="utf-8")

        result = self.run_sync("-f")
        output = self.combined_output(result)

        self.assertEqual(result.returncode, 0, output)
        self.assertTrue(self.sibling_prebuilts.is_symlink())
        self.assertEqual(self.sibling_prebuilts.resolve(), self.shared_prebuilts.resolve())

        backups = sorted(self.root.glob("openharmony_prebuilts.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "marker.txt").is_file())
        self.assertIn("Existing path backed up:", output)

    def test_sync_force_recovers_dirty_checkout_failure(self):
        repo_path = self.repo_root / "arkcompiler" / "ets_frontend"
        self.init_git_repo(repo_path)
        (repo_path / "tracked.txt").write_text("dirty\n", encoding="utf-8")
        (repo_path / "junk.txt").write_text("remove me\n", encoding="utf-8")
        (repo_path / "ignored.tmp").write_text("ignored\n", encoding="utf-8")

        self.write_fake_repo(
            """#!/bin/bash
set -euo pipefail
state_file="${REPO_STATE_FILE:?}"
case "${1:-}" in
  sync)
    shift
    if [ ! -f "$state_file" ]; then
      : > "$state_file"
      cat <<'EOF'
Fetching projects: 100% (503/503), done.
Checking out projects:   6% (31/502) arkcompiler_cangjie_ark_interop
error: Your local changes to the following files would be overwritten by checkout:
        ets2panda/linter/package-lock.json
Please commit your changes or stash them before you switch branches.
Aborting
error: arkcompiler/ets_frontend/: arkcompiler_ets_frontend checkout deadbeef
error: Cannot checkout arkcompiler_ets_frontend

error: Unable to fully sync the tree.
error: Checking out local projects failed.
Failing repos:
arkcompiler/ets_frontend
Try re-running with "-j1 --fail-fast" to exit at the first error.
EOF
      exit 1
    fi

    case " $* " in
      *" --fail-fast "* ) ;;
      *)
        echo "retry was expected to use --fail-fast" >&2
        exit 3
        ;;
    esac
    case " $* " in
      *" arkcompiler/ets_frontend "* ) ;;
      *)
        echo "retry was expected to target arkcompiler/ets_frontend" >&2
        exit 4
        ;;
    esac
    if [ -n "$(git -C "$PWD/arkcompiler/ets_frontend" status --porcelain --ignored)" ]; then
      echo "repo still dirty after force cleanup" >&2
      exit 5
    fi
    exit 0
    ;;
  forall)
    exit 0
    ;;
  *)
    echo "unexpected repo subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
"""
        )

        result = self.run_sync("-f")
        output = self.combined_output(result)

        self.assertEqual(result.returncode, 0, output)
        self.assertEqual((repo_path / "tracked.txt").read_text(encoding="utf-8"), "clean\n")
        self.assertFalse((repo_path / "junk.txt").exists())
        self.assertFalse((repo_path / "ignored.tmp").exists())
        self.assertIn("Force-cleaning repo worktree: arkcompiler/ets_frontend", output)
        self.assertIn("repo sync recovery succeeded for the failing repos.", output)

    def test_sync_reports_prebuilts_stage_failure(self):
        self.write_fake_repo(
            """#!/bin/bash
set -euo pipefail
case "${1:-}" in
  sync|forall)
    exit 0
    ;;
  *)
    echo "unexpected repo subcommand: ${1:-}" >&2
    exit 2
    ;;
esac
"""
        )
        write_executable(
            self.repo_root / "build" / "prebuilts_download.sh",
            "#!/bin/bash\necho prebuilts failed >&2\nexit 7\n",
        )

        result = self.run_sync()
        output = self.combined_output(result)

        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("Stage failed: [3/3] prebuilts_download.sh", output)
        self.assertIn("Stage log: /tmp/ohos_prebuilts_", output)
        self.assertIn("prebuilts failed", output)


if __name__ == "__main__":
    unittest.main()
