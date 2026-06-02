import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
SOURCE_OHOS_SH = SCRIPT_DIR / "ohos.sh"


def run_cmd(cmd, cwd, env=None, check=True):
    return subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=check,
    )


class OhosAdminRelocateTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)

        self.legacy_root = self.root / "scripts"
        self.target_root = self.root / "projects" / "ohos-helper"
        self.legacy_root.mkdir(parents=True)
        self.ohos_sh = self.legacy_root / "ohos.sh"
        shutil.copy2(SOURCE_OHOS_SH, self.ohos_sh)
        self.ohos_sh.chmod(0o755)
        (self.legacy_root / "marker.txt").write_text("workspace marker\n", encoding="utf-8")

    def test_admin_relocate_dry_run_does_not_mutate_filesystem(self):
        result = run_cmd(
            [
                "bash",
                str(self.ohos_sh),
                "admin",
                "relocate",
                "--target-root",
                str(self.target_root),
                "--legacy-link",
                str(self.legacy_root),
                "--dry-run",
            ],
            cwd=self.root,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.legacy_root.is_dir())
        self.assertFalse(self.legacy_root.is_symlink())
        self.assertFalse(self.target_root.exists())
        self.assertIn("Dry-run completed", result.stdout + result.stderr)

    def test_admin_relocate_moves_root_and_creates_symlink(self):
        result = run_cmd(
            [
                "bash",
                str(self.ohos_sh),
                "admin",
                "relocate",
                "--target-root",
                str(self.target_root),
                "--legacy-link",
                str(self.legacy_root),
                "--yes",
            ],
            cwd=self.root,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.target_root.is_dir())
        self.assertTrue((self.target_root / "ohos.sh").is_file())
        self.assertTrue((self.target_root / "marker.txt").is_file())
        self.assertTrue(self.legacy_root.is_symlink())
        self.assertEqual(self.legacy_root.resolve(), self.target_root.resolve())
        self.assertIn("Relocation completed.", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
