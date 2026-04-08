import importlib.util
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
