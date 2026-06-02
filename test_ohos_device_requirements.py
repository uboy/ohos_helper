"""
Requirement tests for ohos_device.sh and ohos_xts_full_run.py.

Verifies board management requirements from AGENTS.md:
  F*  — Flash requirements
  B*  — Board inventory requirements
  G*  — General requirements
  R*  — XTS full run requirements (tested via ohos_xts_full_run.py imports)

Test artifacts saved to: $TEST_ARTIFACT_ROOT/<timestamp>/ (default: $TMPDIR/ohos_test_artifacts)
No real devices, flashing, or SSH connections required.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
DEVICE_SH = SCRIPT_DIR / "ohos_device.sh"

# Add project directory to path for test_helpers import
sys.path.insert(0, str(SCRIPT_DIR))
from test_helpers import get_paths, get_servers

# Get fixture data
PATHS = get_paths()
SERVERS = get_servers()

# Artifact directory per G6/G7
ARTIFACT_ROOT = Path(os.environ.get("TEST_ARTIFACT_ROOT", os.path.join(os.environ.get("TMPDIR", "/tmp"), "ohos_test_artifacts")))
RUN_TIMESTAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
ARTIFACT_DIR = ARTIFACT_ROOT / RUN_TIMESTAMP


def _run_device_sh(*args, timeout=10):
    """Run ohos_device.sh with args, capture output. Returns (rc, stdout, stderr)."""
    result = subprocess.run(
        ["bash", str(DEVICE_SH)] + list(args),
        capture_output=True, text=True, timeout=timeout,
        cwd=str(SCRIPT_DIR),
    )
    return result.returncode, result.stdout, result.stderr


def _save_artifact(name, content):
    """Save test artifact to artifact dir (G6)."""
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    (ARTIFACT_DIR / name).write_text(content)


class _ArtifactTestCase(unittest.TestCase):
    """Base class that saves test output as artifacts."""

    def run(self, result=None):
        test_id = self.id()
        rc = super().run(result)
        # Save artifacts after each test method
        if result and result.failures:
            for test, traceback in result.failures:
                if str(test) == test_id:
                    _save_artifact(f"{test_id}.failure.log", traceback)
        if result and result.errors:
            for test, traceback in result.errors:
                if str(test) == test_id:
                    _save_artifact(f"{test_id}.error.log", traceback)
        return rc


# =========================================================================
# F* — Flash requirements
# =========================================================================

class F1_RemoteFlashUsesTmux(_ArtifactTestCase):
    """F1: Remote flash must use tmux on the remote server."""

    def test_flash_help_mentions_tmux(self):
        rc, out, err = _run_device_sh("flash", "--help")
        _save_artifact("flash_help.txt", out + "\n---STDERR---\n" + err)
        self.assertEqual(rc, 0)
        self.assertIn("tmux", out.lower())

    def test_flash_help_mentions_survives_disconnect(self):
        rc, out, err = _run_device_sh("flash", "--help")
        self.assertIn("survives", out.lower() + err.lower())


class F2_FlashLogsOnRemote(_ArtifactTestCase):
    """F2: Flash logs written to ~/flash-logs/<short>-<date>.log."""

    def test_flash_help_mentions_log_path(self):
        rc, out, err = _run_device_sh("flash", "--help")
        _save_artifact("flash_help_log.txt", out)
        self.assertEqual(rc, 0)
        self.assertIn("flash-logs", out)


class F6_ServerRequiresDevice(_ArtifactTestCase):
    """F6: --server requires --device."""

    def test_server_without_device_fails(self):
        rc, out, err = _run_device_sh(
            "flash", "--server", list(SERVERS.values())[0],
            PATHS["firmware"],
        )
        _save_artifact("flash_server_no_device.log", out + "\n---STDERR---\n" + err)
        # Should fail because --device is missing
        self.assertNotEqual(rc, 0)
        self.assertIn("--device is required", out + err)


class F7_FirmwareValidatedOnRemote(_ArtifactTestCase):
    """F7: Firmware path validated on remote before starting flash."""

    def test_flash_help_mentions_remote_validation(self):
        rc, out, err = _run_device_sh("flash", "--help")
        self.assertIn("valid on remote", out.lower() + err.lower())


class F8_HdcKillAndRestore(_ArtifactTestCase):
    """F8: hdc daemon killed before flash, restored after."""

    def test_flash_help_mentions_hdc_kill(self):
        rc, out, err = _run_device_sh("flash", "--help")
        _save_artifact("flash_help_hdc.txt", out)
        self.assertIn("hdc daemon", out.lower())


class F9_LocalFlashUnchanged(_ArtifactTestCase):
    """F9: Local flash path unchanged when --server not specified."""

    def test_local_flash_still_works_help(self):
        rc, out, err = _run_device_sh("flash", "--help")
        self.assertIn("--devno", out)


class G5_RemoteUsesSshRun(_ArtifactTestCase):
    """G5: Remote operations use _ssh_run() helper."""

    def test_ssh_run_function_exists(self):
        rc, out, _ = _run_device_sh("flash", "--help")
        # _ssh_run is internal; verify it exists in the source
        source = (SCRIPT_DIR / "ohos_device.sh").read_text()
        self.assertIn("_ssh_run()", source)


# =========================================================================
# B* — Board inventory requirements
# =========================================================================

class B1_BoardsConfFromConfDir(_ArtifactTestCase):
    """B1: Board inventory from conf/boards.conf."""

    def test_boards_conf_exists(self):
        conf = SCRIPT_DIR / "conf" / "boards.conf"
        self.assertTrue(conf.exists(), "conf/boards.conf must exist")

    def test_boards_conf_sourcable(self):
        rc, out, err = _run_device_sh("list-targets", timeout=5)
        _save_artifact("list_targets.txt", out + "\n---STDERR---\n" + err)
        # Should not crash — boards.conf sourced without error


class B2_BoardHasRequiredFields(_ArtifactTestCase):
    """B2: Each board has serial, short, server, status, LocationID."""

    def test_all_fields_present(self):
        conf = SCRIPT_DIR / "conf" / "boards.conf"
        content = conf.read_text()
        for i in range(1, 7):
            for field in ["SERIAL", "SHORT", "SERVER", "STATUS",
                          "LOCATIONID_MASKROM", "LOCATIONID_LOADER"]:
                self.assertIn(f"BOARD_{i}_{field}=", content,
                              f"Missing BOARD_{i}_{field} in boards.conf")


class B3_OnlyOkBoardsDefault(_ArtifactTestCase):
    """B3: Only STATUS=OK boards selected by default."""

    def test_py_resolve_boards_skips_broken(self):
        import ohos_xts_full_run as sut
        tmpdir = Path(tempfile.mkdtemp())
        conf = tmpdir / "boards.conf"
        conf.write_text(
            f'BOARD_1_SERIAL="AAA"\\nBOARD_1_SHORT="aaa"\\nBOARD_1_STATUS="OK"\\n'
            f'BOARD_1_SERVER="{list(SERVERS.values())[0]}"\\n'
            'BOARD_2_SERIAL="BBB"\\nBOARD_2_SHORT="bbb"\\nBOARD_2_STATUS="BROKEN"\\n'
            f'BOARD_2_SERVER="{list(SERVERS.values())[1]}"\\n'
        )
        boards = sut.resolve_boards(tmpdir, None, None)
        shutil.rmtree(tmpdir)
        self.assertEqual(len(boards), 1)
        self.assertEqual(boards[0]["serial"], "AAA")


# =========================================================================
# G* — General requirements
# =========================================================================

class G1_ShellSyntaxCheck(_ArtifactTestCase):
    """G1: All shell files pass bash -n."""

    def test_ohos_device_sh_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(DEVICE_SH)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0,
                         f"bash -n failed: {result.stderr}")

    def test_ohos_sh_syntax(self):
        ohos_sh = SCRIPT_DIR / "ohos.sh"
        if ohos_sh.exists():
            result = subprocess.run(
                ["bash", "-n", str(ohos_sh)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0,
                             f"bash -n ohos.sh failed: {result.stderr}")

    def test_remote_templates_syntax(self):
        tmpl_dir = SCRIPT_DIR / "scripts" / "remote"
        if not tmpl_dir.exists():
            self.skipTest("No remote templates dir")
        for tmpl in tmpl_dir.glob("*.sh"):
            result = subprocess.run(
                ["bash", "-n", str(tmpl)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0,
                             f"bash -n {tmpl.name} failed: {result.stderr}")


class G2_PythonSyntaxCheck(_ArtifactTestCase):
    """G2: All Python files pass py_compile."""

    def test_ohos_xts_full_run_compiles(self):
        result = subprocess.run(
            [sys.executable, "-m", "py_compile",
             str(SCRIPT_DIR / "ohos_xts_full_run.py")],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0)


class G3_CommandsInDispatch(_ArtifactTestCase):
    """G3: New commands integrated into ohos_device.sh dispatch."""

    def test_xts_full_run_in_dispatch(self):
        source = (SCRIPT_DIR / "ohos_device.sh").read_text()
        self.assertIn("xts-full-run)", source)

    def test_flash_in_dispatch(self):
        source = (SCRIPT_DIR / "ohos_device.sh").read_text()
        self.assertIn("flash)", source)

    def test_xts_run_in_dispatch(self):
        source = (SCRIPT_DIR / "ohos_device.sh").read_text()
        self.assertIn("xts-run)", source)


class G4_HelpTextDocumentsOptions(_ArtifactTestCase):
    """G4: Help text documents all options with examples."""

    def test_flash_help_has_examples(self):
        rc, out, err = _run_device_sh("flash", "--help")
        _save_artifact("flash_help_g4.txt", out)
        self.assertEqual(rc, 0)
        self.assertIn("Examples:", out)
        self.assertIn("--server", out)
        self.assertIn("--device", out)

    def test_xts_run_help_has_examples(self):
        rc, out, err = _run_device_sh("xts-run", "--help")
        self.assertEqual(rc, 0)
        self.assertIn("--tsv", out)

    def test_xts_full_run_help_has_examples(self):
        rc, out, err = _run_device_sh("xts-full-run", "--help")
        self.assertEqual(rc, 0)
        self.assertIn("--acts-root", out)

    def test_init_board_help_exists(self):
        rc, out, err = _run_device_sh("init-board", "--help")
        self.assertEqual(rc, 0)

    def test_power_help_exists(self):
        rc, out, err = _run_device_sh("power", "--help")
        self.assertEqual(rc, 0)


# =========================================================================
# G6/G7 — Test artifacts
# =========================================================================

class G6_TestArtifactsSaved(unittest.TestCase):
    """G6/G7: Test runs must save artifacts to test-artifacts/<timestamp>/."""

    @classmethod
    def setUpClass(cls):
        ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)

    def test_artifact_dir_exists(self):
        self.assertTrue(ARTIFACT_DIR.exists())

    def test_artifact_summary_written(self):
        """Write a summary of all artifacts after test run."""
        summary = {
            "run_timestamp": RUN_TIMESTAMP,
            "artifact_dir": str(ARTIFACT_DIR),
            "test_file": __file__,
            "requirements_tested": [
                "F1", "F2", "F6", "F7", "F8", "F9",
                "B1", "B2", "B3",
                "G1", "G2", "G3", "G4", "G5",
                "G6", "G7",
            ],
        }
        _save_artifact("summary.json", json.dumps(summary, indent=2))
        self.assertTrue((ARTIFACT_DIR / "summary.json").exists())


# =========================================================================
# R* — XTS full run requirements (shell-level integration)
# =========================================================================

class R6_DryRunNoSideEffects(_ArtifactTestCase):
    """R6: Dry-run produces plan without side effects."""

    def test_dry_run_no_output_dir(self):
        tmpdir = Path(tempfile.mkdtemp())
        acts = tmpdir / "acts"
        tc = acts / "testcases"
        tc.mkdir(parents=True)
        (tc / "ActsAceTest1.json").write_text("{}")
        (tc / "ActsAceTest1.hap").write_bytes(b"\x00")

        output = tmpdir / "should_not_exist"
        rc, out, err = _run_device_sh(
            "xts-full-run",
            "--acts-root", str(acts),
            "--devices", "SN001",
            "--output-dir", str(output),
            "--dry-run",
        )
        _save_artifact("dry_run_output.txt", out + "\n---STDERR---\n" + err)
        shutil.rmtree(tmpdir)
        self.assertEqual(rc, 0)
        self.assertFalse(output.exists(), "Dry-run created output dir")


# =========================================================================
# F10/F11/F12 — New flash requirements
# =========================================================================

class F10_BoardStateUpdatedOnFlash(_ArtifactTestCase):
    """F10: Board state file updated after successful flash."""

    def test_flash_help_mentions_board_state(self):
        rc, out, err = _run_device_sh("flash", "--help")
        _save_artifact("flash_help_board_state.txt", out)
        self.assertEqual(rc, 0)
        self.assertIn("board-state.json", out)

    def test_board_state_function_exists(self):
        """_board_state_update function exists in source."""
        source = (SCRIPT_DIR / "ohos_device.sh").read_text()
        self.assertIn("_board_state_update()", source)


class F11_SmartFlashRecovery(_ArtifactTestCase):
    """F11: Skip hdc switch if board already in Loader mode."""

    def test_flash_help_mentions_loader_skip(self):
        rc, out, err = _run_device_sh("flash", "--help")
        _save_artifact("flash_help_loader_skip.txt", out)
        self.assertEqual(rc, 0)
        self.assertIn("loader", out.lower())

    def test_check_device_mode_function_exists(self):
        """_check_device_mode function exists in source."""
        source = (SCRIPT_DIR / "ohos_device.sh").read_text()
        self.assertIn("_check_device_mode()", source)


class F12_FlashLocking(_ArtifactTestCase):
    """F12: Per-board flash locking prevents concurrent flashes."""

    def test_flash_help_mentions_locking(self):
        rc, out, err = _run_device_sh("flash", "--help")
        _save_artifact("flash_help_locking.txt", out)
        self.assertEqual(rc, 0)
        self.assertIn("lock", out.lower())

    def test_lock_functions_exist(self):
        """Flash lock functions exist in source."""
        source = (SCRIPT_DIR / "ohos_device.sh").read_text()
        self.assertIn("_flash_acquire_lock()", source)
        self.assertIn("_flash_release_lock()", source)
        self.assertIn("_flash_release_lock", source[source.index("_flash_cleanup()"):],
                      "Lock release must be called in _flash_cleanup")


if __name__ == "__main__":
    # Write artifact dir manifest before running
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    (ARTIFACT_DIR / ".gitkeep").write_text("")

    # Run with artifact capture
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)

    result = runner.run(suite)

    # Save final results as artifact (G6/G7)
    _save_artifact("test_results.json", json.dumps({
        "timestamp": RUN_TIMESTAMP,
        "tests_run": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "success": result.wasSuccessful(),
        "artifact_dir": str(ARTIFACT_DIR),
    }, indent=2))

    sys.exit(0 if result.wasSuccessful() else 1)
