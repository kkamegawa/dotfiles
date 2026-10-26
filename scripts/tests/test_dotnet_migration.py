"""Exercise migration state/failure paths with private fixtures and fake commands.

No test installs SDKs, invokes sudo, changes /etc, or operates real package state.
The Bash API is sourced and its command boundaries are replaced inside the test
process; the public CLI never receives a privileged-path override.
"""

import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DRIVER = REPO / "scripts/migrate-dotnet-macos.sh"
BASH = shutil.which("bash")
JQ = shutil.which("jq")
SHASUM = shutil.which("shasum")


@unittest.skipUnless(os.name == "posix" and BASH and JQ and SHASUM, "POSIX Bash, jq and shasum required")
class MigrationTest(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="dotnet-migration-test-")).resolve()
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.home = self.scratch / "home with spaces"
        self.state = self.scratch / "state"
        self.bin = self.scratch / "bin"
        self.registration = self.scratch / "etc/dotnet/install_location_arm64"
        self.root = self.home / ".local/share/mise/dotnet-root"
        self.system = self.scratch / "system-sdk"
        self.calls = self.scratch / "calls"
        for path in (self.home, self.bin, self.registration.parent, self.root, self.system):
            path.mkdir(parents=True, exist_ok=True)
        self.command("mise", """case "$1" in
--version) echo '2026.10.17 macos-arm64' ;;
settings) : ;;
upgrade) echo '--global --exclude --no-prune' ;;
*) echo "mise:$*" >> "$CALLS" ;;
esac""")
        self.command("brew", '''echo "brew:$*" >> "$CALLS"
case "$*" in
  "list --cask --versions dotnet-sdk")
    if [ "${BREW_DOTNET_SDK_INSTALLED:-0}" = 1 ]; then echo 'dotnet-sdk 10.0.401'
    elif [ "${BREW_SILENT_ABSENT:-0}" = 1 ]; then exit 1
    else echo "Error: Cask 'dotnet-sdk' is not installed." >&2; exit 1; fi ;;
  "list --cask")
    if [ "${BREW_DOTNET_SDK_INSTALLED:-0}" = 1 ]; then echo 'dotnet-sdk'; else echo 'orchard'; fi ;;
  "list --cask --versions") echo "Error: Cask 'orchard' is not installed." >&2; exit 1 ;;
esac''')
        self.command("chezmoi", 'echo "chezmoi:$*" >> "$CALLS"')
        self.command("curl", 'echo "curl:$*" >> "$CALLS"; exit 90')
        self.command("uname", 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac')
        self.command("sudo", 'echo "FORBIDDEN-SUDO:$*" >> "$CALLS"; exit 91')
        self.command("pkgutil", 'echo "pkgutil:$*" >> "$CALLS"; exit 92')
        self.command("installer", 'echo "FORBIDDEN-INSTALLER:$*" >> "$CALLS"; exit 93')
        self.command("stat", self.stat_adapter())
        self.env = {**os.environ, "HOME": str(self.home), "CALLS": str(self.calls),
                    "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", "")}

    def stat_adapter(self):
        if platform.system() == "Darwin":
            actual = shutil.which("stat")
            return f'exec {shlex.quote(actual)} "$@"'
        return '''if [ "$1" = -f ]; then
  case "$2" in '%Su') format='%U';; '%u') format='%u';; '%Lp') format='%a';; *) exit 94;; esac
  exec /usr/bin/stat -c "$format" "$3"
fi
exec /usr/bin/stat "$@"'''

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    def source_prefix(self):
        variables = {
            "MIGRATION_HOME": self.home,
            "MIGRATION_REPO": REPO,
            "MIGRATION_STATE_DIR": self.state,
            "MIGRATION_ARCH": "arm64",
            "MIGRATION_SHARED_ROOT": self.root,
            "MIGRATION_SYSTEM_ROOT": self.system,
            "MIGRATION_USER_ROOT": self.home / ".dotnet",
            "MIGRATION_REGISTRATION": self.registration,
            "MIGRATION_MISE_BIN": self.bin / "mise",
            "MIGRATION_CHEZMOI_BIN": self.bin / "chezmoi",
            "MIGRATION_JQ_BIN": JQ,
            "MIGRATION_SHASUM_BIN": SHASUM,
            "MIGRATION_CURL_BIN": self.bin / "curl",
            "MIGRATION_BREW_BIN": self.bin / "brew",
            "MIGRATION_SUDO_BIN": self.bin / "sudo",
            "MIGRATION_PKGUTIL_BIN": self.bin / "pkgutil",
            "MIGRATION_PACKAGE_TOOL": self.bin / "installer",
        }
        return (f"source {shlex.quote(str(DRIVER))}\nmigration_init_defaults\n"
                + "\n".join(f"{key}={shlex.quote(str(value))}" for key, value in variables.items())
                + "\nmigration_require_macos() { return 0; }\n"
                + "migration_validate_inputs() { return 0; }\n")

    def run_api(self, script):
        return subprocess.run([BASH, "-c", self.source_prefix() + script],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def call_log(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def seed_state(self, phase="prepared", targets=None, **changes):
        self.state.mkdir(mode=0o700, exist_ok=True)
        defaults = []
        for relative in (".config/mise/config.toml", ".profile", "PowerShell_profile.ps1", ".gitconfig",
                         ".local/bin/dotfiles-dotnet10", ".local/share/dotfiles/dotnet10-runner/global.json",
                         ".codex/config.toml", ".claude/settings.json"):
            defaults.append({"path": str(self.home / relative), "kind": "absent", "mode": "", "uid": "",
                             "backupFile": "", "originalSha256": "", "appliedSha256": None})
        overrides = {entry["path"]: entry for entry in (targets or [])}
        merged_targets = [overrides.pop(entry["path"], entry) for entry in defaults] + list(overrides.values())
        package = self.state / "dotnet-sdk-10.0.401-osx-arm64.pkg"
        package.write_bytes(b"fixture installer; never executed")
        package.chmod(0o600)
        data = {
            "schemaVersion": 1, "phase": phase, "home": str(self.home),
            "repo": str(REPO), "architecture": "arm64", "sharedRoot": str(self.root),
            "projectPaths": [], "retainedVersions": ["10.0.401", "8.0.404"],
            "targets": merged_targets,
            "registration": {"path": str(self.registration), "kind": "absent", "mode": "", "uid": "",
                             "backupFile": "", "originalSha256": "", "desired": str(self.root)},
            "manifest": {"path": str(self.home / ".config/dotfiles/dotnet-retained-sdks.json"),
                         "originalKind": "absent", "originalMode": "", "originalSha256": "",
                         "backupFile": "", "appliedSha256": None},
            "checkpoints": {"installedVersions": [],
                            "appliedTargets": [entry["path"] for entry in merged_targets
                                               if entry.get("appliedSha256") is not None], "registration": "pending",
                            "caskRemoved": False, "guiAttested": False},
            "inventory": {"oldSystemSdks": ["10.0.401"], "oldUserSdks": ["8.0.404"],
                          "oldSharedSdks": [], "workloadsFile": "", "globalToolsFile": ""},
            "package": {"file": str(package), "version": "10.0.401",
                        "rid": "osx-arm64", "sha512": hashlib.sha512(package.read_bytes()).hexdigest(),
                        "signatureVerified": True},
        }
        data.update(changes)
        path = self.state / "state.json"
        path.write_text(json.dumps(data))
        path.chmod(0o600)
        return data

    def test_sourcing_has_no_side_effects(self):
        result = subprocess.run([BASH, "-c", f"source {shlex.quote(str(DRIVER))}"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.calls.exists())

    def test_help_does_not_create_state_or_call_mutating_tools(self):
        result = subprocess.run([BASH, str(DRIVER), "--help"], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rollback", result.stdout)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.calls.exists())

    def test_missing_host_inventory_is_empty_success(self):
        result = self.run_api('migration_sdk_list "$MIGRATION_HOME/absent/dotnet"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_cask_status_confirms_silent_absence_from_full_inventory(self):
        self.env["BREW_SILENT_ABSENT"] = "1"
        result = self.run_api("migration_cask_status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "absent")
        self.assertIn("brew:list --cask\n", self.call_log())

    def test_empty_sdk_list_keeps_runtime_label_on_its_own_line(self):
        host_root = self.scratch / "sdk host"
        host_root.mkdir()
        host = host_root / "dotnet"
        host.write_text("""#!/bin/sh
case "$1" in
  --list-sdks) exit 0 ;;
  --list-runtimes) echo 'Microsoft.NETCore.App 10.0.1' ;;
esac
""", encoding="utf-8")
        host.chmod(0o755)
        result = self.run_api(f'migration_host_inventory fixture "{host_root}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("  SDKs: \n  runtimes:\n", result.stdout)

    def test_plan_never_creates_state_or_downloads(self):
        result = self.run_api("migration_inventory")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("read-only", result.stdout)
        self.assertIn("dotnet-sdk cask: absent", result.stdout)
        self.assertIn("brew:list --cask --versions dotnet-sdk", self.call_log())
        self.assertNotIn("brew:list --cask --versions\n", self.call_log())
        self.assertFalse(self.state.exists())
        self.assertNotIn("install", self.call_log())
        self.assertNotIn("curl:", self.call_log())
        self.assertNotIn("FORBIDDEN", self.call_log())

    def test_state_update_uses_jq_arguments_without_corrupting_state(self):
        self.seed_state()
        result = self.run_api("migration_update_state --arg p verified '.phase=$p'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.state / "state.json").read_text())["phase"], "verified")
        self.assertEqual((self.state / "state.json").stat().st_mode & 0o777, 0o600)

    def test_state_rejects_a_different_home(self):
        self.seed_state(home="/some/other/home")
        result = self.run_api("migration_read_state")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("FORBIDDEN", self.call_log())

    def test_state_rejects_an_unexpected_target(self):
        self.seed_state(targets=[{"path": str(self.scratch / "unrelated"), "kind": "absent"}])
        result = self.run_api("migration_read_state")
        self.assertNotEqual(result.returncode, 0)

    def test_active_lock_is_not_removed_by_a_second_invocation(self):
        self.state.mkdir(mode=0o700)
        lock = self.state / ".lock"
        lock.mkdir()
        marker = lock / "original"
        marker.write_text("first invocation")
        result = self.run_api("migration_lock")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "first invocation")

    def test_finalization_requires_manual_attestation_before_removal(self):
        self.seed_state("verified")
        result = self.run_api("migration_finalize")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ide-checks-confirmed", result.stderr)
        self.assertNotIn("uninstall", self.call_log())
        self.assertEqual(json.loads((self.state / "state.json").read_text())["phase"], "verified")

    def test_rollback_conflict_preflights_before_any_restore(self):
        target = self.home / ".profile"
        target.write_text("user changed this after switch")
        targets = [{"path": str(target), "kind": "file", "mode": "644", "uid": str(os.getuid()),
                    "backupFile": str(self.state / "backup.1"),
                    "originalSha256": hashlib.sha256(b"old").hexdigest(),
                    "appliedSha256": hashlib.sha256(b"applied").hexdigest()}]
        self.seed_state("switched", targets)
        (self.state / "backup.1").write_text("old")
        (self.state / "backup.1").chmod(0o600)
        result = self.run_api("migration_rollback")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rollback conflict", result.stderr)
        self.assertEqual(target.read_text(), "user changed this after switch")
        self.assertNotIn("FORBIDDEN", self.call_log())

    def test_unapplied_target_is_never_restored_or_removed(self):
        target = self.home / ".profile"
        target.write_text("user created before failed switch")
        self.seed_state(targets=[{"path": str(target), "kind": "absent", "mode": "", "uid": "",
                                 "backupFile": "", "originalSha256": "", "appliedSha256": None}])
        result = self.run_api("migration_restore_targets")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(target.exists(), "Rollback removed an unapplied, user-created target")
        self.assertEqual(target.read_text(), "user created before failed switch")

    def test_sdk_install_failure_does_not_apply_configuration(self):
        self.seed_state()
        self.command("mise", 'echo "mise:$*" >> "$CALLS"; exit 17')
        result = self.run_api("migration_install_retained_sdks")
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.state / "state.json").read_text())
        self.assertEqual(state["checkpoints"]["installedVersions"], [])
        self.assertNotIn("chezmoi:", self.call_log())
        self.assertNotIn("uninstall", self.call_log())

    def test_project_sdk_policy_is_read_without_modification(self):
        project = self.scratch / "project"
        project.mkdir()
        original = json.dumps({"sdk": {"version": "8.0.404", "rollForward": "disable"}})
        (project / "global.json").write_text(original)
        result = self.run_api(f"MIGRATION_PROJECTS=({shlex.quote(str(project))}); migration_project_pins")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("8.0.404", result.stdout)
        self.assertEqual((project / "global.json").read_text(), original)

    def test_nested_project_discovery_skips_generated_artifacts(self):
        root = self.scratch / "multi-project-root"
        candidates = (
            root / "functions/SpoFetch.Functions.sln",
            root / "functions/src/SpoFetch.Functions.csproj",
            root / "hosted-agent/tests/SpoFetch.HostedAgent.Tests.csproj",
            root / "artifacts/ui-preview/Fixture.csproj",
            root / "apm_modules/dotnet/skills/Fixture.csproj",
        )
        for candidate in candidates:
            candidate.parent.mkdir(parents=True, exist_ok=True)
            candidate.touch()

        result = self.run_api(f"migration_select_projects {shlex.quote(str(root))}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            set(result.stdout.splitlines()),
            {str(path) for path in candidates[:3]},
        )

    def test_test_target_detection_skips_regular_projects(self):
        project = self.scratch / "MyRssFeederTranslator.csproj"
        project.write_text('<Project><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>')
        test_project = self.scratch / "MyRssFeederTranslator.Tests.csproj"
        test_project.write_text('<Project><PackageReference Include="Microsoft.NET.Test.Sdk" /></Project>')
        result = self.run_api(
            f"if migration_is_test_target {shlex.quote(str(project))}; then echo project-test; else echo project-build; fi; "
            f"if migration_is_test_target {shlex.quote(str(test_project))}; then echo test-project; else echo test-build; fi"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["project-build", "test-project"])

    def test_unknown_cli_flag_never_downloads_or_creates_state(self):
        result = subprocess.run([BASH, str(DRIVER), "--registration-file", str(self.registration)],
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.exists())
        self.assertNotIn("FORBIDDEN", self.call_log())


if __name__ == "__main__":
    unittest.main()
