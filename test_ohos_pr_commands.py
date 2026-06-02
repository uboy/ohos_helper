"""
Tests for PR CI bot commands feature.

Tests:
  - pr_commands.json structure and content
  - list-ci-commands CLI (text + --labels + --json)
  - ci-command CLI: URL parsing, command validation
  - ohos pr ci-commands dispatch via ohos.sh
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
GITEE_QUERY = SCRIPT_DIR / "gitee_util" / "gitee_query.py"
PR_COMMANDS_JSON = SCRIPT_DIR / "gitee_util" / "pr_commands.json"
OHOS_SH = SCRIPT_DIR / "ohos.sh"

ARTIFACT_ROOT = SCRIPT_DIR / "test-artifacts"
RUN_TIMESTAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
ARTIFACT_DIR = ARTIFACT_ROOT / RUN_TIMESTAMP


def _run_python(script, *args, timeout=15, env=None):
    """Run python script, return (rc, stdout, stderr)."""
    result = subprocess.run(
        ["python3", str(script)] + list(args),
        capture_output=True, text=True, timeout=timeout,
        cwd=str(SCRIPT_DIR),
        env=env,
    )
    return result.returncode, result.stdout, result.stderr


def _run_ohos_pr(*args, timeout=15):
    """Run ohos.sh pr <args>, return (rc, stdout, stderr)."""
    result = subprocess.run(
        ["bash", str(OHOS_SH), "pr"] + list(args),
        capture_output=True, text=True, timeout=timeout,
        cwd=str(SCRIPT_DIR),
    )
    return result.returncode, result.stdout, result.stderr


def _save_artifact(name, content):
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    (ARTIFACT_DIR / name).write_text(content)


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
# JSON Data File Structure
# =========================================================================

class TestPrCommandsJson(_ArtifactTestCase):
    """Verify pr_commands.json structure and required commands present."""

    REQUIRED_COMMANDS = [
        "start build", "stop build", "submit", "check dco",
        "static-check", "lgtm", "check comment", "code review",
    ]

    def setUp(self):
        self.data = json.loads(PR_COMMANDS_JSON.read_text(encoding="utf-8"))

    def test_file_exists(self):
        self.assertTrue(PR_COMMANDS_JSON.exists())

    def test_top_level_keys(self):
        for key in ("pr_commands", "pr_labels", "source_url"):
            self.assertIn(key, self.data, f"Missing top-level key: {key}")

    def test_source_url_is_gitcode(self):
        self.assertIn("gitcode.com", self.data["source_url"])
        self.assertIn("build_command", self.data["source_url"])

    def test_pr_commands_is_list(self):
        self.assertIsInstance(self.data["pr_commands"], list)
        self.assertGreaterEqual(len(self.data["pr_commands"]), 10,
            "Should have at least 10 PR commands per docs")

    def test_required_commands_present(self):
        cmd_texts = [c["command"].lower() for c in self.data["pr_commands"]]
        for required in self.REQUIRED_COMMANDS:
            self.assertTrue(
                any(required in c for c in cmd_texts),
                f"Required command '{required}' not found in pr_commands"
            )

    def test_each_command_has_required_fields(self):
        for cmd in self.data["pr_commands"]:
            self.assertIn("command", cmd, f"Missing 'command': {cmd}")
            self.assertIn("description", cmd, f"Missing 'description': {cmd}")
            self.assertIn("role", cmd, f"Missing 'role': {cmd}")
            self.assertIn("required", cmd, f"Missing 'required': {cmd}")
            self.assertIsInstance(cmd["required"], bool)

    def test_only_start_build_required(self):
        """Only 'start build' should be marked required per docs."""
        required = [c for c in self.data["pr_commands"] if c.get("required")]
        self.assertEqual(len(required), 1, "Exactly one command must be required")
        self.assertEqual(required[0]["command"].lower(), "start build")

    def test_pr_labels_present(self):
        labels = [l["label"] for l in self.data["pr_labels"]]
        for expected in ["waiting_on_author", "waiting_for_review",
                          "reviewing", "waiting_for_merge", "merged"]:
            self.assertIn(expected, labels, f"Missing label: {expected}")


# =========================================================================
# CLI: list-ci-commands
# =========================================================================

class TestListCiCommands(_ArtifactTestCase):
    """Test list-ci-commands CLI output."""

    def test_default_output_lists_commands(self):
        rc, out, err = _run_python(GITEE_QUERY, "list-ci-commands")
        _save_artifact("ci_commands_default.txt", out + "\n---STDERR---\n" + err)
        self.assertEqual(rc, 0, f"rc={rc}: {err}")
        self.assertIn("start build", out)
        self.assertIn("lgtm", out)
        self.assertIn("check dco", out)

    def test_output_mentions_required_marker(self):
        rc, out, _ = _run_python(GITEE_QUERY, "list-ci-commands")
        self.assertEqual(rc, 0)
        self.assertIn("REQUIRED", out)

    def test_labels_flag(self):
        rc, out, err = _run_python(GITEE_QUERY, "list-ci-commands", "--labels")
        _save_artifact("ci_commands_labels.txt", out + "\n---STDERR---\n" + err)
        self.assertEqual(rc, 0)
        self.assertIn("waiting_on_author", out)
        self.assertIn("reviewing", out)
        # Should not list commands when --labels is set
        # (labels mode skips commands list)

    def test_json_flag_outputs_valid_json(self):
        rc, out, err = _run_python(GITEE_QUERY, "list-ci-commands", "--json")
        _save_artifact("ci_commands_json.txt", out)
        self.assertEqual(rc, 0)
        data = json.loads(out)  # Should parse without error
        self.assertIn("pr_commands", data)
        self.assertIn("pr_labels", data)

    def test_source_url_in_output(self):
        rc, out, _ = _run_python(GITEE_QUERY, "list-ci-commands")
        self.assertEqual(rc, 0)
        self.assertIn("gitcode.com/openharmony", out)

    def test_role_information_shown(self):
        rc, out, _ = _run_python(GITEE_QUERY, "list-ci-commands")
        self.assertEqual(rc, 0)
        self.assertIn("PR author", out)
        self.assertIn("Committer", out)


# =========================================================================
# URL Parsing
# =========================================================================

class TestUrlParsing(_ArtifactTestCase):
    """Test _parse_pr_url handles GitCode and Gitee URL formats."""

    def setUp(self):
        # Import the module's function
        sys.path.insert(0, str(SCRIPT_DIR / "gitee_util"))
        try:
            from gitee_query import _parse_pr_url  # type: ignore
            self.parse = _parse_pr_url
        except ImportError:
            # Re-raise as skip
            self.skipTest("Cannot import gitee_query._parse_pr_url")

    def test_gitcode_pulls_url(self):
        owner, repo, num = self.parse(
            "https://gitcode.com/openharmony/arkui_ace_engine/pulls/84616")
        self.assertEqual(owner, "openharmony")
        self.assertEqual(repo, "arkui_ace_engine")
        self.assertEqual(num, 84616)

    def test_gitcode_pull_url(self):
        owner, repo, num = self.parse(
            "https://gitcode.com/openharmony/arkui_ace_engine/pull/84616")
        self.assertEqual(num, 84616)

    def test_gitee_merge_requests_url(self):
        owner, repo, num = self.parse(
            "https://gitee.com/openharmony/arkui_ace_engine/merge_requests/84616")
        self.assertEqual(owner, "openharmony")
        self.assertEqual(num, 84616)

    def test_invalid_url_returns_none(self):
        owner, repo, num = self.parse("not-a-url")
        self.assertIsNone(owner)
        self.assertIsNone(repo)
        self.assertIsNone(num)

    def test_url_without_number(self):
        owner, repo, num = self.parse(
            "https://gitcode.com/openharmony/arkui_ace_engine/pulls/")
        self.assertIsNone(owner)


# =========================================================================
# Command Validation
# =========================================================================

class TestCommandValidation(_ArtifactTestCase):
    """Test _match_command correctly identifies known commands."""

    def setUp(self):
        sys.path.insert(0, str(SCRIPT_DIR / "gitee_util"))
        try:
            from gitee_query import _match_command, _load_pr_commands  # type: ignore
            self.match = _match_command
            self.commands = _load_pr_commands()["pr_commands"]
        except ImportError:
            self.skipTest("Cannot import gitee_query functions")

    def test_exact_match_start_build(self):
        self.assertTrue(self.match("start build", self.commands))

    def test_exact_match_lgtm(self):
        self.assertTrue(self.match("lgtm", self.commands))

    def test_exact_match_check_dco(self):
        self.assertTrue(self.match("check dco", self.commands))

    def test_assign_with_users_matches(self):
        """assign @user1 @user2 should match the assign command pattern."""
        self.assertTrue(self.match("assign @user1 @user2", self.commands))

    def test_unassign_with_user_matches(self):
        self.assertTrue(self.match("unassign @someone", self.commands))

    def test_empty_command_does_not_match(self):
        self.assertFalse(self.match("", self.commands))
        self.assertFalse(self.match("   ", self.commands))

    def test_unknown_command_does_not_match(self):
        self.assertFalse(self.match("destroy everything", self.commands))
        self.assertFalse(self.match("random text", self.commands))

    def test_case_insensitive(self):
        self.assertTrue(self.match("Start Build", self.commands))
        self.assertTrue(self.match("LGTM", self.commands))


# =========================================================================
# ci-command CLI: validation and arg parsing
# =========================================================================

class TestCiCommandCli(_ArtifactTestCase):
    """Test ci-command CLI argument handling and validation."""

    def test_missing_command_text_fails(self):
        rc, out, err = _run_python(GITEE_QUERY, "ci-command",
                                    "--url", "https://gitcode.com/owner/repo/pulls/1")
        self.assertNotEqual(rc, 0)
        # argparse reports missing positional arg
        self.assertIn("command_text", (out + err).lower())

    def test_missing_pr_identifier_fails(self):
        rc, out, err = _run_python(GITEE_QUERY, "ci-command", "start build")
        self.assertNotEqual(rc, 0)
        # argparse mutually exclusive group requires one
        combined = (out + err).lower()
        self.assertTrue("--url" in combined or "--pr-id" in combined,
                        f"Expected --url or --pr-id in error: {combined}")

    def test_invalid_url_fails(self):
        rc, out, err = _run_python(GITEE_QUERY, "ci-command",
                                    "start build", "--url", "not-a-url")
        self.assertNotEqual(rc, 0)
        self.assertIn("cannot parse", (out + err).lower())

    def test_unknown_command_warns_without_posting(self):
        """Unknown command with --yes skipped should prompt and abort on EOF.

        We use stdin EOF (no input) so it should abort with rc=1.
        """
        # Pass --yes to allow unknown; then attempt will fail at API call
        # but we want to verify the warning happens
        rc, out, err = _run_python(GITEE_QUERY, "ci-command",
                                    "totally-unknown-cmd",
                                    "--url", "https://gitcode.com/owner/repo/pulls/1",
                                    timeout=10)
        # Without --yes, EOF on stdin should abort
        self.assertNotEqual(rc, 0)
        self.assertIn("not in official", (out + err).lower())

    def test_url_or_pr_id_required(self):
        rc, out, err = _run_python(GITEE_QUERY, "ci-command", "start build")
        self.assertNotEqual(rc, 0)


# =========================================================================
# ohos.sh wrapper dispatch
# =========================================================================

class TestOhosPrDispatch(_ArtifactTestCase):
    """Verify ohos.sh pr ci-commands dispatch works."""

    def test_ohos_pr_ci_commands_runs(self):
        rc, out, err = _run_ohos_pr("ci-commands")
        _save_artifact("ohos_pr_ci_commands.txt", out + "\n---STDERR---\n" + err)
        self.assertEqual(rc, 0, f"ohos pr ci-commands failed: rc={rc}, err={err}")
        self.assertIn("start build", out)
        self.assertIn("lgtm", out)

    def test_ohos_pr_ci_commands_labels(self):
        rc, out, err = _run_ohos_pr("ci-commands", "--labels")
        _save_artifact("ohos_pr_ci_commands_labels.txt", out + "\n---STDERR---\n" + err)
        self.assertEqual(rc, 0)
        self.assertIn("waiting_on_author", out)

    def test_ohos_pr_ci_commands_json(self):
        rc, out, err = _run_ohos_pr("ci-commands", "--json")
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertIn("pr_commands", data)

    def test_ohos_pr_help_lists_ci_commands(self):
        rc, out, err = _run_ohos_pr("help")
        self.assertEqual(rc, 0)
        self.assertIn("ci-commands", out)
        self.assertIn("ci-command", out)


if __name__ == "__main__":
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    (ARTIFACT_DIR / ".gitkeep").write_text("")
    unittest.main()
