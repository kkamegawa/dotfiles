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

    def write_fake_mise(self):
        fake_mise = self.temp / "mise-fake"
        fake_mise.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' '=== call ===' \"$@\" >> \"$MISE_LOG\"\n"
            "if [ \"$3\" = \"ls\" ]; then\n"
            "  printf '%s' \"$MISE_LS_JSON\"\n"
            "elif [ \"$3\" = \"bin-paths\" ] && [ \"$5\" = \"--\" ]; then\n"
            "  if [ \"$MISE_FAIL_VERSIONED\" = \"1\" ]; then echo 'fixture failure' >&2; exit 23; fi\n"
            "  printf '%s' \"$MISE_VERSIONED_JSON\"\n"
            "elif [ \"$3\" = \"bin-paths\" ]; then\n"
            "  printf '%s' \"$MISE_ACTIVE_JSON\"\n"
            "else\n"
            "  echo \"unexpected fake mise arguments: $*\" >&2\n"
            "  exit 24\n"
            "fi\n",
            encoding="utf-8",
        )
        fake_mise.chmod(0o755)
        return fake_mise

    def run_discover(self, mise_path, *, ls_json, active_json, versioned_json, fail_versioned=False):
        return subprocess.run(
            [NODE, str(HELPER), "--discover", str(self.settings_path), str(self.ownership_path), str(mise_path)],
            text=True,
            capture_output=True,
            env={
                **os.environ,
                "HOME": str(self.home),
                "MISE_SHIMS_DIR": str(self.home / ".local" / "share" / "mise" / "shims"),
                "MISE_LOG": str(self.temp / "mise-calls.log"),
                "MISE_LS_JSON": json.dumps(ls_json),
                "MISE_ACTIVE_JSON": json.dumps(active_json),
                "MISE_VERSIONED_JSON": json.dumps(versioned_json),
                "MISE_FAIL_VERSIONED": "1" if fail_versioned else "0",
            },
            check=False,
        )

    def read_mise_calls(self):
        log_path = self.temp / "mise-calls.log"
        if not log_path.exists():
            return []
        return [
            block.strip().splitlines()
            for block in log_path.read_text(encoding="utf-8").split("=== call ===\n")
            if block.strip()
        ]

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

    @unittest.skipIf(IS_WINDOWS, "production discovery uses a POSIX fake mise executable and symlink")
    def test_discover_uses_official_inventory_shape_tracks_versions_and_preserves_files_on_failure(self):
        az_v1 = self.executable("az", "1.0.0")
        az_v2 = self.executable("az", "2.0.0")
        gh_v3 = self.executable("gh", "3.0.0")
        self.write_settings(
            {"permissions": {"allow": ["Bash(az account show)", "Bash(gh pr:*)"]}}
        )
        fake_mise = self.write_fake_mise()
        shims_dir = self.home / ".local" / "share" / "mise" / "shims"
        shims_dir.mkdir(parents=True)
        shim_az = shims_dir / "az"
        shim_az.symlink_to(fake_mise)

        inventory_all = {
            "azure:cli": [
                {
                    "version": "1.0.0",
                    "install_path": str(az_v1.parent.parent),
                    "source": {"type": "mise.toml", "path": str(self.home / ".config" / "mise.toml")},
                },
                {
                    "version": "2.0.0",
                    "install_path": str(az_v2.parent.parent),
                    "source": {"type": "mise.toml", "path": str(self.home / ".config" / "mise.toml")},
                },
            ],
            "github:cli": [
                {
                    "version": "3.0.0",
                    "install_path": str(gh_v3.parent.parent),
                    "source": {"type": "mise.toml", "path": str(self.home / ".config" / "mise.toml")},
                }
            ],
        }
        inventory_current = {
            "azure:cli": [inventory_all["azure:cli"][1]],
            "github:cli": inventory_all["github:cli"],
        }
        active_bins = [self.bin_record("az", az_v2), self.bin_record("gh", gh_v3)]
        all_versioned_bins = [
            self.bin_record("az", az_v1),
            self.bin_record("az", az_v2),
            self.bin_record("gh", gh_v3),
        ]
        current_versioned_bins = [self.bin_record("az", az_v2), self.bin_record("gh", gh_v3)]

        first = self.run_discover(
            fake_mise,
            ls_json=inventory_all,
            active_json=active_bins,
            versioned_json=all_versioned_bins,
        )

        self.assertEqual(first.returncode, 0, first.stderr)
        first_rules = self.read_settings()["permissions"]["allow"]
        for executable in (az_v1, az_v2):
            self.assertIn(f"Bash({self.rule_path(executable)} account show)", first_rules)
        self.assertIn(f"Bash({self.rule_path(gh_v3)} pr:*)", first_rules)
        self.assertIn(f"Bash({self.rule_path(shim_az)} account show)", first_rules)
        self.assertEqual(
            self.read_mise_calls(),
            [
                ["-C", str(self.home), "ls", "--installed", "--json"],
                ["-C", str(self.home), "bin-paths", "--json"],
                [
                    "-C",
                    str(self.home),
                    "bin-paths",
                    "--json",
                    "--",
                    "azure:cli@1.0.0",
                    "azure:cli@2.0.0",
                    "github:cli@3.0.0",
                ],
            ],
        )

        updated = self.run_discover(
            fake_mise,
            ls_json=inventory_current,
            active_json=active_bins,
            versioned_json=current_versioned_bins,
        )
        self.assertEqual(updated.returncode, 0, updated.stderr)
        updated_rules = self.read_settings()["permissions"]["allow"]
        self.assertNotIn(f"Bash({self.rule_path(az_v1)} account show)", updated_rules)
        self.assertIn(f"Bash({self.rule_path(az_v2)} account show)", updated_rules)
        self.assertIn(f"Bash({self.rule_path(shim_az)} account show)", updated_rules)

        settings_before_failure = self.settings_path.read_bytes()
        ownership_before_failure = self.ownership_path.read_bytes()
        failed = self.run_discover(
            fake_mise,
            ls_json={
                "azure:cli": [
                    {
                        "version": "4.0.0",
                        "install_path": "/unused",
                        "source": {"type": "mise.toml", "path": str(self.home / ".config" / "mise.toml")},
                    }
                ]
            },
            active_json=[self.bin_record("az", az_v2)],
            versioned_json=[],
            fail_versioned=True,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("exit code 23", failed.stderr)
        self.assertIn("fixture failure", failed.stderr)
        self.assertEqual(self.settings_path.read_bytes(), settings_before_failure)
        self.assertEqual(self.ownership_path.read_bytes(), ownership_before_failure)


if __name__ == "__main__":
    unittest.main()
