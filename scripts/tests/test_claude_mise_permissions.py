"""Tests for mise-managed executable paths in Claude Code permissions."""

import json
import os
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "home" / "dot_claude" / "hooks" / "mise-permissions.mjs"
NODE = os.environ.get("NODE", "node")
IS_WINDOWS = platform.system() == "Windows"


@unittest.skipUnless(shutil.which(NODE), "node is not installed")
class MisePermissionsTestCase(unittest.TestCase):
    def setUp(self):
        # Keep temporary files in the workspace: Windows AppContainer processes
        # can be unable to create files in the system temporary directory.
        self.temp = Path(
            tempfile.mkdtemp(prefix=".mise-permissions-", dir=REPO / "scripts" / "tests")
        )
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.home = self.temp / "home"
        self.home.mkdir()
        self.settings_path = self.temp / "settings.json"
        self.ownership_path = self.temp / "ownership.json"
        self.bins_dir = self.temp / "mise" / "installs"
        self.bins_dir.mkdir(parents=True)

    def executable(self, name, version="1.0.0"):
        executable = self.bins_dir / name / version / "bin" / name
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("fixture", encoding="utf-8")
        if not IS_WINDOWS:
            executable.chmod(0o755)
        return executable

    def write_settings(self, settings):
        self.settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")

    def run_helper(self, bins, *, raw_input=None):
        if raw_input is None:
            raw_input = json.dumps(bins)
        return subprocess.run(
            [NODE, str(HELPER), str(self.settings_path), str(self.ownership_path)],
            input=raw_input,
            text=True,
            capture_output=True,
            env={**os.environ, "HOME": str(self.home)},
            check=False,
        )

    def read_settings(self):
        return json.loads(self.settings_path.read_text(encoding="utf-8"))

    def bin_record(self, name, executable):
        # Forward slashes are valid on Windows and avoid adding shell quotes to
        # generated Claude rules solely because the native path uses backslashes.
        path = executable.as_posix()
        return {"name": name, "path": path, "symlink": False}

    def rule_path(self, executable):
        return executable.as_posix()

    def test_keeps_exact_rules_for_all_reported_versions_of_a_tool(self):
        executables = [self.executable("az", version) for version in ("1.0.0", "2.0.0")]
        self.settings_path.write_text(
            json.dumps({"permissions": {"allow": ["Bash(az)", "Bash(az account show)"]}}),
            encoding="utf-8",
        )

        result = self.run_helper([self.bin_record("az", executable) for executable in executables])

        self.assertEqual(result.returncode, 0, result.stderr)
        allow = self.read_settings()["permissions"]["allow"]
        for executable in executables:
            executable_path = self.rule_path(executable)
            self.assertIn(f"Bash({executable_path})", allow)
            self.assertIn(f"Bash({executable_path} account show)", allow)
        self.assertFalse(self.settings_path.read_bytes().endswith(b"\n"))

    def test_expands_allow_ask_and_deny_rules_for_multiple_tools(self):
        az = self.executable("az")
        gh = self.executable("gh")
        dotnet = self.executable("dotnet")
        self.write_settings(
            {
                "permissions": {
                    "allow": ["Bash(gh pr:*)"],
                    "ask": ["Bash(dotnet ef database update:*)"],
                    "deny": ["Bash(az *)"],
                }
            }
        )

        result = self.run_helper(
            [
                self.bin_record("az", az),
                self.bin_record("gh", gh),
                self.bin_record("dotnet", dotnet),
            ]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        permissions = self.read_settings()["permissions"]
        az_path = self.rule_path(az)
        gh_path = self.rule_path(gh)
        dotnet_path = self.rule_path(dotnet)
        self.assertIn(f"Bash({gh_path} pr:*)", permissions["allow"])
        self.assertIn(f"Bash({dotnet_path} ef database update:*)", permissions["ask"])
        self.assertIn(f"Bash({az_path} *)", permissions["deny"])
        ledger = json.loads(self.ownership_path.read_text(encoding="utf-8"))
        self.assertEqual(ledger["version"], 1)
        self.assertEqual(
            {(entry["group"], entry["rule"]) for entry in ledger["rules"]},
            {
                ("allow", f"Bash({gh_path} pr:*)"),
                ("ask", f"Bash({dotnet_path} ef database update:*)"),
                ("deny", f"Bash({az_path} *)"),
            },
        )

    def test_supported_ask_wildcard_and_allow_rules_keep_exact_suffixes(self):
        az = self.executable("az")
        self.write_settings(
            {
                "permissions": {
                    "allow": ["Bash(az account show)"],
                    "ask": ["Bash(az account *)"],
                    "deny": [],
                }
            }
        )

        result = self.run_helper([self.bin_record("az", az)])

        self.assertEqual(result.returncode, 0, result.stderr)
        permissions = self.read_settings()["permissions"]
        az_path = self.rule_path(az)
        self.assertIn(f"Bash({az_path} account *)", permissions["ask"])
        self.assertIn(f"Bash({az_path} account show)", permissions["allow"])

    def test_unsupported_ask_executable_head_suppresses_allow_alias(self):
        az = self.executable("az")
        self.write_settings(
            {
                "permissions": {
                    "allow": ["Bash(az account show)"],
                    "ask": ["Bash(a* account show)"],
                    "deny": [],
                }
            }
        )

        result = self.run_helper([self.bin_record("az", az)])

        self.assertEqual(result.returncode, 0, result.stderr)
        permissions = self.read_settings()["permissions"]
        az_path = self.rule_path(az)
        self.assertIn("Bash(a* account show)", permissions["ask"])
        self.assertNotIn(f"Bash({az_path} account show)", permissions["allow"])

    def test_preserves_manual_absolute_rules_and_other_settings_and_is_idempotent(self):
        az = self.executable("az")
        original = {
            "model": "opusplan",
            "env": {"PATH": "/custom/bin", "KEEP": "value"},
            "permissions": {
                "allow": ["Bash(az account show)", "Bash(/manual/path/az account show)"],
                "ask": [],
                "deny": [],
            },
            "customSetting": {"enabled": True},
        }
        self.write_settings(original)
        bins = [self.bin_record("az", az)]

        first = self.run_helper(bins)
        self.assertEqual(first.returncode, 0, first.stderr)
        after_first = self.settings_path.read_bytes()
        ledger_after_first = self.ownership_path.read_bytes()
        second = self.run_helper(bins)

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.settings_path.read_bytes(), after_first)
        self.assertEqual(self.ownership_path.read_bytes(), ledger_after_first)
        settings = self.read_settings()
        self.assertEqual(settings["model"], original["model"])
        self.assertEqual(settings["env"], original["env"])
        self.assertEqual(settings["customSetting"], original["customSetting"])
        self.assertIn("Bash(/manual/path/az account show)", settings["permissions"]["allow"])

    def test_replaces_stale_generated_aliases_when_mise_path_changes(self):
        old_az = self.executable("az", "1.0.0")
        new_az = self.executable("az", "2.0.0")
        self.write_settings({"permissions": {"allow": ["Bash(az account show)"]}})

        initial = self.run_helper([self.bin_record("az", old_az)])
        self.assertEqual(initial.returncode, 0, initial.stderr)
        updated = self.run_helper([self.bin_record("az", new_az)])

        self.assertEqual(updated.returncode, 0, updated.stderr)
        rules = self.read_settings()["permissions"]["allow"]
        self.assertIn(f"Bash({self.rule_path(new_az)} account show)", rules)
        self.assertNotIn(f"Bash({self.rule_path(old_az)} account show)", rules)
        self.assertIn("Bash(az account show)", rules)

    def test_invalid_discovery_data_fails_without_changing_either_file(self):
        az = self.executable("az")
        self.write_settings({"permissions": {"allow": ["Bash(az account show)"]}, "keep": 1})
        self.ownership_path.write_text(
            json.dumps({"version": 1, "rules": [{"group": "allow", "rule": "Bash(/stale/az account show)"}]}),
            encoding="utf-8",
        )
        settings_before = self.settings_path.read_bytes()
        ownership_before = self.ownership_path.read_bytes()
        malformed_inputs = [
            "{bad json",
            "{}",
            json.dumps([{"name": "az", "path": str(az.parent / "wrong-name")}]),
            json.dumps([{"name": "az", "path": str(self.temp / "missing" / "az")}]),
            json.dumps([{"name": "az", "path": str(az).replace("\\", "/").replace("/az/1.0.0/", "/az*/1.0.0/")}]),
        ]

        for invalid_input in malformed_inputs:
            with self.subTest(input=invalid_input):
                result = self.run_helper([], raw_input=invalid_input)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.settings_path.read_bytes(), settings_before)
                self.assertEqual(self.ownership_path.read_bytes(), ownership_before)

    def test_invalid_settings_fails_without_changing_settings_or_ownership(self):
        az = self.executable("az")
        self.settings_path.write_text('{"permissions":{"allow":false}}\n', encoding="utf-8")
        self.ownership_path.write_text('{"version":1,"rules":[]}\n', encoding="utf-8")
        settings_before = self.settings_path.read_bytes()
        ownership_before = self.ownership_path.read_bytes()

        result = self.run_helper([self.bin_record("az", az)])

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.settings_path.read_bytes(), settings_before)
        self.assertEqual(self.ownership_path.read_bytes(), ownership_before)


if __name__ == "__main__":
    unittest.main()
