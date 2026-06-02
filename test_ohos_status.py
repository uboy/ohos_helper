#!/usr/bin/env python3
"""Tests for ohos_status.py"""

import json
import os
import sys
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

# Add project directory to path for test_helpers import
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from test_helpers import get_boards, get_pdu, get_servers, get_ssh

from ohos_status import (
    compute_board_status,
    detect_completed_xts,
    detect_other_ops,
    detect_running_xts,
    detect_tmux_sessions,
    fmt_ago,
    fmt_duration,
    parse_boards_conf,
    parse_run_log_shards,
    progress_bar,
)

# Get fixture data
BOARDS = get_boards()
PDU = get_pdu()
SERVERS = get_servers()
SSH = get_ssh()

SAMPLE_BOARDS_CONF = textwrap.dedent(f"""\
    # Board inventory
    PDU_HOST="{PDU['host']}"

    BOARD_1_LABEL="{BOARDS[0]['label']}"
    BOARD_1_SERVER="{BOARDS[0]['server']}"
    BOARD_1_SERIAL="{BOARDS[0]['serial']}"
    BOARD_1_SHORT="{BOARDS[0]['short']}"
    BOARD_1_OUTLET="3"
    BOARD_1_STATUS="OK"

    BOARD_2_LABEL="{BOARDS[1]['label']}"
    BOARD_2_SERVER="{BOARDS[1]['server']}"
    BOARD_2_SERIAL="{BOARDS[1]['serial']}"
    BOARD_2_SHORT="{BOARDS[1]['short']}"
    BOARD_2_OUTLET="7"
    BOARD_2_STATUS="OK"

    BOARD_3_LABEL="{BOARDS[2]['label']}"
    BOARD_3_SERVER="{BOARDS[2]['server']}"
    BOARD_3_SERIAL="{BOARDS[2]['serial']}"
    BOARD_3_SHORT="{BOARDS[2]['short']}"
    BOARD_3_OUTLET="4"
    BOARD_3_STATUS="BROKEN"
""")


class TestFmtDuration(unittest.TestCase):
    def test_seconds(self):
        self.assertEqual(fmt_duration(45), "45s")

    def test_minutes(self):
        self.assertEqual(fmt_duration(180), "3m")

    def test_hours_minutes(self):
        self.assertEqual(fmt_duration(3720), "1h 2m")

    def test_hours_minutes_seconds(self):
        self.assertEqual(fmt_duration(3725), "1h 2m 5s")


class TestProgressbar(unittest.TestCase):
    def test_zero(self):
        bar = progress_bar(0, 100, width=10)
        self.assertEqual(bar, "░" * 10)

    def test_half(self):
        bar = progress_bar(50, 100, width=10)
        self.assertEqual(bar, "█████░░░░░")

    def test_full(self):
        bar = progress_bar(100, 100, width=10)
        self.assertEqual(bar, "█" * 10)

    def test_zero_total(self):
        bar = progress_bar(0, 0, width=10)
        self.assertEqual(bar, "░" * 10)


class TestFmtAgo(unittest.TestCase):
    def test_recent(self):
        result = fmt_ago("2026-01-01T00:00:00Z")
        # Should contain "ago"
        self.assertIn("ago", result)

    def test_invalid(self):
        self.assertEqual(fmt_ago(""), "?")


class TestParseBoardsConf(unittest.TestCase):
    def test_parse(self):
        import tempfile, os
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as f:
            f.write(SAMPLE_BOARDS_CONF)
            f.flush()
            boards = parse_boards_conf(Path(f.name))
        os.unlink(f.name)

        self.assertEqual(len(boards), 3)
        self.assertEqual(boards[0]["label"], BOARDS[0]["label"])
        self.assertEqual(boards[0]["server"], BOARDS[0]["server"])
        self.assertEqual(boards[0]["serial"], BOARDS[0]["serial"])
        self.assertEqual(boards[0]["short"], BOARDS[0]["short"])
        self.assertEqual(boards[1]["label"], BOARDS[1]["label"])
        self.assertEqual(boards[2]["status"], "BROKEN")

    def test_missing_file(self):
        boards = parse_boards_conf(Path("/nonexistent/boards.conf"))
        self.assertEqual(boards, [])


SAMPLE_PS_OUTPUT = textwrap.dedent(f"""\
    {SSH['user']}  2896003  0.0  0.0  7508  3692 ?  Ss  09:42  0:00 /bin/bash -c source /foo && eval 'python3 ohos_xts_full_run.py --label full-ci-cycle1 --devices AAAA,BBBB --variant static --skip-init'
    {SSH['user']}  2896023  0.0  0.0 344504 26016 ?  Sl  09:42  0:02 python3 ohos_xts_full_run.py --acts-root /path/acts --devices AAAA,BBBB --variant static --pattern ActsAce* --label full-ci-cycle1 --skip-init
    {SSH['user']}  2896045  0.0  0.0 344504 26320 ?  Sl  09:42  0:02 python3 ohos_xts_full_run.py --acts-root /path/acts --devices CCCC,DDDD --variant static --pattern ActsAce* --label full-bl-cycle1
    {SSH['user']}  1234567  0.0  0.0 344504 26320 ?  Sl  09:42  0:02 python3 some_other_script.py --label foo
""")


class TestDetectRunningXTS(unittest.TestCase):
    def test_detects_python_processes(self):
        runs = detect_running_xts(SAMPLE_PS_OUTPUT)
        # Should only find the 2 actual python3 processes (not bash wrapper, not other script)
        self.assertEqual(len(runs), 2)

    def test_extracts_label(self):
        runs = detect_running_xts(SAMPLE_PS_OUTPUT)
        labels = {r["label"] for r in runs}
        self.assertIn("full-ci-cycle1", labels)
        self.assertIn("full-bl-cycle1", labels)

    def test_extracts_devices(self):
        runs = detect_running_xts(SAMPLE_PS_OUTPUT)
        ci_run = next(r for r in runs if r["label"] == "full-ci-cycle1")
        self.assertEqual(ci_run["device_serials"], ["AAAA", "BBBB"])

    def test_extracts_variant(self):
        runs = detect_running_xts(SAMPLE_PS_OUTPUT)
        for r in runs:
            self.assertEqual(r["variant"], "static")


# Build SAMPLE_RUN_LOG dynamically from fixture board serials
# Use boards 1, 3, 5 (indices 0, 2, 4) as 3-shard sample
_shard_b1, _shard_b2, _shard_b3 = BOARDS[1], BOARDS[3], BOARDS[5]
_shard_s1 = _shard_b1["serial"][-12:]  # e.g. 1f100a2eba00
_shard_s2 = _shard_b2["serial"][-12:]  # e.g. 69874e4f8800
_shard_s3 = _shard_b3["serial"][-12:]  # e.g. f8517d2dba00

SAMPLE_RUN_LOG = textwrap.dedent(f"""\
    [2026-05-30T06:42:07Z] INFO Checking HDC connectivity...
    [2026-05-30T06:44:29Z] INFO [shard-01-{_shard_s1}] Running 111 modules on {_shard_b1['serial']}
    [2026-05-30T06:44:29Z] INFO [shard-02-{_shard_s2}] Running 111 modules on {_shard_b2['serial']}
    [2026-05-30T06:44:28Z] INFO [shard-03-{_shard_s3}] Running 110 modules on {_shard_b3['serial']}
    [2026-05-30T07:44:29Z] INFO [shard-02-{_shard_s2}] PASS: 111 modules, 3600s
""")


class TestParseRunLogShards(unittest.TestCase):
    def test_parses_shards(self):
        import tempfile, os
        with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
            f.write(SAMPLE_RUN_LOG)
            f.flush()
            shards = parse_run_log_shards(Path(f.name))
        os.unlink(f.name)

        self.assertEqual(len(shards), 3)
        self.assertEqual(shards[0]["name"], f"shard-01-{_shard_s1}")
        self.assertEqual(shards[0]["total"], 111)
        self.assertEqual(shards[0]["serial"], _shard_b1["serial"])

    def test_completed_shard(self):
        import tempfile, os
        with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
            f.write(SAMPLE_RUN_LOG)
            f.flush()
            shards = parse_run_log_shards(Path(f.name))
        os.unlink(f.name)

        shard02 = next(s for s in shards if _shard_s2 in s["name"])
        self.assertEqual(shard02["status"], "PASS")
        self.assertEqual(shard02["done"], 111)

    def test_running_shard(self):
        import tempfile, os
        with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
            f.write(SAMPLE_RUN_LOG)
            f.flush()
            shards = parse_run_log_shards(Path(f.name))
        os.unlink(f.name)

        shard01 = next(s for s in shards if _shard_s1 in s["name"])
        self.assertEqual(shard01["status"], "RUNNING")
        self.assertIsNone(shard01["done"])

    def test_missing_file(self):
        shards = parse_run_log_shards(Path("/nonexistent/run.log"))
        self.assertEqual(shards, [])


SAMPLE_REPORT_JSON = {
    "run_label": "full-test-run",
    "started_at": "2026-05-30T06:00:00Z",
    "finished_at": "2026-05-30T10:00:00Z",
    "total_modules": 443,
    "device_count": 4,
    "aggregate": {
        "successful": 3,
        "failed": 1,
        "timed_out": 0,
        "total_duration_s": 14400,
    },
}


class TestDetectCompletedXTS(unittest.TestCase):
    def test_scans_reports(self):
        import tempfile, os
        with tempfile.TemporaryDirectory() as tmpdir:
            run_dir = Path(tmpdir) / "full-test-run"
            run_dir.mkdir()
            (run_dir / "full_run_report.json").write_text(json.dumps(SAMPLE_REPORT_JSON))

            runs = detect_completed_xts(Path(tmpdir), limit=5)
            self.assertEqual(len(runs), 1)
            self.assertEqual(runs[0]["label"], "full-test-run")
            self.assertEqual(runs[0]["successful"], 3)
            self.assertEqual(runs[0]["failed"], 1)

    def test_empty_dir(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            runs = detect_completed_xts(Path(tmpdir), limit=5)
            self.assertEqual(runs, [])


class TestDetectOtherOps(unittest.TestCase):
    def test_flash(self):
        ps = f"{SSH['user']}  12345  0.0  0.0  344504  26320  ?  Sl  09:42  0:02 python3 flash.py --image /path/to/fw\n"
        ops = detect_other_ops(ps)
        self.assertEqual(len(ops["flash"]), 1)
        self.assertEqual(ops["flash"][0]["pid"], "12345")

    def test_build(self):
        ps = f"{SSH['user']}  99999  0.0  0.0  344504  26320  ?  Sl  09:42  0:02 /bin/bash build.sh --product-name rk3568\n"
        ops = detect_other_ops(ps)
        self.assertEqual(len(ops["build"]), 1)

    def test_none(self):
        ps = f"{SSH['user']} 123 ps aux\n"
        ops = detect_other_ops(ps)
        self.assertEqual(ops["flash"], [])
        self.assertEqual(ops["build"], [])


class TestComputeBoardStatus(unittest.TestCase):
    def test_free(self):
        boards = [{"serial": "AAA", "label": "B1", "short": "aaa", "server": "10.0.0.1", "status": "OK"}]
        status = compute_board_status(boards, [])
        self.assertIsNone(status[0]["in_use_by"])

    def test_in_use(self):
        boards = [{"serial": "AAA", "label": "B1", "short": "aaa", "server": "10.0.0.1", "status": "OK"}]
        runs = [{"label": "my-run", "device_serials": ["AAA"], "shards": []}]
        status = compute_board_status(boards, runs)
        self.assertEqual(status[0]["in_use_by"], "my-run")


class TestDetectTmuxSessions(unittest.TestCase):
    @patch("ohos_status.subprocess.run")
    def test_detects_xts_sessions(self, mock_run):
        mock_run.return_value = unittest.mock.Mock(
            returncode=0, stdout="xts-ci-run\nxts-bl-run\nother-session\n"
        )
        sessions = detect_tmux_sessions()
        self.assertEqual(len(sessions), 2)
        self.assertEqual(sessions[0]["name"], "xts-ci-run")
        self.assertEqual(sessions[1]["name"], "xts-bl-run")

    @patch("ohos_status.subprocess.run")
    def test_no_tmux_running(self, mock_run):
        mock_run.return_value = unittest.mock.Mock(returncode=1, stdout="")
        sessions = detect_tmux_sessions()
        self.assertEqual(sessions, [])

    @patch("ohos_status.subprocess.run", side_effect=Exception("no tmux"))
    def test_tmux_not_installed(self, mock_run):
        sessions = detect_tmux_sessions()
        self.assertEqual(sessions, [])

if __name__ == "__main__":
    unittest.main()
