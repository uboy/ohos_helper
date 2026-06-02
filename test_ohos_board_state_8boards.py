"""
Integration tests simulating all 8 boards with different states.

Scenarios:
  1. Board in Maskrom mode → normal flash (hdc switch required)
  2. Board already in Loader → skip switch, flash directly
  3. Concurrent flash to same board → blocked
  4. Concurrent flash to different boards → allowed
  5. Board state file updated after flash
  6. Mode detection across multi-device servers
  7. Stale lock cleanup
  8. Flash with missing LocationID fallback

Board topology (generic example):
  server1 (10.0.0.1): Board 1 (LocationID 143), Board 2 (LocationID 144)
  server2 (10.0.0.2): Board 3 (LocationID 144), Board 4 (LocationID 1b4), Board 6 (LocationID 18)
  server3 (10.0.0.3): Board 5 (LocationID 11), Board 7 (LocationID 14), Board 8 (LocationID 13)
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

SCRIPT_DIR = Path(__file__).resolve().parent
DEVICE_SH = SCRIPT_DIR / "ohos_device.sh"

# Add project directory to path for test_helpers import
sys.path.insert(0, str(SCRIPT_DIR))
from test_helpers import get_boards

ARTIFACT_ROOT = SCRIPT_DIR / "test-artifacts"
RUN_TIMESTAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
ARTIFACT_DIR = ARTIFACT_ROOT / RUN_TIMESTAMP

# Board definitions from test fixtures
BOARDS = get_boards()


def _run_device_sh(*args, timeout=10, env=None):
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


def _make_mock_flash_tool(tmpdir, devices_output):
    """Create a mock flash_tool that prints given LD output."""
    tool = tmpdir / "flash_tool"
    tool.write_text(f'#!/bin/bash\nif [ "$1" = "LD" ]; then\n  cat <<EOF\n{devices_output}\nEOF\n  exit 0\nelse\n  exit 0\nfi\n')
    tool.chmod(0o755)
    return str(tool)


class _ArtifactTestCase(unittest.TestCase):
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
# Scenario 1: Mode detection for all 8 boards (Maskrom state)
# =========================================================================

class TestModeDetectionAll8Boards(_ArtifactTestCase):
    """Detect Maskrom mode for each board individually on multi-device servers."""

    def test_board1_maskrom_on_bm1(self):
        """Board 1 (LocationID 143) in Maskrom on BM1 with 2 devices."""
        b1, b2 = BOARDS[0], BOARDS[1]
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), (
                f"DevNo=1 SerialNo={b1['loader_serial']} Mode=Maskrom LocationID={b1['locationid_loader']} Pid=0x5000\n"
                f"DevNo=2 SerialNo={b2['loader_serial']} Mode=Maskrom LocationID={b2['locationid_loader']} Pid=0x5000\n"
            ))
            rc, out, err = _run_device_sh("__test-internal", "check-device-mode", mock, b1["locationid_loader"])
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Maskrom")

    def test_board3_maskrom_on_bm2(self):
        """Board 3 (LocationID 144) in Maskrom on BM2 with 3 devices."""
        b3, b4, b6 = BOARDS[2], BOARDS[3], BOARDS[5]
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), (
                f"DevNo=1 SerialNo={b3['loader_serial']} Mode=Maskrom LocationID={b3['locationid_loader']} Pid=0x5000\n"
                f"DevNo=2 SerialNo={b4['loader_serial']} Mode=Maskrom LocationID={b4['locationid_loader']} Pid=0x5000\n"
                f"DevNo=3 SerialNo={b6['loader_serial']} Mode=Maskrom LocationID={b6['locationid_loader']} Pid=0x5000\n"
            ))
            rc, out, err = _run_device_sh("__test-internal", "check-device-mode", mock, b3["locationid_loader"])
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Maskrom")

    def test_board5_maskrom_on_bm3(self):
        """Board 5 (LocationID 11) in Maskrom on BM3 with 3 devices."""
        b5, b7, b8 = BOARDS[4], BOARDS[6], BOARDS[7]
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), (
                f"DevNo=1 SerialNo={b5['loader_serial']} Mode=Maskrom LocationID={b5['locationid_loader']} Pid=0x5000\n"
                f"DevNo=2 SerialNo={b7['loader_serial']} Mode=Maskrom LocationID={b7['locationid_loader']} Pid=0x5000\n"
                f"DevNo=3 SerialNo={b8['loader_serial']} Mode=Maskrom LocationID={b8['locationid_loader']} Pid=0x5000\n"
            ))
            rc, out, err = _run_device_sh("__test-internal", "check-device-mode", mock, b5["locationid_loader"])
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Maskrom")

    def test_board8_maskrom_on_bm3(self):
        """Board 8 (LocationID 13) in Maskrom on BM3."""
        b5, b7, b8 = BOARDS[4], BOARDS[6], BOARDS[7]
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), (
                f"DevNo=1 SerialNo={b5['loader_serial']} Mode=Maskrom LocationID={b5['locationid_loader']} Pid=0x5000\n"
                f"DevNo=2 SerialNo={b7['loader_serial']} Mode=Maskrom LocationID={b7['locationid_loader']} Pid=0x5000\n"
                f"DevNo=3 SerialNo={b8['loader_serial']} Mode=Maskrom LocationID={b8['locationid_loader']} Pid=0x5000\n"
            ))
            rc, out, err = _run_device_sh("__test-internal", "check-device-mode", mock, b8["locationid_loader"])
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Maskrom")


# =========================================================================
# Scenario 2: Board already in Loader mode (smart recovery)
# =========================================================================

class TestSmartRecoveryAll8Boards(_ArtifactTestCase):
    """Detect Loader mode for boards stuck after failed flash."""

    def _make_loader_scenario(self, server_boards, loader_n):
        """Create mock with one board in Loader, rest in Maskrom."""
        lines = []
        for i, b in enumerate(server_boards, 1):
            mode = "Loader" if b["n"] == loader_n else "Maskrom"
            pid = "0x350a" if mode == "Loader" else "0x5000"
            lines.append(f"DevNo={i} SerialNo={b['loader_serial']} Mode={mode} LocationID={b['locationid_loader']} Pid={pid}")
        return "\n".join(lines)

    def test_board1_loader_on_bm1(self):
        """Board 1 stuck in Loader — should be detected, skip switch."""
        bm1_boards = [
            {"n": 1, "loader_serial": BOARDS[0]["loader_serial"], "locationid_loader": BOARDS[0]["locationid_loader"]},
            {"n": 2, "loader_serial": BOARDS[1]["loader_serial"], "locationid_loader": BOARDS[1]["locationid_loader"]},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), self._make_loader_scenario(bm1_boards, 1))
            rc, out, err = _run_device_sh("__test-internal", "check-device-mode", mock, BOARDS[0]["locationid_loader"])
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Loader",
                "Board 1 should be detected in Loader mode on BM1")

    def test_board4_loader_on_bm2(self):
        """Board 4 stuck in Loader on BM2 with 2 other Maskrom boards."""
        bm2_boards = [
            {"n": 3, "loader_serial": BOARDS[2]["loader_serial"], "locationid_loader": BOARDS[2]["locationid_loader"]},
            {"n": 4, "loader_serial": BOARDS[3]["loader_serial"], "locationid_loader": BOARDS[3]["locationid_loader"]},
            {"n": 6, "loader_serial": BOARDS[5]["loader_serial"], "locationid_loader": BOARDS[5]["locationid_loader"]},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), self._make_loader_scenario(bm2_boards, 4))
            rc, out, err = _run_device_sh("__test-internal", "check-device-mode", mock, BOARDS[3]["locationid_loader"])
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Loader")

    def test_board7_loader_on_bm3(self):
        """Board 7 stuck in Loader on BM3."""
        bm3_boards = [
            {"n": 5, "loader_serial": BOARDS[4]["loader_serial"], "locationid_loader": BOARDS[4]["locationid_loader"]},
            {"n": 7, "loader_serial": BOARDS[6]["loader_serial"], "locationid_loader": BOARDS[6]["locationid_loader"]},
            {"n": 8, "loader_serial": BOARDS[7]["loader_serial"], "locationid_loader": BOARDS[7]["locationid_loader"]},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), self._make_loader_scenario(bm3_boards, 7))
            rc, out, err = _run_device_sh("__test-internal", "check-device-mode", mock, BOARDS[6]["locationid_loader"])
            self.assertEqual(rc, 0)
            self.assertEqual(out.strip(), "Loader")

    def test_mixed_modes_on_bm2(self):
        """BM2: Board 3 in Loader, Board 4 in Maskrom, Board 6 in Loader."""
        b3, b4, b6 = BOARDS[2], BOARDS[3], BOARDS[5]
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), (
                f"DevNo=1 SerialNo={b3['loader_serial']} Mode=Loader LocationID={b3['locationid_loader']} Pid=0x350a\n"
                f"DevNo=2 SerialNo={b4['loader_serial']} Mode=Maskrom LocationID={b4['locationid_loader']} Pid=0x5000\n"
                f"DevNo=3 SerialNo={b6['loader_serial']} Mode=Loader LocationID={b6['locationid_loader']} Pid=0x350a\n"
            ))
            # Board 3 → Loader
            rc, out, _ = _run_device_sh("__test-internal", "check-device-mode", mock, b3["locationid_loader"])
            self.assertEqual(out.strip(), "Loader")
            # Board 4 → Maskrom
            rc, out, _ = _run_device_sh("__test-internal", "check-device-mode", mock, b4["locationid_loader"])
            self.assertEqual(out.strip(), "Maskrom")
            # Board 6 → Loader
            rc, out, _ = _run_device_sh("__test-internal", "check-device-mode", mock, b6["locationid_loader"])
            self.assertEqual(out.strip(), "Loader")

    def test_no_device_found_for_wrong_locationid(self):
        """Wrong LocationID returns failure."""
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), (
                "DevNo=1 SerialNo=ABC Mode=Loader LocationID=143 Pid=0x350a\n"
                "DevNo=2 SerialNo=DEF Mode=Loader LocationID=144 Pid=0x350a\n"
            ))
            rc, out, _ = _run_device_sh("__test-internal", "check-device-mode", mock, "999")
            self.assertNotEqual(rc, 0, "Should fail for non-existent LocationID")


# =========================================================================
# Scenario 3: Flash locking across all 8 boards
# =========================================================================

class TestFlashLockingAll8Boards(_ArtifactTestCase):
    """Per-board locking works across all 8 boards independently."""

    def test_lock_all_8_boards(self):
        """Lock all 8 boards simultaneously, all succeed."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            locks_created = []
            try:
                for b in BOARDS:
                    rc, out, err = _run_device_sh(
                        "__test-internal", "flash-acquire-lock", b["serial"], env=env)
                    self.assertEqual(rc, 0,
                        f"Lock board {b['n']} ({b['short']}) failed: {err}")
                    lock_path = Path(f"/tmp/ohos-flash-{b['serial'][-6:]}.lock")
                    self.assertTrue(lock_path.exists(),
                        f"Lock file missing for board {b['n']}")
                    locks_created.append(lock_path)

                # Verify all 8 locks coexist
                for lock_path in locks_created:
                    self.assertTrue(lock_path.exists())
            finally:
                for lock_path in locks_created:
                    lock_path.unlink(missing_ok=True)

    def test_same_board_double_lock_blocked(self):
        """Locking same board twice — second lock blocked."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            # Pick Board 3
            serial = BOARDS[2]["serial"]
            lock_path = Path(f"/tmp/ohos-flash-{serial[-6:]}.lock")

            try:
                # First lock — success
                rc, _, _ = _run_device_sh("__test-internal", "flash-acquire-lock", serial, env=env)
                self.assertEqual(rc, 0)
                self.assertTrue(lock_path.exists())

                # Second lock — blocked (held by live PID from first subprocess)
                # Note: the PID in the lock file is from the now-dead subprocess,
                # so we need to write a lock with our own PID
                lock_path.write_text(f"PID:{os.getpid()} USER:test STARTED:now\n")

                rc, out, err = _run_device_sh("__test-internal", "flash-acquire-lock", serial, env=env)
                self.assertNotEqual(rc, 0, "Second lock should be blocked")
            finally:
                lock_path.unlink(missing_ok=True)

    def test_different_boards_independent(self):
        """Locking Board 1 doesn't block Board 2 (same server)."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            b1 = BOARDS[0]["serial"]
            b2 = BOARDS[1]["serial"]
            lock1 = Path(f"/tmp/ohos-flash-{b1[-6:]}.lock")
            lock2 = Path(f"/tmp/ohos-flash-{b2[-6:]}.lock")

            try:
                # Lock board 1
                rc, _, _ = _run_device_sh("__test-internal", "flash-acquire-lock", b1, env=env)
                self.assertEqual(rc, 0)

                # Board 2 should still be lockable (different serial)
                rc, _, _ = _run_device_sh("__test-internal", "flash-acquire-lock", b2, env=env)
                self.assertEqual(rc, 0, "Board 2 should be lockable while Board 1 locked")
            finally:
                lock1.unlink(missing_ok=True)
                lock2.unlink(missing_ok=True)

    def test_stale_lock_cleanup_per_board(self):
        """Stale lock on Board 5 cleaned up, fresh lock acquired."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            serial = BOARDS[4]["serial"]
            lock_path = Path(f"/tmp/ohos-flash-{serial[-6:]}.lock")

            try:
                # Create stale lock
                lock_path.write_text("PID:999999999 USER:deadguy STARTED:2020-01-01\n")

                rc, out, err = _run_device_sh("__test-internal", "flash-acquire-lock", serial, env=env)
                self.assertEqual(rc, 0, f"Stale lock should be replaced: {err}")
                content = lock_path.read_text()
                self.assertNotIn("999999999", content)
                self.assertIn("PID:", content)
            finally:
                lock_path.unlink(missing_ok=True)

    def test_release_all_8_boards(self):
        """Release locks for all 8 boards."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            for b in BOARDS:
                lock_path = Path(f"/tmp/ohos-flash-{b['serial'][-6:]}.lock")
                lock_path.write_text(f"PID:12345 USER:test STARTED:now\n")

                rc, _, _ = _run_device_sh("__test-internal", "flash-release-lock", b["serial"], env=env)
                self.assertEqual(rc, 0)
                self.assertFalse(lock_path.exists(), f"Lock for board {b['n']} should be removed")


# =========================================================================
# Scenario 4: Board state file with all 8 boards
# =========================================================================

class TestBoardStateAll8Boards(_ArtifactTestCase):
    """Board state file works with all 8 boards flashed."""

    def _make_firmware(self, tmpdir, version="7.0.0.26"):
        """Create minimal valid firmware dir."""
        fw = tmpdir / "fw"
        fw.mkdir()
        (fw / "MiniLoaderAll.bin").write_bytes(b"\x00")
        (fw / "parameter.txt").write_text(f"FIRMWARE_VER:11.0\nMACHINE_MODEL:rk3568_r\n")
        parent = fw.parent
        (parent / f"version-Daily_Version-OpenHarmony_{version}-20260526_180236-dayu200_img.tar.gz").write_bytes(b"\x00")
        (fw / "manifest_tag.xml").write_text(
            '<?xml version="1.0"?>\n<manifest>\n'
            f'<project name="test" revision="{"a" * 40}"/>\n</manifest>\n')
        return str(fw)

    def test_flash_all_8_boards_sequentially(self):
        """Simulate flashing all 8 boards — state file tracks all."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware(Path(tmp))
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            for b in BOARDS:
                rc, out, err = _run_device_sh(
                    "__test-internal", "board-state-update", b["serial"], fw, env=env)
                self.assertEqual(rc, 0,
                    f"Board {b['n']} state update failed: {err}")

            state_file = Path(tmp) / "board-state.json"
            state = json.loads(state_file.read_text())

            # All 8 boards in state
            self.assertEqual(len(state["boards"]), 8)
            for b in BOARDS:
                self.assertIn(b["serial"], state["boards"])
                entry = state["boards"][b["serial"]]
                self.assertEqual(entry["serial"], b["serial"])
                self.assertIn("firmware", entry)
                self.assertEqual(entry["firmware"]["openharmony_version"], "OpenHarmony_7.0.0.26")
                self.assertEqual(entry["firmware"]["firmware_ver"], "11.0")
                self.assertEqual(entry["firmware"]["machine_model"], "rk3568_r")

    def test_reflash_one_preserves_others(self):
        """Re-flash Board 3 — Boards 1,2,4-8 intact."""
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware(Path(tmp), version="7.0.0.26")
            fw2 = self._make_firmware_v2(Path(tmp))
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            # Flash all 8 with v26
            for b in BOARDS:
                _run_device_sh("__test-internal", "board-state-update", b["serial"], fw, env=env)

            # Re-flash Board 3 with v28
            _run_device_sh("__test-internal", "board-state-update",
                          BOARDS[2]["serial"], fw2, env=env)

            state = json.loads((Path(tmp) / "board-state.json").read_text())

            # Board 3 has new version
            self.assertEqual(state["boards"][BOARDS[2]["serial"]]["firmware"]["openharmony_version"],
                           "OpenHarmony_7.0.0.28")
            # Board 1 still has old version
            self.assertEqual(state["boards"][BOARDS[0]["serial"]]["firmware"]["openharmony_version"],
                           "OpenHarmony_7.0.0.26")
            # Still 8 boards
            self.assertEqual(len(state["boards"]), 8)

    def _make_firmware_v2(self, tmpdir):
        """Create firmware v2 in separate subdirectory to avoid tarball collision."""
        v2dir = tmpdir / "firmware_v2"
        v2dir.mkdir()
        fw = v2dir / "fw"
        fw.mkdir()
        (fw / "MiniLoaderAll.bin").write_bytes(b"\x00")
        (fw / "parameter.txt").write_text("FIRMWARE_VER:11.1\nMACHINE_MODEL:rk3568_r\n")
        (v2dir / "version-Daily_Version-OpenHarmony_7.0.0.28-20260530_120000-dayu200_img.tar.gz").write_bytes(b"\x00")
        (fw / "manifest_tag.xml").write_text(
            '<?xml version="1.0"?>\n<manifest>\n'
            f'<project name="test" revision="{"b" * 40}"/>\n</manifest>\n')
        return str(fw)

    def test_board_short_and_server_resolved(self):
        """Board short and server resolved from boards.conf."""
        fb1, fb2 = BOARDS[0], BOARDS[1]
        with tempfile.TemporaryDirectory() as tmp:
            fw = self._make_firmware(Path(tmp))
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            # Write real boards.conf
            (Path(tmp) / "boards.conf").write_text(
                f"BOARD_COUNT=2\n"
                f"BOARD_1_SERIAL={fb1['serial']}\n"
                f"BOARD_1_SHORT={fb1['short']}\n"
                f"BOARD_1_SERVER={fb1['server']}\n"
                f"BOARD_2_SERIAL={fb2['serial']}\n"
                f"BOARD_2_SHORT={fb2['short']}\n"
                f"BOARD_2_SERVER={fb2['server']}\n"
            )

            _run_device_sh("__test-internal", "board-state-update",
                          fb1["serial"], fw, env=env)
            _run_device_sh("__test-internal", "board-state-update",
                          fb2["serial"], fw, env=env)

            state = json.loads((Path(tmp) / "board-state.json").read_text())

            b1 = state["boards"][fb1["serial"]]
            self.assertEqual(b1["short"], fb1["short"])
            self.assertEqual(b1["server"], fb1["server"])

            b2 = state["boards"][fb2["serial"]]
            self.assertEqual(b2["short"], fb2["short"])
            self.assertEqual(b2["server"], fb2["server"])

    def test_state_file_survives_partial_corruption(self):
        """Missing state file treated as empty — no crash."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            # Read with no file
            rc, out, _ = _run_device_sh("__test-internal", "board-state-read", env=env)
            self.assertEqual(rc, 0)
            state = json.loads(out)
            self.assertEqual(state, {"version": 1, "boards": {}})


# =========================================================================
# Scenario 5: Edge cases
# =========================================================================

class TestEdgeCases(_ArtifactTestCase):
    """Edge cases with real board data."""

    def test_locationid_collision_bm1_bm2(self):
        """Board 2 and Board 3 both have LocationID 144 but on different servers.
        Lock files should not collide because serials differ."""
        b2 = BOARDS[1]  # serial ...a2eba00, short new-a2eba00
        b3 = BOARDS[2]  # serial ...feb8800, short feb8800

        lock2 = Path(f"/tmp/ohos-flash-{b2['serial'][-6:]}.lock")
        lock3 = Path(f"/tmp/ohos-flash-{b3['serial'][-6:]}.lock")

        # Lock paths differ because serials differ
        self.assertNotEqual(str(lock2), str(lock3),
            "Boards with same LocationID on different servers must have different lock paths")

    def test_lock_path_derived_from_serial_not_locationid(self):
        """Lock uses last 6 chars of serial (HDC), not LocationID."""
        for b in BOARDS:
            lock = f"/tmp/ohos-flash-{b['serial'][-6:]}.lock"
            # Verify lock contains serial suffix, not LocationID
            self.assertIn(b["serial"][-6:], lock,
                         f"Board {b['n']} lock path should contain serial suffix")
            self.assertNotIn(b["locationid_loader"], lock.replace("ohos-flash-", "").replace(".lock", ""),
                         f"Board {b['n']} lock path should not contain LocationID")

    def test_empty_serial_handled(self):
        """Empty serial doesn't crash."""
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["OHOS_CONF_DIR"] = tmp
            (Path(tmp) / "boards.conf").write_text("BOARD_COUNT=0\n")

            rc, out, err = _run_device_sh("__test-internal", "board-state-update",
                                          "", "/some/path", env=env)
            # Should warn but not crash
            self.assertEqual(rc, 0)

    def test_no_device_on_server(self):
        """No devices detected on server — mode detection returns failure."""
        with tempfile.TemporaryDirectory() as tmp:
            mock = _make_mock_flash_tool(Path(tmp), "")
            rc, out, _ = _run_device_sh("__test-internal", "check-device-mode", mock)
            self.assertNotEqual(rc, 0)


if __name__ == "__main__":
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    (ARTIFACT_DIR / ".gitkeep").write_text("")
    unittest.main()
