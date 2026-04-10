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


class OhosPrWrapperTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)

        self.root = Path(self.tempdir.name)
        self.repo_root = self.root / "workspace"
        self.repo_root.mkdir()

        self.fake_gitee_dir = self.root / "gitee_util"
        (self.fake_gitee_dir / ".git").mkdir(parents=True)
        self.fake_pydeps = self.root / "pydeps"
        self.fake_pydeps.mkdir()
        for module_name in ("requests.py", "tqdm.py", "prompt_toolkit.py", "bs4.py"):
            (self.fake_pydeps / module_name).write_text("", encoding="utf-8")
        (self.fake_pydeps / "dateutil.py").write_text("", encoding="utf-8")

        self.fake_runner = self.root / "gitee-util-runner.py"
        write_executable(
            self.fake_runner,
            (
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "args = sys.argv[1:]\n"
                "if args and args[0] == '--provider':\n"
                "  args = args[2:]\n"
                "if args and args[0] == 'show-comments':\n"
                "  print('\\n💬 Comments for PR #123 in owner/repo:\\n')\n"
                "  print('--- alice @ 2026-04-10T12:00:00Z ---')\n"
                "  print('First line')\n"
                "  print('')\n"
                "  print('')\n"
                "  print('Second paragraph')\n"
                "  print('')\n"
                "  print('--- bob @ 2026-04-10T13:30:00Z ---')\n"
                "  print('Reply body')\n"
                "  sys.exit(0)\n"
                "if args and args[0] == 'show-pr':\n"
                "  print('PR #83368')\n"
                "  print('Title: Improve chipgroup behavior')\n"
                "  print('Changed Files: 1')\n"
                "  sys.exit(0)\n"
                "print('unexpected command', args)\n"
            ),
        )

        self.env = os.environ.copy()
        self.env["HOME"] = str(self.root)
        self.env["GITEE_UTIL_DIR"] = str(self.fake_gitee_dir)
        self.env["GITEE_UTIL_RUNNER"] = str(self.fake_runner)
        self.env["OHOS_PR_NO_PAGER"] = "1"
        self.env["PYTHONPATH"] = str(self.fake_pydeps)

    def test_pr_show_comments_uses_compact_viewer_format(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "pr",
                "show-comments",
                "--repo",
                "owner/repo",
                "--pr-id",
                "123",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Comments for PR #123 in owner/repo:", result.stdout)
        self.assertIn("[1] alice", result.stdout)
        self.assertIn("created: 2026-04-10T12:00:00Z", result.stdout)
        self.assertIn("[2] bob", result.stdout)
        self.assertIn("Second paragraph", result.stdout)
        self.assertNotIn("--- alice @ 2026-04-10T12:00:00Z ---", result.stdout)
        self.assertNotIn("\n\n\n", result.stdout)

    def test_help_pr_mentions_compact_viewer_and_pager(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "help",
                "pr",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("show-pr prints one readable PR card", result.stdout)
        self.assertIn("show-comments is reformatted into a compact viewer.", result.stdout)
        self.assertIn("quit with q", result.stdout)
        self.assertNotIn("The vendored tool repo lives at:", result.stdout)
        self.assertNotIn("To update that tool later:", result.stdout)

    def test_pr_show_pr_routes_to_runner(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "pr",
                "show-pr",
                "--url",
                "https://gitcode.com/openharmony/arkui_ace_engine/pull/83368",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PR #83368", result.stdout)
        self.assertIn("Title: Improve chipgroup behavior", result.stdout)

    def test_pr_show_pr_accepts_positional_url(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "pr",
                "show-pr",
                "https://gitcode.com/openharmony/arkui_ace_engine/pull/83368",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PR #83368", result.stdout)

    def test_pr_show_comments_accepts_positional_url(self):
        result = run_cmd(
            [
                "bash",
                str(OHOS_SH),
                "pr",
                "show-comments",
                "https://gitcode.com/openharmony/arkui_ace_engine/pull/83368",
            ],
            cwd=self.repo_root,
            env=self.env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Comments for PR #123 in owner/repo:", result.stdout)


if __name__ == "__main__":
    unittest.main()
