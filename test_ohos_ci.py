"""Tests for ohos_ci_tool.py — CI build info and artifact download."""

import unittest
from pathlib import Path
from unittest.mock import patch

# Ensure the repo root is on sys.path
_REPO_ROOT = Path(__file__).resolve().parent
import sys
sys.path.insert(0, str(_REPO_ROOT))

from ohos_ci_tool import extract_build_info, make_choice_menu

SAMPLE_HTML = """<html>
<body>
<table>
<tr><td>dayu200</td><td>success</td><td><a href="https://cidownload.openharmony.cn/Artifacts/dayu200/20260518-1-01277/log/build.log">build.log</a></td><td><a href="https://cidownload.openharmony.cn/Artifacts/dayu200/20260518-1-01277/version/Artifacts-dayu200-20260518-1-01277.tar.gz">Artifact</a></td></tr>
<tr><td>ohos-sdk</td><td>success</td><td><a href="https://cidownload.openharmony.cn/Artifacts/ohos-sdk/20260518-1-01277/log/build.log">build.log</a></td><td><a href="https://cidownload.openharmony.cn/Artifacts/ohos-sdk/20260518-1-01277/version/Artifacts-sdk-20260518-1-01277.tar.gz">Artifact</a></td></tr>
<tr><td>dayu200_xts_static</td><td>failed(compile failed)</td><td><a href="https://cidownload.openharmony.cn/Artifacts/dayu200_xts_static/20260518-1-01277/log/build.log">build.log</a></td><td></td></tr>
</table>
<a href="https://dcp.openharmony.cn/workbench/cicd/detail/abc123/runlist">DCP Dashboard</a>
</body>
</html>"""

SAMPLE_HTML_NO_CI = """<html><body><p>Just a comment</p></body></html>"""


class TestExtractBuildInfo(unittest.TestCase):

    def test_extracts_all_targets(self):
        builds = extract_build_info(SAMPLE_HTML)
        self.assertEqual(len(builds), 3, f"Expected 3 builds, got {len(builds)}: "
                         f"{[b['target'] for b in builds]}")

    def test_extracts_target_names(self):
        builds = extract_build_info(SAMPLE_HTML)
        targets = {b["target"] for b in builds}
        self.assertIn("dayu200", targets)
        self.assertIn("ohos-sdk", targets)
        self.assertIn("dayu200_xts_static", targets)

    def test_extracts_status(self):
        builds = extract_build_info(SAMPLE_HTML)
        statuses = {b["target"]: b["status"] for b in builds}
        self.assertEqual(statuses["dayu200"], "success")
        self.assertEqual(statuses["dayu200_xts_static"], "failed(compile failed)")

    def test_extracts_log_urls(self):
        builds = extract_build_info(SAMPLE_HTML)
        urls = {b["target"]: b["log_url"] for b in builds}
        self.assertIn("build.log", urls["dayu200"])
        self.assertIn("https://", urls["dayu200_xts_static"])

    def test_extracts_artifact_urls(self):
        builds = extract_build_info(SAMPLE_HTML)
        urls = {b["target"]: b["artifact_url"] for b in builds}
        self.assertIn("tar.gz", urls["dayu200"])
        self.assertIn("tar.gz", urls["ohos-sdk"])
        self.assertEqual(urls["dayu200_xts_static"], "")

    def test_extracts_dashboard_url(self):
        builds = extract_build_info(SAMPLE_HTML)
        dash = {b["target"]: b["dashboard_url"] for b in builds}
        self.assertIn("dcp.openharmony.cn", dash["dayu200"])

    def test_empty_html(self):
        builds = extract_build_info(SAMPLE_HTML_NO_CI)
        self.assertEqual(len(builds), 0)

    def test_empty_string(self):
        builds = extract_build_info("")
        self.assertEqual(len(builds), 0)


class TestExtractBuildInfoEdgeCases(unittest.TestCase):

    def test_duplicate_rows_deduplicates(self):
        html = SAMPLE_HTML + SAMPLE_HTML
        builds = extract_build_info(html)
        self.assertEqual(len(builds), 3)

    def test_alt_log_urls(self):
        html = """<a href="https://example.com/some/path/build.log">build.log</a>"""
        builds = extract_build_info(html)
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0]["target"], "unknown")


if __name__ == "__main__":
    unittest.main()
