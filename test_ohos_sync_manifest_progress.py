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


class OhosSyncManifestProgressTests(unittest.TestCase):
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
            self.bin_dir / "npm",
            "#!/bin/bash\nexit 0\n",
        )
        write_executable(
            self.repo_root / "build" / "prebuilts_download.sh",
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

    def test_sync_progress_uses_external_manifest_include_total_when_repo_list_is_one(self):
        external_manifest = self.root / "image_bundle" / "manifest_tag.xml"
        external_manifest.parent.mkdir(parents=True)
        external_manifest.write_text(
            """<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="proj_1" path="proj_1" />
  <project name="proj_2" path="proj_2" />
  <project name="proj_3" path="proj_3" />
  <project name="proj_4" path="proj_4" />
  <project name="proj_5" path="proj_5" />
</manifest>
""",
            encoding="utf-8",
        )
        (self.repo_root / ".repo" / "manifest.xml").write_text(
            f"""<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <include name="{external_manifest}" />
</manifest>
""",
            encoding="utf-8",
        )

        self.write_fake_repo(
            """#!/bin/bash
set -euo pipefail
case "${1:-}" in
  list)
    echo "manifest"
    ;;
  sync)
    if [ "${FAKE_TTY:-0}" = "1" ]; then
      cat <<'EOF'
Fetching projects:  20% (1/5)
Fetching projects:  60% (3/5)
Fetching projects: 100% (5/5), done.
EOF
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
        output = self.combined_output(result).replace("\r", "\n")

        self.assertEqual(result.returncode, 0, output)
        self.assertRegex(output, re.compile(r"repo sync: .*\(5/5\)"))
        self.assertNotIn("(1/1)", output)


if __name__ == "__main__":
    unittest.main()
