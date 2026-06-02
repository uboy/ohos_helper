"""
Tests for board state tracking, smart flash recovery, and flash locking.

Requirements verified:
  F10 — Board state file updated after successful flash
  F11 — Smart flash recovery (skip hdc switch if already in Loader)
  F12 — Per-board flash locking

Test artifacts saved to: $TEST_ARTIFACT_ROOT/<timestamp>/ (default: $TMPDIR/ohos_test_artifacts)
"""

import json
import os
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

ARTIFACT_ROOT = Path(os.environ.get("TEST_ARTIFACT_ROOT", os.path.join(os.environ.get("TMPDIR", "/tmp"), "ohos_test_artifacts")))
RUN_TIMESTAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
ARTIFACT_DIR = ARTIFACT_ROOT / RUN_TIMESTAMP


def _run_device_sh(*args, timeout=10, env=None):
    """Run ohos_device.sh with args, capture output. Returns (rc, stdout, stderr)."""
    result = subprocess.run(
        ["bash", str(DEVICE_SH)] + list(args),
        capture_output=True, text=True, timeout=timeout,
        cwd=str(SCRIPT_DIR),
        env=env,
    )
    return result.returncode, result.stdout, result.stderr


def _save_artifact(name, content):
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    (ARTIFACT_DIR / name).write_text(content)


class _ArtifactTestCase(unittest.TestCase):
    """Base class that saves test output as artifacts."""

    def run(self, result=None):
        test_id = self.id()
        rc = super().run(result)
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
# Firmware Version Extraction
# =========================================================================

class TestExtractFirmwareVersion(_ArtifactTestCase):
    """Test _extract_firmware_version extracts version info from firmware dir."""

    def _make_firmware_dir(self, tmpdir, with_tarball=True, with_log=True,
                           with_parameter=True, with_manifest=True):
        """Create a fake firmware directory with version files."""
        fw_dir = tmpdir / "image_bundle"
        fw_dir.mkdir()
        fw_dir.mkdir(parents=True, exist_ok=True)

        # Always need MiniLoaderAll.bin for validity
        (fw_dir / "MiniLoaderAll.bin").write_bytes(b"\x00" * 100)

        parent = fw_dir.parent

        if with_tarball:
            tarball_name = "version-Daily_Version-OpenHarmony_7.0.0.26-20260526_180236-dayu200_img.tar.gz"
            (parent / tarball_name).write_bytes(b"\x00" * 100)

        if with_log:
            log_content = (
                "2026-05-26 18:02:36: [INFO]pipeline_cfg:{'versionName': "
                "'OpenHarmony_7.0.0.26', 'manifest_branch': 'master'}"
            )
            (fw_dir / "daily_build.log").write_text(log_content)

        if with_parameter:
            param = (
                "FIRMWARE_VER:11.0\n"
                "MACHINE_MODEL:rk3568_r\n"
                "MACHINE_ID:007\n"
                "MANUFACTURER: rockchip\n"
            )
            (fw_dir / "parameter.txt").write_text(param)

        if with_manifest:
            manifest = (
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<manifest>\n'
                '  <project name="test_repo" path="test/path" '
                'revision="a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"/>\n'
                '</manifest>\n'
            )
            (fw_dir / "manifest_tag.xml").write_text(manifest)

        return str(fw_dir)

    def test_extracts_version_from_tarball_name(self):
        """OpenHarmony version extracted from tarball filename."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware_dir(Path(tmp), with_tarball=True, with_log=False)
            rc, out, err = _run_device_sh("__test-internal", "extract-firmware-version", fw)
            _save_artifact("extract_tarball.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")
            self.assertIn("OPENHARMONY_VERSION=OpenHarmony_7.0.0.26", out)

    def test_extracts_version_from_daily_build_log_fallback(self):
        """Fallback to daily_build.log when no tarball."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware_dir(Path(tmp), with_tarball=False, with_log=True)
            rc, out, err = _run_device_sh("__test-internal", "extract-firmware-version", fw)
            _save_artifact("extract_log.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")
            self.assertIn("OPENHARMONY_VERSION=OpenHarmony_7.0.0.26", out)

    def test_extracts_firmware_ver_from_parameter_txt(self):
        """FIRMWARE_VER and MACHINE_MODEL from parameter.txt."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware_dir(Path(tmp), with_parameter=True)
            rc, out, err = _run_device_sh("__test-internal", "extract-firmware-version", fw)
            _save_artifact("extract_param.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")
            self.assertIn("FIRMWARE_VER=11.0", out)
            self.assertIn("MACHINE_MODEL=rk3568_r", out)

    def test_extracts_manifest_hash_from_xml(self):
        """Manifest hash from manifest_tag.xml."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware_dir(Path(tmp), with_manifest=True)
            rc, out, err = _run_device_sh("__test-internal", "extract-firmware-version", fw)
            _save_artifact("extract_manifest.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")
            self.assertIn("MANIFEST_HASH=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0", out)

    def test_missing_files_graceful(self):
        """Missing files produce empty values, no crash."""
        with tempfile.TemporaryDirectory() as tmp:
            fw_dir = Path(tmp) / "fw"
            fw_dir.mkdir()
            (fw_dir / "MiniLoaderAll.bin").write_bytes(b"\x00")
            rc, out, err = _run_device_sh("__test-internal", "extract-firmware-version", str(fw_dir))
            _save_artifact("extract_missing.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")
            self.assertIn("OPENHARMONY_VERSION=", out)
            self.assertIn("FIRMWARE_VER=", out)
            # Should still have all keys even if empty
            for key in ["OPENHARMONY_VERSION", "FIRMWARE_VER", "MACHINE_MODEL",
                        "MANIFEST_HASH", "TARBALL_NAME"]:
                self.assertIn(f"{key}=", out)


# =========================================================================
# Board State File
# =========================================================================

class TestBoardStateUpdate(_ArtifactTestCase):
    """Test _board_state_update writes valid JSON with correct structure."""

    def _make_firmware_dir(self, tmpdir):
        """Minimal valid firmware dir."""
        fw_dir = tmpdir / "fw"
        fw_dir.mkdir()
        (fw_dir / "MiniLoaderAll.bin").write_bytes(b"\x00" * 100)
        (fw_dir / "parameter.txt").write_text("FIRMWARE_VER:11.0\nMACHINE_MODEL:rk3568_r\n")
        parent = fw_dir.parent
        (parent / "version-Daily_Version-OpenHarmony_7.0.0.26-20260526_180236-dayu200_img.tar.gz").write_bytes(b"\x00")
        return str(fw_dir)

    def test_creates_state_file_on_first_flash(self):
        """State file created when it doesn't exist."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware_dir(Path(tmp))
            state_file = Path(tmp) / "board-state.json"
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            # Ensure boards.conf exists
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            rc, out, err = _run_device_sh(
                "__test-internal", "board-state-update",
                "TESTSERIAL123456", fw,
                env=env,
            )
            _save_artifact("state_create.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")
            self.assertTrue(state_file.exists(), "State file should be created")

            state = json.loads(state_file.read_text())
            self.assertIn("TESTSERIAL123456", state["boards"])
            entry = state["boards"]["TESTSERIAL123456"]
            self.assertEqual(entry["serial"], "TESTSERIAL123456")
            self.assertIn("firmware", entry)
            self.assertEqual(entry["firmware"]["openharmony_version"], "OpenHarmony_7.0.0.26")

    def test_updates_existing_entry(self):
        """Second update overwrites first for same serial."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware_dir(Path(tmp))
            state_file = Path(tmp) / "board-state.json"
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            # First update
            _run_device_sh("__test-internal", "board-state-update",
                          "SERIAL_A", fw, env=env)
            # Second update
            _run_device_sh("__test-internal", "board-state-update",
                          "SERIAL_A", fw, env=env)

            state = json.loads(state_file.read_text())
            self.assertEqual(len(state["boards"]), 1, "Should have 1 entry")

    def test_preserves_other_boards(self):
        """Updating board B preserves board A entry."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware_dir(Path(tmp))
            state_file = Path(tmp) / "board-state.json"
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            _run_device_sh("__test-internal", "board-state-update",
                          "SERIAL_A", fw, env=env)
            _run_device_sh("__test-internal", "board-state-update",
                          "SERIAL_B", fw, env=env)

            state = json.loads(state_file.read_text())
            self.assertIn("SERIAL_A", state["boards"])
            self.assertIn("SERIAL_B", state["boards"])
            self.assertEqual(len(state["boards"]), 2)

    def test_output_is_valid_json(self):
        """State file is always valid JSON."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware_dir(Path(tmp))
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            _run_device_sh("__test-internal", "board-state-update",
                          "SERIAL_X", fw, env=env)

            state_file = Path(tmp) / "board-state.json"
            self.assertTrue(state_file.exists())
            state = json.loads(state_file.read_text())
            self.assertEqual(state["version"], 1)
            self.assertIn("boards", state)

    def test_board_state_read_default(self):
        """_board_state_read returns default when file missing."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            rc, out, err = _run_device_sh("__test-internal", "board-state-read", env=env)
            state = json.loads(out)
            self.assertEqual(state["version"], 1)
            self.assertEqual(state["boards"], {})


# =========================================================================
# Flash Locking
# =========================================================================

class TestFlashLocking(_ArtifactTestCase):
    """Test per-board flash lock acquisition and release."""

    def test_acquire_creates_lock_file(self):
        """Lock file created with correct format."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            rc, out, err = _run_device_sh(
                "__test-internal", "flash-acquire-lock",
                "SERIAL123456", env=env,
            )
            _save_artifact("lock_acquire.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")

            lock_path = Path("/tmp/ohos-flash-123456.lock")
            self.assertTrue(lock_path.exists(), "Lock file should exist")
            content = lock_path.read_text()
            self.assertIn("PID:", content)
            self.assertIn("USER:", content)
            self.assertIn("STARTED:", content)

            # Cleanup
            lock_path.unlink(missing_ok=True)

    def test_acquire_fails_if_live_pid(self):
        """Second acquire fails when lock held by live process."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            # Create lock with current PID (always alive)
            lock_path = Path("/tmp/ohos-flash-123456.lock")
            lock_path.write_text(f"PID:{os.getpid()} USER:test STARTED:2026-01-01T00:00:00+0000\n")

            try:
                rc, out, err = _run_device_sh(
                    "__test-internal", "flash-acquire-lock",
                    "SERIAL123456", env=env,
                )
                _save_artifact("lock_live.txt", out + "\n---STDERR---\n" + err)
                self.assertNotEqual(rc, 0, "Should fail when locked by live process")
            finally:
                lock_path.unlink(missing_ok=True)

    def test_acquire_removes_stale_lock(self):
        """Stale lock (dead PID) is removed and new lock acquired."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            lock_path = Path("/tmp/ohos-flash-123456.lock")
            # PID 999999999 almost certainly doesn't exist
            lock_path.write_text("PID:999999999 USER:deadguy STARTED:2020-01-01T00:00:00+0000\n")

            try:
                rc, out, err = _run_device_sh(
                    "__test-internal", "flash-acquire-lock",
                    "SERIAL123456", env=env,
                )
                _save_artifact("lock_stale.txt", out + "\n---STDERR---\n" + err)
                self.assertEqual(rc, 0, f"Should succeed after removing stale lock: {err}")
                # Verify lock was overwritten
                content = lock_path.read_text()
                self.assertNotIn("999999999", content, "Stale lock should be overwritten")
            finally:
                lock_path.unlink(missing_ok=True)

    def test_release_removes_lock(self):
        """Release deletes lock file."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            lock_path = Path("/tmp/ohos-flash-123456.lock")
            lock_path.write_text(f"PID:{os.getpid()} USER:test STARTED:now\n")

            rc, out, err = _run_device_sh(
                "__test-internal", "flash-release-lock",
                "SERIAL123456", env=env,
            )
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")
            self.assertFalse(lock_path.exists(), "Lock file should be removed")

    def test_release_idempotent(self):
        """Release on non-existent lock doesn't error."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            lock_path = Path("/tmp/ohos-flash-123456.lock")
            lock_path.unlink(missing_ok=True)

            rc, out, err = _run_device_sh(
                "__test-internal", "flash-release-lock",
                "SERIAL123456", env=env,
            )
            self.assertEqual(rc, 0, f"Exit code {rc}: {err}")


# =========================================================================
# Device Mode Detection
# =========================================================================

class TestCheckDeviceMode(_ArtifactTestCase):
    """Test _check_device_mode parses flash_tool LD output."""

    def test_detects_loader_mode(self):
        """Detects Loader mode from flash_tool output."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_tool = Path(tmp) / "flash_tool"
            mock_tool.write_text(
                '#!/bin/bash\n'
                'echo "DevNo=1 SerialNo=ABC Mode=Loader LocationID=144 Pid=0x350a"\n'
            )
            mock_tool.chmod(0o755)

            rc, out, err = _run_device_sh(
                "__test-internal", "check-device-mode",
                str(mock_tool),
            )
            _save_artifact("mode_loader.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Loader")

    def test_detects_maskrom_mode(self):
        """Detects Maskrom mode from flash_tool output."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_tool = Path(tmp) / "flash_tool"
            mock_tool.write_text(
                '#!/bin/bash\n'
                'echo "DevNo=2 SerialNo=DEF Mode=Maskrom LocationID=200 Pid=0x5000"\n'
            )
            mock_tool.chmod(0o755)

            rc, out, err = _run_device_sh(
                "__test-internal", "check-device-mode",
                str(mock_tool),
            )
            _save_artifact("mode_maskrom.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Maskrom")

    def test_returns_empty_for_no_device(self):
        """Returns failure when no devices detected."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_tool = Path(tmp) / "flash_tool"
            mock_tool.write_text('#!/bin/bash\nexit 1\n')
            mock_tool.chmod(0o755)

            rc, out, err = _run_device_sh(
                "__test-internal", "check-device-mode",
                str(mock_tool),
            )
            _save_artifact("mode_empty.txt", out + "\n---STDERR---\n" + err)
            self.assertNotEqual(rc, 0, "Should fail when no device found")

    def test_filters_by_locationid(self):
        """Filters by LocationID when specified."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_tool = Path(tmp) / "flash_tool"
            mock_tool.write_text(
                '#!/bin/bash\n'
                'echo "DevNo=1 SerialNo=ABC Mode=Loader LocationID=144 Pid=0x350a"\n'
                'echo "DevNo=2 SerialNo=DEF Mode=Loader LocationID=200 Pid=0x350a"\n'
            )
            mock_tool.chmod(0o755)

            rc, out, err = _run_device_sh(
                "__test-internal", "check-device-mode",
                str(mock_tool), "200",
            )
            _save_artifact("mode_filtered.txt", out + "\n---STDERR---\n" + err)
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Loader")


# =========================================================================
# Lock Path
# =========================================================================

class TestFlashLockPath(_ArtifactTestCase):
    """Test _flash_lock_path generates correct path."""

    def test_lock_path_uses_short_suffix(self):
        """Lock path uses last 6 chars of serial."""
        rc, out, err = _run_device_sh(
            "__test-internal", "flash-lock-path",
            "VERYLONGSERIAL123456",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), "/tmp/ohos-flash-123456.lock")

    def test_lock_path_short_serial(self):
        """Short serial still works."""
        rc, out, err = _run_device_sh(
            "__test-internal", "flash-lock-path",
            "ABC",
        )
        self.assertEqual(rc, 0)
        self.assertIn("/tmp/ohos-flash-", out)


if __name__ == "__main__":
    unittest.main()
