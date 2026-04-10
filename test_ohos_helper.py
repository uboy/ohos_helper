import json
import importlib.util
import io
import os
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory


HELPER_PATH = Path("/data/shared/common/scripts/ohos-helper.py")
SPEC = importlib.util.spec_from_file_location("ohos_helper", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
ohos_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ohos_helper)


class ArtifactInferenceTests(unittest.TestCase):
    def test_infer_direct_shared_library_artifact(self):
        entry = {
            "name": "arkts_frontend",
            "output_name": "",
            "label": "//foundation/arkui/ace_engine/frameworks/bridge/arkts_frontend:arkts_frontend",
            "type": "ohos_shared_library",
            "artifact_output_names": [],
            "install_dir_occurrences": [],
        }

        artifacts = ohos_helper.infer_direct_entry_artifacts(
            entry,
            confidence="direct",
            reason="test",
        )

        self.assertEqual(artifacts[0]["name"], "libarkts_frontend.z.so")
        self.assertEqual(artifacts[0]["kind"], "shared_library")

    def test_infer_generated_outputs_from_output_fields(self):
        entry = {
            "name": "arcbutton_abc",
            "output_name": "",
            "label": "//foundation/arkui/ace_engine/advanced_ui_component/arcbutton/interfaces:arcbutton_abc",
            "type": "gen_js_obj",
            "artifact_output_names": ["arcbutton.abc", "arcbutton_abc.o"],
            "install_dir_occurrences": [],
        }

        artifacts = ohos_helper.infer_direct_entry_artifacts(
            entry,
            confidence="inferred",
            reason="test",
        )

        self.assertEqual([item["name"] for item in artifacts], ["arcbutton.abc", "arcbutton_abc.o"])

    def test_component_fallback_for_ace_ng_file(self):
        artifacts = ohos_helper.infer_component_fallback_artifacts(
            "/home/dmazur/proj/ohos_master/foundation/arkui/ace_engine/frameworks/core/components_ng/animation/geometry_transition.cpp",
            "/home/dmazur/proj/ohos_master",
            "ace_engine",
        )

        self.assertEqual(artifacts[0]["name"], "libace_compatible.z.so")
        self.assertEqual(artifacts[0]["confidence"], "fallback")

    def test_collect_file_artifacts_includes_build_ninja_outputs(self):
        with TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            source_path = repo_root / "foundation/arkui/ace_engine/frameworks/core/components_ng/pattern/button/button_pattern.cpp"
            source_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_text("// source\n", encoding="utf-8")
            out_dir = repo_root / "out" / "rk3568"
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / "build.ninja").write_text(
                "build lib.unstripped/libbutton.z.so: cxx ../../foundation/arkui/ace_engine/frameworks/core/components_ng/pattern/button/button_pattern.cpp\n",
                encoding="utf-8",
            )

            artifacts = ohos_helper.collect_file_artifacts(
                str(source_path),
                str(repo_root),
                "",
                [],
                [],
                [],
            )

        self.assertTrue(any(item["name"] == "libbutton.z.so" for item in artifacts))
        built_artifact = next(item for item in artifacts if item["name"] == "libbutton.z.so")
        self.assertEqual(built_artifact["confidence"], "built")
        self.assertTrue(any(path.endswith("libbutton.z.so") for path in built_artifact["observed_paths"]))

    def test_collect_file_artifacts_includes_module_info_outputs(self):
        with TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            source_path = repo_root / "foundation/arkui/ace_engine/frameworks/core/components_ng/pattern/button/button_pattern.cpp"
            source_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_text("// source\n", encoding="utf-8")
            out_dir = repo_root / "out" / "rk3568"
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / "module_info.json").write_text(
                json.dumps(
                    {
                        "button_module": {
                            "label": "//foundation/arkui/ace_engine:button_module",
                            "sources": [
                                "foundation/arkui/ace_engine/frameworks/core/components_ng/pattern/button/button_pattern.cpp"
                            ],
                            "module_path": "out/rk3568/lib.unstripped/libbutton_module.z.so",
                        }
                    },
                    indent=2,
                ),
                encoding="utf-8",
            )

            artifacts = ohos_helper.collect_file_artifacts(
                str(source_path),
                str(repo_root),
                "",
                [],
                [],
                [],
            )

        self.assertTrue(any(item["name"] == "libbutton_module.z.so" for item in artifacts))
        built_artifact = next(item for item in artifacts if item["name"] == "libbutton_module.z.so")
        self.assertEqual(built_artifact["confidence"], "built")
        self.assertEqual(built_artifact["owner_label"], "//foundation/arkui/ace_engine:button_module")

    def test_collect_file_artifacts_includes_matching_testcase_hap(self):
        with TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            source_path = repo_root / "test/xts/acts/arkui/ace_ets_module_advancedComponents/ace_ets_module_advance_chip_static/entry/src/main/ets/MainAbility/pages/ChipGroup/ChipGroupItemOptionsPage.ets"
            source_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_text("// source\n", encoding="utf-8")
            testcase_dir = repo_root / "out" / "release" / "suites" / "acts" / "testcases"
            testcase_dir.mkdir(parents=True, exist_ok=True)
            (testcase_dir / "ActsAceEtsModuleAdvanceChipStaticTest.json").write_text(
                json.dumps(
                    {
                        "driver": {
                            "type": "OHJSUnitTest",
                            "bundle-name": "com.arkui.ace.advance.chip.static",
                            "module-name": "entry",
                        },
                        "kits": [
                            {
                                "type": "AppInstallKit",
                                "test-file-name": ["ActsAceEtsModuleAdvanceChipStaticTest.hap"],
                            }
                        ],
                    },
                    indent=2,
                ),
                encoding="utf-8",
            )
            entry = {
                "name": "ace_ets_module_advance_chip_static",
                "output_name": "",
                "label": "//test/xts/acts/arkui:ace_ets_module_advance_chip_static",
                "type": "group",
                "artifact_output_names": [],
                "install_dir_occurrences": [],
            }

            artifacts = ohos_helper.collect_file_artifacts(
                str(source_path),
                str(repo_root),
                "",
                [entry],
                [entry],
                [],
            )

        self.assertTrue(any(item["name"] == "ActsAceEtsModuleAdvanceChipStaticTest.hap" for item in artifacts))
        hap_artifact = next(item for item in artifacts if item["name"] == "ActsAceEtsModuleAdvanceChipStaticTest.hap")
        self.assertEqual(hap_artifact["kind"], "hap_package")
        self.assertEqual(hap_artifact["confidence"], "built")

    def test_generated_wrapper_note_for_file(self):
        note = ohos_helper.generated_wrapper_note_for_file(
            "/repo/foundation/arkui/ace_engine/advanced_ui_component_static/assembled_advanced_ui_component/@ohos.arkui.advanced.ChipGroup.ets",
            "/repo",
        )

        self.assertIn("generated assembled advanced UI ETS wrapper", note)
        self.assertIn("advanced_ui_component/chipgroup/source/chipgroup.ets", note)

    def test_artifact_search_summary_lines_report_available_layers(self):
        with TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            source_path = repo_root / "foundation/arkui/ace_engine/frameworks/core/components_ng/pattern/button/button_pattern.cpp"
            source_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_text("// source\n", encoding="utf-8")
            out_dir = repo_root / "out" / "rk3568"
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / "module_info.json").write_text("{}", encoding="utf-8")
            (out_dir / "build.ninja").write_text("", encoding="utf-8")
            testcase_dir = repo_root / "out" / "release" / "suites" / "acts" / "testcases"
            testcase_dir.mkdir(parents=True, exist_ok=True)
            (testcase_dir / "ActsExample.json").write_text("{}", encoding="utf-8")

            lines = ohos_helper.artifact_search_summary_lines(str(source_path), str(repo_root), "ace_engine")

        text = "\n".join(lines)
        self.assertIn("module_info.json): available", text)
        self.assertIn("testcase metadata", text)
        self.assertIn("build outputs (out/*/build.ninja): available", text)
        self.assertIn("Artifact types considered:", text)

    def test_show_file_info_prints_artifact_search_summary(self):
        with TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            (repo_root / ".repo").mkdir()
            (repo_root / "build").mkdir()
            (repo_root / "build" / "prebuilts_download.sh").write_text("", encoding="utf-8")
            source_path = repo_root / "foundation/arkui/ace_engine/advanced_ui_component_static/assembled_advanced_ui_component/@ohos.arkui.advanced.ChipGroup.ets"
            source_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_text("// source\n", encoding="utf-8")
            output = io.StringIO()
            cwd_before = os.getcwd()
            try:
                os.chdir(repo_root)
                with redirect_stdout(output):
                    rc = ohos_helper.show_file_info(str(source_path), str(repo_root))
            finally:
                os.chdir(cwd_before)

        rendered = output.getvalue()
        self.assertEqual(rc, 0)
        self.assertIn("Generated Wrapper Note:", rendered)
        self.assertIn("Artifact Search Summary:", rendered)
        self.assertIn("Artifact types considered:", rendered)


if __name__ == "__main__":
    unittest.main()
