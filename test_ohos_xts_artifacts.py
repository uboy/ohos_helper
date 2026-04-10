import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import ohos_xts_artifacts


class _FakePrepared:
    def __init__(self, payload):
        self._payload = payload

    def to_dict(self):
        return dict(self._payload)


class OhosXtsArtifactsTests(unittest.TestCase):
    def test_download_sdk_writes_report(self):
        with tempfile.TemporaryDirectory() as tempdir:
            json_path = Path(tempdir) / "report.json"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                with mock.patch.object(
                    ohos_xts_artifacts,
                    "prepare_sdk_from_args",
                    return_value=_FakePrepared(
                        {
                            "status": "ready",
                            "tag": "20260410_120125",
                            "component": "ohos-sdk-public",
                            "role": "sdk",
                            "package_kind": "full",
                            "archive_path": "/tmp/sdk.tar.gz",
                            "extracted_root": "/tmp/sdk",
                            "primary_root": "/tmp/sdk/interface/sdk-js/api",
                        }
                    ),
                ):
                    rc = ohos_xts_artifacts.main(
                        [
                            "download",
                            "sdk",
                            "--sdk-build-tag",
                            "20260410_120125",
                            "--json-out",
                            str(json_path),
                        ]
                    )

            self.assertEqual(rc, 0)
            self.assertIn("download_daily_sdk: ready", stdout.getvalue())
            payload = json.loads(json_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["operations"]["download_daily_sdk"]["tag"], "20260410_120125")

    def test_flash_local_passes_paths_to_flash_image_bundle(self):
        flash_result = mock.Mock()
        flash_result.status = "completed"
        flash_result.to_dict.return_value = {
            "status": "completed",
            "image_root": "/tmp/image_bundle",
            "flash_py_path": "/tmp/flash.py",
            "flash_tool_path": "/tmp/bin/flash.x86_64",
            "hdc_path": "/tmp/hdc",
            "device": "",
            "loader_device": {},
            "command": ["flash"],
            "returncode": 0,
            "output_tail": "",
        }
        with tempfile.TemporaryDirectory() as tempdir:
            json_path = Path(tempdir) / "report.json"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                with mock.patch.object(
                    ohos_xts_artifacts,
                    "resolve_local_firmware_root",
                    return_value=Path("/tmp/image_bundle"),
                ), mock.patch.object(
                    ohos_xts_artifacts,
                    "flash_image_bundle",
                    return_value=flash_result,
                ) as flash_mock:
                    rc = ohos_xts_artifacts.main(
                        [
                            "flash",
                            "--flash-firmware-path",
                            "/tmp/requested_bundle",
                            "--flash-py-path",
                            "/tmp/flash.py",
                            "--hdc-path",
                            "/tmp/hdc",
                            "--json-out",
                            str(json_path),
                        ]
                    )

            self.assertEqual(rc, 0)
            flash_mock.assert_called_once()
            self.assertEqual(flash_mock.call_args.kwargs["image_root"], Path("/tmp/image_bundle"))
            self.assertEqual(flash_mock.call_args.kwargs["flash_py_path"], "/tmp/flash.py")
            self.assertEqual(flash_mock.call_args.kwargs["hdc_path"], "/tmp/hdc")
            payload = json.loads(json_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["operations"]["flash_local_firmware"]["requested_path"], "/tmp/requested_bundle")
            self.assertIn("flash_local_firmware: completed", stdout.getvalue())

    def test_list_tags_uses_selected_component_defaults(self):
        stdout = io.StringIO()
        builds = [
            mock.Mock(tag="20260410_120338", version_name="OpenHarmony_7.0.0.20", hardware_board="dayu200"),
            mock.Mock(tag="20260409_120338", version_name="", hardware_board=""),
        ]
        with contextlib.redirect_stdout(stdout):
            with mock.patch.object(ohos_xts_artifacts, "list_daily_tags", return_value=builds) as list_mock:
                rc = ohos_xts_artifacts.main(["list-tags", "firmware", "--list-tags-count", "2"])

        self.assertEqual(rc, 0)
        list_mock.assert_called_once()
        self.assertEqual(list_mock.call_args.kwargs["component"], ohos_xts_artifacts.DEFAULT_FIRMWARE_COMPONENT)
        self.assertIn("20260410_120338", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
