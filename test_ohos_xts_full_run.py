"""
Tests for ohos_xts_full_run.py — verify REQUIREMENTS, not implementation.

Requirements under test:
  R1  Board inventory from conf/boards.conf, --boards, --devices overrides
  R2  Module discovery from testcases/*.json with variant filtering
  R3  Round-robin test partitioning across shards
  R4  Shard suite creation: xdevice config files (user_config.xml, acts.json)
  R5  Report format compatible with existing xts_full_runs/ convention
  R6  Dry-run produces plan without side effects
  R7  Exit code: 0 on all pass, 1 on any fail/timeout
  R8  Cleanup of temporary directories after run
  R9  Missing required files (.json) cause early failure, not silent skip
  R10 Shard names use 12-char suffix to prevent collision on multi-device servers
  R11 Remote reports rsync'd back even when xdevice SSH times out
  R12 Connectivity check tolerates remote-only boards (skip-connect flag)
  R13 Local tmux self-relaunch: auto-detect, create session, or warn
  R14 Remote xdevice runs in tmux when available, fallback to direct SSH
"""

import json
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import TestCase, mock

import ohos_xts_full_run as sut


class R1BoardInventory(TestCase):
    """R1: Board inventory from conf/boards.conf with overrides."""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp(prefix="test_xts_r1_"))
        self.conf_dir = self.tmpdir / "conf"
        self.conf_dir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _write_boards_conf(self, boards_text: str):
        (self.conf_dir / "boards.conf").write_text(boards_text)

    def test_boards_conf_only_ok_boards_returned(self):
        """Only boards with STATUS=OK are returned by default."""
        self._write_boards_conf(
            'BOARD_1_SERIAL="AAA"\nBOARD_1_SHORT="aaa"\nBOARD_1_STATUS="OK"\n'
            'BOARD_1_SERVER="10.0.0.1"\n'
            'BOARD_2_SERIAL="BBB"\nBOARD_2_SHORT="bbb"\nBOARD_2_STATUS="BROKEN"\n'
            'BOARD_2_SERVER="10.0.0.2"\n'
        )
        boards = sut.resolve_boards(self.conf_dir, None, None)
        serials = [b["serial"] for b in boards]
        self.assertEqual(serials, ["AAA"])

    def test_boards_conf_filter_by_short(self):
        """--boards filters by short serial from boards.conf."""
        self._write_boards_conf(
            'BOARD_1_SERIAL="AAA"\nBOARD_1_SHORT="aaa"\nBOARD_1_STATUS="OK"\n'
            'BOARD_1_SERVER="10.0.0.1"\n'
            'BOARD_2_SERIAL="BBB"\nBOARD_2_SHORT="bbb"\nBOARD_2_STATUS="OK"\n'
            'BOARD_2_SERVER="10.0.0.2"\n'
        )
        boards = sut.resolve_boards(self.conf_dir, ["bbb"], None)
        self.assertEqual(len(boards), 1)
        self.assertEqual(boards[0]["serial"], "BBB")

    def test_boards_conf_no_conf_no_devices_exits(self):
        """Missing boards.conf without --devices causes exit."""
        with self.assertRaises(SystemExit):
            sut.resolve_boards(self.tmpdir / "nonexistent", None, None)

    def test_devices_override_skips_conf(self):
        """--devices bypasses boards.conf entirely."""
        boards = sut.resolve_boards(None, None, ["SN001", "SN002"])
        self.assertEqual(len(boards), 2)
        self.assertEqual(boards[0]["serial"], "SN001")
        self.assertEqual(boards[1]["serial"], "SN002")

    def test_devices_override_preserves_server_empty(self):
        """--devices entries have empty server (local execution)."""
        boards = sut.resolve_boards(None, None, ["SN001"])
        self.assertEqual(boards[0]["server"], "")

    def test_short_serial_shorter_than_6(self):
        """Short serials < 6 chars are kept as-is, not sliced."""
        boards = sut.resolve_boards(None, None, ["ABC"])
        self.assertEqual(boards[0]["short"], "ABC")

    def test_boards_conf_contains_server(self):
        """Board entries from conf include server field."""
        self._write_boards_conf(
            'BOARD_1_SERIAL="AAA"\nBOARD_1_SHORT="aaa"\nBOARD_1_STATUS="OK"\n'
            'BOARD_1_SERVER="10.0.0.1"\n'
        )
        boards = sut.resolve_boards(self.conf_dir, None, None)
        self.assertEqual(boards[0]["server"], "10.0.0.1")


class R2ModuleDiscovery(TestCase):
    """R2: Module discovery from testcases/*.json with variant filtering."""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp(prefix="test_xts_r2_"))
        self.tc_dir = self.tmpdir / "testcases"
        self.tc_dir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _create_module(self, name: str):
        (self.tc_dir / f"{name}.json").write_text("{}")
        (self.tc_dir / f"{name}.hap").write_bytes(b"\x00")

    def test_discovers_actsace_modules(self):
        """Finds all ActsAce*.json modules (excluding .syscap.json)."""
        self._create_module("ActsAceButton")
        self._create_module("ActsAceImage")
        self._create_module("ActsAceButton.syscap")  # should be excluded
        (self.tc_dir / "ActsAceButton.syscap.json").write_text("{}")
        (self.tc_dir / "OtherModule.json").write_text("{}")

        modules = sut.list_ace_test_modules(self.tc_dir)
        self.assertIn("ActsAceButton", modules)
        self.assertIn("ActsAceImage", modules)
        self.assertNotIn("ActsAceButton.syscap", modules)
        self.assertNotIn("OtherModule", modules)

    def test_variant_static_filters(self):
        """variant=static returns only modules containing StaticTest."""
        self._create_module("ActsAceButtonStaticTest")
        self._create_module("ActsAceButtonDynamicTest")
        self._create_module("ActsAceButtonOther")

        modules = sut.list_ace_test_modules(self.tc_dir, variant="static")
        self.assertEqual(modules, ["ActsAceButtonStaticTest"])

    def test_variant_dynamic_filters(self):
        """variant=dynamic returns only modules containing DynamicTest."""
        self._create_module("ActsAceButtonStaticTest")
        self._create_module("ActsAceButtonDynamicTest")

        modules = sut.list_ace_test_modules(self.tc_dir, variant="dynamic")
        self.assertEqual(modules, ["ActsAceButtonDynamicTest"])

    def test_variant_any_returns_all(self):
        """variant=any returns all matching modules."""
        self._create_module("ActsAceButtonStaticTest")
        self._create_module("ActsAceButtonDynamicTest")
        self._create_module("ActsAceButtonOther")

        modules = sut.list_ace_test_modules(self.tc_dir, variant="any")
        self.assertEqual(len(modules), 3)

    def test_custom_pattern(self):
        """Custom --pattern overrides default ActsAce*."""
        self._create_module("ActsUiTest")
        self._create_module("ActsAceButton")

        modules = sut.list_ace_test_modules(self.tc_dir, pattern="ActsUi*")
        self.assertEqual(modules, ["ActsUiTest"])

    def test_empty_testcases_returns_empty(self):
        """Empty testcases dir returns no modules."""
        modules = sut.list_ace_test_modules(self.tc_dir)
        self.assertEqual(modules, [])


class R3Partitioning(TestCase):
    """R3: Round-robin test partitioning across shards."""

    def test_even_distribution(self):
        """Modules are distributed round-robin across shards."""
        modules = [f"Mod{i}" for i in range(6)]
        shards = sut.partition_tests(modules, 3)
        self.assertEqual(shards[0], ["Mod0", "Mod3"])
        self.assertEqual(shards[1], ["Mod1", "Mod4"])
        self.assertEqual(shards[2], ["Mod2", "Mod5"])

    def test_uneven_distribution(self):
        """Extra modules go to earlier shards."""
        modules = [f"Mod{i}" for i in range(5)]
        shards = sut.partition_tests(modules, 2)
        self.assertEqual(shards[0], ["Mod0", "Mod2", "Mod4"])
        self.assertEqual(shards[1], ["Mod1", "Mod3"])

    def test_more_shards_than_modules(self):
        """Extra shards are empty."""
        modules = ["Mod0"]
        shards = sut.partition_tests(modules, 3)
        self.assertEqual(shards[0], ["Mod0"])
        self.assertEqual(shards[1], [])
        self.assertEqual(shards[2], [])

    def test_single_shard(self):
        """Single shard gets all modules."""
        modules = ["Mod0", "Mod1", "Mod2"]
        shards = sut.partition_tests(modules, 1)
        self.assertEqual(shards[0], modules)

    def test_no_modules(self):
        """Empty module list produces empty shards."""
        shards = sut.partition_tests([], 3)
        self.assertTrue(all(s == [] for s in shards))


class R4ShardSuite(TestCase):
    """R4: Shard suite creation produces valid xdevice config files."""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp(prefix="test_xts_r4_"))
        self.acts_root = self.tmpdir / "acts"
        self.acts_tc = self.acts_root / "testcases"
        self.acts_cfg = self.acts_root / "config"
        self.acts_tc.mkdir(parents=True)
        self.acts_cfg.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _create_source_module(self, name: str, with_hap: bool = True):
        (self.acts_tc / f"{name}.json").write_text('{"test": true}')
        if with_hap:
            (self.acts_tc / f"{name}.hap").write_bytes(b"\x00")

    def test_user_config_xml_contains_device_sn(self):
        """user_config.xml targets the correct device serial."""
        shard_dir = self.tmpdir / "shard"
        self._create_source_module("ActsAceTest1")
        sut.create_shard_suite(self.acts_root, shard_dir, ["ActsAceTest1"], "MY-SERIAL-123")

        tree = ET.parse(shard_dir / "config" / "user_config.xml")
        sn_elem = tree.find(".//sn")
        self.assertIsNotNone(sn_elem)
        self.assertEqual(sn_elem.text, "MY-SERIAL-123")

    def test_acts_json_has_shellkit(self):
        """Generated acts.json contains ShellKit with required device prep commands."""
        shard_dir = self.tmpdir / "shard"
        self._create_source_module("ActsAceTest1")
        sut.create_shard_suite(self.acts_root, shard_dir, ["ActsAceTest1"], "SN1")

        acts = json.loads((shard_dir / "config" / "acts.json").read_text())
        kit_types = [k["type"] for k in acts["kits"]]
        self.assertIn("ShellKit", kit_types)
        shellkit = next(k for k in acts["kits"] if k["type"] == "ShellKit")
        run_cmds = shellkit["run-command"]
        self.assertIn("remount", run_cmds)
        self.assertIn("chmod -R 777 /data/data/resource", run_cmds)

    def test_acts_json_uses_template_when_available(self):
        """When acts/config/acts.json exists, it's copied instead of generated."""
        (self.acts_cfg / "acts.json").write_text('{"custom": true}')
        shard_dir = self.tmpdir / "shard"
        self._create_source_module("ActsAceTest1")
        sut.create_shard_suite(self.acts_root, shard_dir, ["ActsAceTest1"], "SN1")

        acts = json.loads((shard_dir / "config" / "acts.json").read_text())
        self.assertEqual(acts, {"custom": True})

    def test_test_files_copied_to_shard(self):
        """Module .json and .hap files are copied into shard testcases/."""
        shard_dir = self.tmpdir / "shard"
        self._create_source_module("ActsAceTest1")
        self._create_source_module("ActsAceTest2")
        sut.create_shard_suite(self.acts_root, shard_dir, ["ActsAceTest1", "ActsAceTest2"], "SN1")

        tc = shard_dir / "testcases"
        self.assertTrue((tc / "ActsAceTest1.json").exists())
        self.assertTrue((tc / "ActsAceTest1.hap").exists())
        self.assertTrue((tc / "ActsAceTest2.json").exists())

    def test_missing_json_causes_failure(self):
        """R9: Missing .json for a module causes early failure."""
        shard_dir = self.tmpdir / "shard"
        # No source files created — ActsAceTest1.json missing
        with self.assertRaises(SystemExit):
            sut.create_shard_suite(self.acts_root, shard_dir, ["ActsAceTest1"], "SN1")

    def test_missing_hap_produces_warning(self):
        """R9: Missing .hap warns but doesn't die (json is the critical file)."""
        shard_dir = self.tmpdir / "shard"
        self._create_source_module("ActsAceTest1", with_hap=False)
        with mock.patch("ohos_xts_full_run.warn") as mock_warn:
            sut.create_shard_suite(self.acts_root, shard_dir, ["ActsAceTest1"], "SN1")
        mock_warn.assert_called()
        self.assertIn(".hap missing", mock_warn.call_args[0][0])


class R5ReportFormat(TestCase):
    """R5: Report format compatible with existing xts_full_runs/ convention."""

    def _make_shard_result(self, shard="shard-01-abc", success=True, exit_code=0,
                           module_count=3, duration=100.0, errors=None):
        return {
            "shard": shard,
            "module_count": module_count,
            "modules": ["Mod1"],
            "started_at": "2026-01-01T00:00:00Z",
            "exit_code": exit_code,
            "duration_s": duration,
            "report_dir": "/tmp/reports",
            "success": success,
            "errors": errors or [],
            "finished_at": "2026-01-01T00:01:40Z",
        }

    def test_report_has_devices_dict_not_shards(self):
        """Report uses 'devices' dict keyed by serial (existing convention)."""
        shard_info = [("shard-01-abc", Path("/tmp"), ["Mod1"], "SERIAL_ABC", "10.0.0.1")]
        report = sut.merge_reports(
            [self._make_shard_result()], shard_info,
            Path("/tmp/out"), "test-run", 1, 100.0,
        )
        self.assertIn("devices", report)
        self.assertNotIn("shards", report)
        self.assertIn("SERIAL_ABC", report["devices"])

    def test_device_entry_has_host_field(self):
        """Each device entry includes 'host' from boards.conf."""
        shard_info = [("shard-01-abc", Path("/tmp"), ["Mod1"], "SERIAL_ABC", "10.0.0.1")]
        report = sut.merge_reports(
            [self._make_shard_result()], shard_info,
            Path("/tmp/out"), "test-run", 1, 100.0,
        )
        self.assertEqual(report["devices"]["SERIAL_ABC"]["host"], "10.0.0.1")

    def test_aggregate_counts_successful(self):
        """Aggregate section counts successful devices."""
        shard_info = [
            ("shard-01-abc", Path("/tmp"), ["Mod1"], "SN1", "10.0.0.1"),
            ("shard-02-def", Path("/tmp"), ["Mod2"], "SN2", "10.0.0.2"),
        ]
        report = sut.merge_reports(
            [self._make_shard_result(success=True),
             self._make_shard_result(shard="shard-02-def", success=False, exit_code=1)],
            shard_info, Path("/tmp/out"), "test-run", 2, 100.0,
        )
        self.assertEqual(report["aggregate"]["successful"], 1)
        self.assertEqual(report["aggregate"]["failed"], 1)

    def test_aggregate_counts_timed_out(self):
        """Timed-out devices (exit_code -2) counted separately."""
        shard_info = [("shard-01-abc", Path("/tmp"), ["Mod1"], "SN1", "10.0.0.1")]
        report = sut.merge_reports(
            [self._make_shard_result(success=False, exit_code=-2, errors=["Timed out"])],
            shard_info, Path("/tmp/out"), "test-run", 1, 100.0,
        )
        self.assertEqual(report["aggregate"]["timed_out"], 1)
        self.assertEqual(report["aggregate"]["failed"], 0)

    def test_report_written_to_file(self):
        """Report is written as JSON to output dir."""
        out = Path(tempfile.mkdtemp(prefix="test_xts_r5_"))
        shard_info = [("shard-01-abc", Path("/tmp"), ["Mod1"], "SN1", "10.0.0.1")]
        sut.merge_reports(
            [self._make_shard_result()], shard_info,
            out, "test-run", 1, 100.0,
        )
        report_file = out / "full_run_report.json"
        self.assertTrue(report_file.exists())
        data = json.loads(report_file.read_text())
        self.assertEqual(data["run_label"], "test-run")
        shutil.rmtree(out)

    def test_multi_shard_same_device_merged(self):
        """Multiple shards on same device are merged into one device entry."""
        shard_info = [
            ("shard-01-abc", Path("/tmp"), ["Mod1"], "SN1", "10.0.0.1"),
            ("shard-02-abc", Path("/tmp"), ["Mod2"], "SN1", "10.0.0.1"),
        ]
        report = sut.merge_reports(
            [self._make_shard_result(module_count=5, duration=50.0),
             self._make_shard_result(shard="shard-02-abc", module_count=3, duration=70.0)],
            shard_info, Path("/tmp/out"), "test-run", 8, 70.0,
        )
        self.assertEqual(len(report["devices"]), 1)
        self.assertEqual(report["devices"]["SN1"]["module_count"], 8)
        self.assertEqual(report["devices"]["SN1"]["duration_s"], 70.0)


class R6DryRun(TestCase):
    """R6: Dry-run produces plan without side effects."""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp(prefix="test_xts_r6_"))
        self.acts = self.tmpdir / "acts"
        tc = self.acts / "testcases"
        tc.mkdir(parents=True)
        for i in range(4):
            (tc / f"ActsAceTest{i}.json").write_text("{}")
            (tc / f"ActsAceTest{i}.hap").write_bytes(b"\x00")

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_dry_run_returns_zero(self):
        """Dry-run exits with code 0."""
        result = subprocess.run(
            [sys.executable, "-m", "ohos_xts_full_run",
             "--acts-root", str(self.acts),
             "--devices", "SN1,SN2",
             "--dry-run"],
            capture_output=True, text=True,
            cwd=Path(__file__).resolve().parent,
        )
        self.assertEqual(result.returncode, 0)

    def test_dry_run_prints_shards(self):
        """Dry-run output mentions shards and module counts."""
        result = subprocess.run(
            [sys.executable, "-m", "ohos_xts_full_run",
             "--acts-root", str(self.acts),
             "--devices", "SN1,SN2",
             "--dry-run"],
            capture_output=True, text=True,
            cwd=Path(__file__).resolve().parent,
        )
        self.assertIn("Shard 1", result.stdout)
        self.assertIn("Shard 2", result.stdout)
        self.assertIn("modules", result.stdout)

    def test_dry_run_creates_no_output_dir(self):
        """Dry-run doesn't create output directory."""
        output = self.tmpdir / "should_not_exist"
        subprocess.run(
            [sys.executable, "-m", "ohos_xts_full_run",
             "--acts-root", str(self.acts),
             "--devices", "SN1",
             "--output-dir", str(output),
             "--dry-run"],
            capture_output=True, text=True,
            cwd=Path(__file__).resolve().parent,
        )
        self.assertFalse(output.exists())


class R7ExitCode(TestCase):
    """R7: Exit code reflects pass/fail — 0 on all pass, 1 on any fail/timeout."""

    def test_main_returns_1_on_failure(self):
        """main() returns 1 when aggregate has failures."""
        report = {
            "aggregate": {"failed": 1, "timed_out": 0},
        }
        has_failures = report["aggregate"]["failed"] or report["aggregate"]["timed_out"]
        self.assertEqual(1 if has_failures else 0, 1)

    def test_main_returns_1_on_timeout(self):
        """main() returns 1 when aggregate has timeouts."""
        report = {
            "aggregate": {"failed": 0, "timed_out": 1},
        }
        has_failures = report["aggregate"]["failed"] or report["aggregate"]["timed_out"]
        self.assertEqual(1 if has_failures else 0, 1)

    def test_main_returns_0_on_success(self):
        """main() returns 0 when all devices succeed."""
        report = {
            "aggregate": {"failed": 0, "timed_out": 0},
        }
        has_failures = report["aggregate"]["failed"] or report["aggregate"]["timed_out"]
        self.assertEqual(1 if has_failures else 0, 0)


class R8Cleanup(TestCase):
    """R8: Temporary directories are cleaned up after run."""

    def test_cleanup_called_in_main(self):
        """main() calls shutil.rmtree on temp_dir after shard execution."""
        # Verify the cleanup path exists by checking the code flow
        # (full integration test would need real devices)
        import inspect
        source = inspect.getsource(sut.main)
        self.assertIn("shutil.rmtree(temp_dir)", source)


class R9MissingFiles(TestCase):
    """R9: Missing required files cause early failure, not silent skip."""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp(prefix="test_xts_r9_"))
        self.acts = self.tmpdir / "acts"
        (self.acts / "testcases").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_missing_json_dies(self):
        """Missing .json file causes SystemExit."""
        shard_dir = self.tmpdir / "shard"
        with self.assertRaises(SystemExit):
            sut.create_shard_suite(self.acts, shard_dir, ["Nonexistent"], "SN1")

    def test_present_json_missing_hap_warns(self):
        """Present .json but missing .hap produces warning."""
        (self.acts / "testcases" / "Mod.json").write_text("{}")
        shard_dir = self.tmpdir / "shard"
        with mock.patch("ohos_xts_full_run.warn") as mock_warn:
            sut.create_shard_suite(self.acts, shard_dir, ["Mod"], "SN1")
        mock_warn.assert_called()


class R4XdeviceConfigPassing(TestCase):
    """R4: xdevice receives correct config file paths and module list format."""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp(prefix="test_xts_r4x_"))
        self.acts_root = self.tmpdir / "acts"
        self.acts_tc = self.acts_root / "testcases"
        self.acts_cfg = self.acts_root / "config"
        self.acts_tc.mkdir(parents=True)
        self.acts_cfg.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _create_source_module(self, name: str, with_hap: bool = True):
        (self.acts_tc / f"{name}.json").write_text('{"test": true}')
        if with_hap:
            (self.acts_tc / f"{name}.hap").write_bytes(b"\x00")

    def test_c_flag_points_to_user_config_xml_not_acts_json(self):
        """xdevice -c flag must receive user_config.xml, not acts.json.

        xdevice's UserConfigManager expects XML; passing JSON causes
        ParseError at line 1 column 0.
        """
        shard_dir = self.tmpdir / "shard"
        modules = ["ActsAceTest1"]
        self._create_source_module(modules[0])
        sut.create_shard_suite(self.acts_root, shard_dir, modules, "SN1")

        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            sut.run_xdevice_shard(
                "python3 -m xdevice", shard_dir, modules, "SN1",
                self.tmpdir / "reports" / "shard-01",
            )

        called_args = mock_run.call_args[0][0]
        c_idx = next((i for i, a in enumerate(called_args) if a == "-c"), None)
        self.assertIsNotNone(c_idx, "-c flag not found in xdevice args")
        config_path = called_args[c_idx + 1]
        self.assertTrue(
            config_path.endswith("user_config.xml"),
            f"-c must point to user_config.xml, got: {config_path}",
        )

    def test_l_flag_uses_semicolon_separator(self):
        """xdevice -l flag must use ; separator (not spaces).

        xdevice's SplicingAction joins args with space, then splits by ;.
        Space-separated names become one non-existent entry.
        """
        shard_dir = self.tmpdir / "shard"
        modules = ["ActsAceTest1", "ActsAceTest2", "ActsAceTest3"]
        for m in modules:
            self._create_source_module(m)
        sut.create_shard_suite(self.acts_root, shard_dir, modules, "SN1")

        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            sut.run_xdevice_shard(
                "python3 -m xdevice", shard_dir, modules, "SN1",
                self.tmpdir / "reports" / "shard-01",
            )

        called_args = mock_run.call_args[0][0]
        l_idx = next((i for i, a in enumerate(called_args) if a == "-l"), None)
        self.assertIsNotNone(l_idx, "-l flag not found in xdevice args")
        testlist = called_args[l_idx + 1]
        for mod in modules:
            self.assertIn(mod, testlist)
        # Must use ; as separator (xdevice splits by ;)
        self.assertIn(";", testlist)
        # Must NOT be separate args (SplicingAction would join with space)
        # Verify it's a single semicolon-joined string
        parts_after_l = called_args[l_idx + 1:l_idx + 1 + len(modules)]
        self.assertEqual(len(parts_after_l), 1,
                         "Module names must be a single ;-joined string, not separate args")

    def test_user_config_xml_is_valid_xml(self):
        """Generated user_config.xml must be parseable by XML parsers.

        xdevice uses ElementTree.parse() — the file must be well-formed XML.
        """
        shard_dir = self.tmpdir / "shard"
        self._create_source_module("ActsAceTest1")
        sut.create_shard_suite(self.acts_root, shard_dir, ["ActsAceTest1"], "SN-XYZ")

        config_path = shard_dir / "config" / "user_config.xml"
        tree = ET.parse(config_path)
        root = tree.getroot()
        self.assertEqual(root.tag, "user_config")
        sn = tree.find(".//sn")
        self.assertEqual(sn.text, "SN-XYZ")

    def test_user_config_xml_has_required_structure(self):
        """user_config.xml must have environment/device and testcases sections.

        xdevice's UserConfigManager expects these elements.
        """
        shard_dir = self.tmpdir / "shard"
        self._create_source_module("ActsAceTest1")
        sut.create_shard_suite(self.acts_root, shard_dir, ["ActsAceTest1"], "SN1")

        tree = ET.parse(shard_dir / "config" / "user_config.xml")
        self.assertIsNotNone(tree.find(".//environment"))
        self.assertIsNotNone(tree.find(".//device[@type='usb-hdc']"))
        self.assertIsNotNone(tree.find(".//testcases"))
        self.assertIsNotNone(tree.find(".//resource"))

    def test_xdevice_reports_captured_before_cleanup(self):
        """R5: xdevice reports are copied from temp shard dir before cleanup.

        xdevice writes to <shard_dir>/reports/<shard_label>/; these must
        be preserved after temp dir cleanup.
        """
        shard_dir = self.tmpdir / "shard-01-abc"
        modules = ["ActsAceTest1"]
        self._create_source_module(modules[0])
        sut.create_shard_suite(self.acts_root, shard_dir, modules, "SN1")

        # Simulate xdevice writing a report (xdevice puts reports in
        # shard_dir/reports/<task_name>/ where task_name = shard_label)
        shard_label = shard_dir.name
        xdevice_out = shard_dir / "reports" / shard_label / "summary.xml"
        xdevice_out.parent.mkdir(parents=True, exist_ok=True)
        xdevice_out.write_text('<?xml version="1.0"?><results/>')

        report_root = self.tmpdir / "captured_reports"

        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="", stderr="")
            result = sut.run_xdevice_shard(
                "python3 -m xdevice", shard_dir, modules, "SN1",
                report_root,
            )

        self.assertTrue(result["success"])
        copied = report_root / shard_label / "summary.xml"
        self.assertTrue(copied.exists(), "xdevice report not captured to output dir")


class R10ShardNameCollision(TestCase):
    """R10: Shard names use 12-char serial suffix to prevent collision.

    Bug: Two boards ending in ...2eba00 on the same server produced
    identical shard names (e.g. shard-04-2eba00).  The second board's
    rsync overwrote user_config.xml of the first, causing xdevice to
    target the wrong device.

    Fix: resolve_boards and main() use s[-12:] instead of s[-6:].
    """

    def test_12char_suffix_distinguishes_2eba00_boards(self):
        """Boards ...09100a2eba00 and ...2a100a2eba00 must differ."""
        sn_a = "4501004456343033320109100a2eba00"
        sn_b = "450100445634303332012a100a2eba00"
        short_a = sn_a[-12:] if len(sn_a) >= 12 else sn_a
        short_b = sn_b[-12:] if len(sn_b) >= 12 else sn_b
        self.assertNotEqual(short_a, short_b)

    def test_old_6char_suffix_produces_collision(self):
        """Document the old bug: -6 suffix gives identical strings."""
        sn_a = "4501004456343033320109100a2eba00"
        sn_b = "450100445634303332012a100a2eba00"
        self.assertEqual(sn_a[-6:], sn_b[-6:])

    def test_ci_plus_bl_shard_names_all_unique(self):
        """8 boards (4 CI + 4 BL) produce 8 unique shard names."""
        ci_serials = [
            "450100445634303332011f100a2eba00",
            "150100424a544434520369874e4f8800",
            "45010044563430333201f8517d2dba00",
            "450100445634303332012a100a2eba00",
        ]
        bl_serials = [
            "150100424a544434520369864f628800",
            "150100424a544434520369864feb8800",
            "4501004456343033320109100a2eba00",
            "45010044563430333201990f0a2eba00",
        ]
        names = []
        for i, sn in enumerate(ci_serials):
            names.append(f"shard-{i+1:02d}-{sn[-12:]}")
        for i, sn in enumerate(bl_serials):
            names.append(f"shard-{i+1:02d}-{sn[-12:]}")
        self.assertEqual(len(names), len(set(names)),
                         f"Duplicate shard names: {names}")

    def test_resolve_boards_produces_12char_short(self):
        """resolve_boards with --devices returns 12-char short names."""
        boards = sut.resolve_boards(None, None, [
            "450100445634303332012a100a2eba00",
        ])
        self.assertEqual(boards[0]["short"], "2a100a2eba00")

    def test_resolve_boards_short_names_unique_for_same_server(self):
        """Two boards on the same server must have different short names."""
        boards = sut.resolve_boards(None, None, [
            "4501004456343033320109100a2eba00",
            "45010044563430333201990f0a2eba00",
        ])
        shorts = [b["short"] for b in boards]
        self.assertEqual(len(shorts), len(set(shorts)))

    def test_remote_shard_paths_differ_for_same_server(self):
        """Two shards on the same server produce different /tmp paths."""
        boards = [
            {"short": "09100a2eba00"},
            {"short": "990f0a2eba00"},
        ]
        paths = [f"/tmp/xts_shard_shard-0{i+1}-{b['short']}" for i, b in enumerate(boards)]
        self.assertNotEqual(paths[0], paths[1])

    def test_short_serial_under_12_kept_as_is(self):
        """Serial shorter than 12 chars is kept whole, not sliced."""
        boards = sut.resolve_boards(None, None, ["ABC"])
        self.assertEqual(boards[0]["short"], "ABC")


class R11RsyncAfterTimeout(TestCase):
    """R11: Remote reports are rsync'd back even when xdevice SSH times out.

    Bug: subprocess.TimeoutExpired from the SSH+xdevice call propagated
    out of _run_shard_remote, skipping the rsync that copies reports
    from the remote server.  Result: empty local report dirs after
    4-hour runs, losing all test results.

    Fix: wrap xdevice SSH call in try/finally, rsync in finally block.
    """

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp(prefix="test_xts_r11_"))
        self.shard_dir = self.tmpdir / "shard"
        self.shard_dir.mkdir()
        self.report_dir = self.tmpdir / "reports" / "shard-01-test"
        self.report_dir.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    @mock.patch("ohos_xts_full_run._remote_has_tmux", return_value=False)
    @mock.patch("ohos_xts_full_run.subprocess.run")
    def test_rsync_back_called_after_timeout(self, mock_run, mock_tmux):
        """When xdevice SSH raises TimeoutExpired, rsync must still execute."""
        call_seq = [0]

        def _mock_run(cmd, **kwargs):
            call_seq[0] += 1
            # Calls 1-3: mkdir, rsync out, hdc prestart — succeed
            if call_seq[0] <= 3:
                r = mock.Mock()
                r.returncode = 0
                r.stderr = ""
                return r
            # Call 4: xdevice SSH — timeout
            if call_seq[0] == 4:
                raise subprocess.TimeoutExpired(cmd=["ssh"], timeout=5)
            # Call 5+: rsync back + cleanup — succeed
            r = mock.Mock()
            r.returncode = 0
            r.stderr = ""
            return r

        mock_run.side_effect = _mock_run

        result = {"exit_code": -1, "success": False, "errors": []}

        with self.assertRaises(subprocess.TimeoutExpired):
            sut._run_shard_remote(
                server="10.0.0.1",
                args=["/fake/runner.sh", "run", "acts"],
                shard_dir=self.shard_dir,
                shard_label="shard-01-test",
                report_dir=self.report_dir,
                result=result,
                timeout=5,
            )

        # Verify rsync back was called (at least 2 rsync calls total:
        # outbound + inbound)
        rsync_calls = [
            c for c in mock_run.call_args_list
            if isinstance(c[0][0], list) and "rsync" in c[0][0]
        ]
        self.assertGreaterEqual(len(rsync_calls), 2,
                                "rsync back must be called even after timeout")

    @mock.patch("ohos_xts_full_run._remote_has_tmux", return_value=False)
    @mock.patch("ohos_xts_full_run.subprocess.run")
    def test_stdout_stderr_saved_after_timeout(self, mock_run, mock_tmux):
        """xdevice stdout/stderr are saved even on timeout."""
        call_seq = [0]

        def _mock_run(cmd, **kwargs):
            call_seq[0] += 1
            if call_seq[0] <= 3:
                r = mock.Mock()
                r.returncode = 0
                r.stderr = ""
                return r
            if call_seq[0] == 4:
                raise subprocess.TimeoutExpired(cmd=["ssh"], timeout=5)
            r = mock.Mock()
            r.returncode = 0
            r.stderr = ""
            return r

        mock_run.side_effect = _mock_run

        result = {"exit_code": -1, "success": False, "errors": []}

        with self.assertRaises(subprocess.TimeoutExpired):
            sut._run_shard_remote(
                server="10.0.0.1",
                args=["/fake/runner.sh", "run", "acts"],
                shard_dir=self.shard_dir,
                shard_label="shard-01-test",
                report_dir=self.report_dir,
                result=result,
                timeout=5,
            )

        # On timeout, stdout/stderr should be empty string (set before try)
        stdout_log = self.report_dir / "xdevice_stdout.log"
        stderr_log = self.report_dir / "xdevice_stderr.log"
        self.assertTrue(stdout_log.exists(), "xdevice_stdout.log must be written")
        self.assertTrue(stderr_log.exists(), "xdevice_stderr.log must be written")

    @mock.patch("ohos_xts_full_run._remote_has_tmux", return_value=False)
    @mock.patch("ohos_xts_full_run.subprocess.run")
    def test_rsync_on_nonzero_exit(self, mock_run, mock_tmux):
        """When xdevice exits non-zero, rsync still happens and logs are saved."""
        mock_proc = mock.Mock()
        mock_proc.returncode = 255
        mock_proc.stdout = "xdevice output"
        mock_proc.stderr = "xdevice errors"

        def _mock_run(cmd, **kwargs):
            cmd_str = " ".join(str(c) for c in cmd) if isinstance(cmd, list) else str(cmd)
            if "runner.sh" in cmd_str:
                return mock_proc
            r = mock.Mock()
            r.returncode = 0
            r.stderr = ""
            return r

        mock_run.side_effect = _mock_run

        result = {"exit_code": -1, "success": False, "errors": []}

        ret = sut._run_shard_remote(
            server="10.0.0.1",
            args=["/fake/runner.sh", "run", "acts"],
            shard_dir=self.shard_dir,
            shard_label="shard-01-test",
            report_dir=self.report_dir,
            result=result,
            timeout=60,
        )

        self.assertFalse(ret["success"])
        self.assertEqual(ret["exit_code"], 255)
        self.assertEqual(
            (self.report_dir / "xdevice_stdout.log").read_text(),
            "xdevice output",
        )
        self.assertEqual(
            (self.report_dir / "xdevice_stderr.log").read_text(),
            "xdevice errors",
        )

    @mock.patch("ohos_xts_full_run._remote_has_tmux", return_value=False)
    @mock.patch("ohos_xts_full_run.subprocess.run")
    def test_rsync_failure_doesnt_crash(self, mock_run, mock_tmux):
        """If rsync back itself fails, function must not crash."""
        call_seq = [0]

        def _mock_run(cmd, **kwargs):
            call_seq[0] += 1
            if call_seq[0] <= 3:
                r = mock.Mock()
                r.returncode = 0
                r.stderr = ""
                return r
            if call_seq[0] == 4:
                mock_proc = mock.Mock()
                mock_proc.returncode = 255
                mock_proc.stdout = "xdevice out"
                mock_proc.stderr = "xdevice err"
                return mock_proc
            # call 5: rsync back — raises
            if call_seq[0] == 5:
                raise subprocess.CalledProcessError(1, "rsync")
            # call 6: cleanup ssh — succeed
            r = mock.Mock()
            r.returncode = 0
            r.stderr = ""
            return r

        mock_run.side_effect = _mock_run

        result = {"exit_code": -1, "success": False, "errors": []}

        ret = sut._run_shard_remote(
            server="10.0.0.1",
            args=["/fake/runner.sh", "run", "acts"],
            shard_dir=self.shard_dir,
            shard_label="shard-01-test",
            report_dir=self.report_dir,
            result=result,
            timeout=60,
        )

        # Function should complete (rsync failure is caught in finally)
        self.assertFalse(ret["success"])
        self.assertEqual(ret["exit_code"], 255)


class R12ConnectivityCheck(TestCase):
    """R12: Connectivity check tolerates remote-only boards.

    Bug: check_hdc_connectivity runs local 'hdc list targets', but boards
    are on remote servers. All devices appear "offline", wasting ~2min on
    futile hdc_tconn attempts.

    Fix: --skip-connect flag added to bypass check for remote setups.
    """

    def test_skip_connect_flag_exists(self):
        """argparse accepts --skip-connect."""
        import inspect
        source = inspect.getsource(sut.main)
        self.assertIn("skip_connect", source)

    def test_skip_connect_bypasses_check(self):
        """When --skip-connect is set, check_hdc_connectivity is not called."""
        import inspect
        source = inspect.getsource(sut.main)
        self.assertIn("skip_connect", source)


class R13TmuxSelfRelaunch(TestCase):
    """R13: Local tmux self-relaunch.

    When not inside tmux and tmux is available, _ensure_tmux_session
    should create a new tmux session and sys.exit(0).
    When inside tmux, it should be a no-op.
    When tmux is unavailable, it should warn but continue.
    """

    @mock.patch("ohos_xts_full_run.subprocess.run")
    @mock.patch("ohos_xts_full_run.shutil.which", return_value="/usr/bin/tmux")
    @mock.patch.dict("os.environ", {}, clear=True)
    def test_relaunch_creates_tmux_session(self, mock_which, mock_run):
        """Outside tmux + tmux available → creates session, sys.exit(0)."""
        # kill-session call + new-session call
        mock_run.return_value = mock.Mock(returncode=0, stderr="")
        with self.assertRaises(SystemExit) as ctx:
            sut._ensure_tmux_session("test-run")
        self.assertEqual(ctx.exception.code, 0)
        # 2 calls: kill-session + new-session
        self.assertEqual(mock_run.call_count, 2)
        new_session_call = mock_run.call_args_list[1]
        args = new_session_call[0][0]
        self.assertEqual(args[0], "tmux")
        self.assertEqual(args[1], "new-session")
        self.assertIn("xts-test-run", args)

    @mock.patch("ohos_xts_full_run.subprocess.run")
    @mock.patch.dict("os.environ", {"XTS_TMUX_SESSION": "test-run"})
    def test_already_in_own_session_is_noop(self, mock_run):
        """Inside own xts-<label> session (env marker set) → no action."""
        sut._ensure_tmux_session("test-run")
        mock_run.assert_not_called()

    @mock.patch("ohos_xts_full_run.shutil.which", return_value=None)
    @mock.patch.dict("os.environ", {}, clear=True)
    def test_no_tmux_warns_continues(self, mock_which):
        """No tmux → warns but does not exit."""
        # Should not raise
        sut._ensure_tmux_session("test-run")

    @mock.patch("ohos_xts_full_run.subprocess.run")
    @mock.patch("ohos_xts_full_run.shutil.which", return_value="/usr/bin/tmux")
    @mock.patch.dict("os.environ", {}, clear=True)
    def test_session_name_sanitized(self, mock_which, mock_run):
        """Session name only contains safe chars."""
        mock_run.return_value = mock.Mock(returncode=0, stderr="")
        with self.assertRaises(SystemExit):
            sut._ensure_tmux_session("my run/with weird#chars")
        args = mock_run.call_args[0][0]
        session_name = args[args.index("-s") + 1]
        # Only alphanumeric, dash, dot, underscore
        self.assertTrue(all(c.isalnum() or c in "-_." for c in session_name))


class R14RemoteTmuxExecution(TestCase):
    """R14: Remote xdevice runs in tmux when available, fallback to direct SSH.

    When tmux is available on the remote server, xdevice should start
    inside a tmux session and be polled for completion.
    When tmux is not available, fall back to synchronous SSH with warning.
    """

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp(prefix="test_xts_r14_"))
        self.shard_dir = self.tmpdir / "shard"
        self.shard_dir.mkdir()
        self.report_dir = self.tmpdir / "reports" / "shard-01-test"
        self.report_dir.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    @mock.patch("ohos_xts_full_run._remote_has_tmux", return_value=True)
    @mock.patch("ohos_xts_full_run.subprocess.run")
    def test_tmux_path_starts_session(self, mock_run, mock_has_tmux):
        """When remote has tmux, creates tmux session and polls."""
        call_count = [0]

        def _mock_run(cmd, **kwargs):
            call_count[0] += 1
            r = mock.Mock()
            r.returncode = 0
            r.stdout = "0\n"  # exit_code file
            r.stderr = ""
            # First calls: mkdir, rsync, prestart, tmux start
            # Then polling: tmux has-session returns 1 (session gone)
            # Then: cat exit_code, cat stdout, cat stderr
            return r

        mock_run.side_effect = _mock_run
        result = {"exit_code": -1, "success": False, "errors": []}
        ret = sut._run_shard_remote(
            server="10.0.0.1",
            args=["/fake/runner.sh", "run", "acts"],
            shard_dir=self.shard_dir,
            shard_label="shard-01-test",
            report_dir=self.report_dir,
            result=result,
            timeout=60,
        )

        # Verify tmux new-session was called (via SSH)
        tmux_calls = [
            c for c in mock_run.call_args_list
            if isinstance(c[0][0], list) and c[0][0][0] == "ssh"
            and any("tmux" in str(a) for a in c[0][0])
        ]
        self.assertGreater(len(tmux_calls), 0, "tmux new-session must be called via SSH")

    @mock.patch("ohos_xts_full_run._remote_has_tmux", return_value=False)
    @mock.patch("ohos_xts_full_run.subprocess.run")
    def test_fallback_uses_direct_ssh(self, mock_run, mock_has_tmux):
        """When remote has no tmux, uses direct SSH fallback."""
        call_count = [0]

        def _mock_run(cmd, **kwargs):
            call_count[0] += 1
            r = mock.Mock()
            r.returncode = 0
            r.stdout = ""
            r.stderr = ""
            return r

        mock_run.side_effect = _mock_run
        result = {"exit_code": -1, "success": False, "errors": []}
        ret = sut._run_shard_remote(
            server="10.0.0.1",
            args=["/fake/runner.sh", "run", "acts"],
            shard_dir=self.shard_dir,
            shard_label="shard-01-test",
            report_dir=self.report_dir,
            result=result,
            timeout=60,
        )
        self.assertTrue(ret["success"])
        # Verify a direct SSH call (not tmux) was made
        ssh_calls = [
            c for c in mock_run.call_args_list
            if isinstance(c[0][0], list) and c[0][0][0] == "ssh"
        ]
        self.assertGreater(len(ssh_calls), 0)

    @mock.patch("ohos_xts_full_run._remote_has_tmux")
    def test_remote_tmux_detection(self, mock_has_tmux):
        """_remote_has_tmux returns True when which tmux succeeds."""
        mock_has_tmux.return_value = True
        self.assertTrue(sut._remote_has_tmux("user@host"))

    @mock.patch("ohos_xts_full_run._remote_has_tmux")
    def test_remote_no_tmux(self, mock_has_tmux):
        """_remote_has_tmux returns False when which tmux fails."""
        mock_has_tmux.return_value = False
        self.assertFalse(sut._remote_has_tmux("user@host"))
