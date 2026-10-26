"""Exercise complete migration phases with temporary homes and fake commands.

No test downloads a real SDK, invokes real sudo, changes /etc, or touches a real
Homebrew installation. Driver functions are sourced and host/package boundaries
are replaced with fixture commands.
Run: python -m unittest scripts.tests.test_dotnet_migration_flow -v
"""

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

from scripts.tests import test_dotnet_migration as base_migration

BASH = base_migration.BASH
JQ = base_migration.JQ
SHASUM = base_migration.SHASUM


@unittest.skipUnless(os.name == "posix" and BASH and JQ and SHASUM, "POSIX Bash, jq and shasum required")
class MigrationFlowTest(unittest.TestCase):
    """Composition reuses MigrationTest's fixture setup without inheriting its test cases."""

    def setUp(self):
        self.fixture = base_migration.MigrationTest("test_sourcing_has_no_side_effects")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.f = self.fixture
        self.f.state.mkdir(mode=0o700)
        self.f.state.chmod(0o700)
        self.system_sdks = self.f.scratch / "system-sdks.txt"
        self.user_sdks = self.f.scratch / "user-sdks.txt"
        self.shared_sdks = self.f.scratch / "shared-sdks.txt"
        self.system_runtimes = self.f.scratch / "system-runtimes.txt"
        self.user_runtimes = self.f.scratch / "user-runtimes.txt"
        self.shared_runtimes = self.f.scratch / "shared-runtimes.txt"
        self.manifest = self.f.home / ".config/dotfiles/dotnet-retained-sdks.json"
        self.project = self.f.scratch / "project with spaces"
        self.project.mkdir()
        (self.project / "global.json").write_text(
            json.dumps({"sdk": {"version": "9.0.100", "rollForward": "latestPatch"}}),
            encoding="utf-8",
        )
        self.registration_original = "old-system-runtime\n"
        self.f.registration.write_text(self.registration_original, encoding="utf-8")
        self.f.registration.chmod(0o644)
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        self.manifest.write_text(
            json.dumps({"schemaVersion": 1, "versions": ["8.0.404", "7.0.410"]}),
            encoding="utf-8",
        )
        self.managed_target_values = {}
        for index, rel in enumerate(
            (
                ".config/mise/config.toml",
                ".profile",
                "PowerShell_profile.ps1",
                ".gitconfig",
                ".local/bin/dotfiles-dotnet10",
                ".local/share/dotfiles/dotnet10-runner/global.json",
                ".codex/config.toml",
                ".claude/settings.json",
            )
        ):
            path = self.f.home / rel
            if index in (0, 1, 3):
                path.parent.mkdir(parents=True, exist_ok=True)
                content = f"user-owned original {rel}\n"
                path.write_text(content, encoding="utf-8")
                self.managed_target_values[str(path)] = content

        self.package_bytes = b"fixture rollback installer payload"
        self.package_hash = hashlib.sha512(self.package_bytes).hexdigest()
        self.index_file = self.f.scratch / "releases-index.json"
        self.metadata_file = self.f.scratch / "releases.json"
        self.package_fixture = self.f.scratch / "sdk.pkg"
        self.metadata_url = "fixture-release-metadata"
        self.package_url = "fixture-sdk-package"
        self.index_file.write_text(
            json.dumps({"releases-index": [{"channel-version": "10.0", "releases.json": self.metadata_url}]}),
            encoding="utf-8",
        )
        self.metadata_file.write_text(
            json.dumps(
                {
                    "releases": [
                        {
                            "sdk": {
                                "version": "10.0.401",
                                "files": [
                                    {
                                        "rid": "osx-arm64",
                                        "name": "dotnet-sdk-osx-arm64.pkg",
                                        "url": self.package_url,
                                        "hash": self.package_hash,
                                    }
                                ],
                            }
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        self.package_fixture.write_bytes(self.package_bytes)

        self.system_sdks.write_text("10.0.401 [/system/sdk]\n", encoding="utf-8")
        self.user_sdks.write_text("8.0.404 [/user/sdk]\n", encoding="utf-8")
        self.shared_sdks.write_text("", encoding="utf-8")
        self.system_runtimes.write_text("Microsoft.NETCore.App 10.0.12 [/system/shared]\n", encoding="utf-8")
        self.user_runtimes.write_text("Microsoft.NETCore.App 8.0.11 [/user/shared]\n", encoding="utf-8")
        self.shared_runtimes.write_text("Microsoft.NETCore.App 10.0.11 [/shared/runtime]\n", encoding="utf-8")

        self.write_host(self.f.system / "dotnet", self.system_sdks, self.system_runtimes)
        self.write_host(self.f.home / ".dotnet/dotnet", self.user_sdks, self.user_runtimes)
        self.write_host(self.f.root / "dotnet", self.shared_sdks, self.shared_runtimes)
        self.brew_present = self.f.scratch / "brew-cask-present"
        self.brew_present.touch()
        self.sudo_temp = self.f.scratch / "sudo-registration.tmp"
        self.apply_count = self.f.scratch / "chezmoi-apply-count"

        self.f.env.update(
            {
                "SYSTEM_SDKS_FILE": str(self.system_sdks),
                "USER_SDKS_FILE": str(self.user_sdks),
                "SHARED_SDKS_FILE": str(self.shared_sdks),
                "SYSTEM_RUNTIMES_FILE": str(self.system_runtimes),
                "USER_RUNTIMES_FILE": str(self.user_runtimes),
                "SHARED_RUNTIMES_FILE": str(self.shared_runtimes),
                "FAKE_INDEX_FILE": str(self.index_file),
                "FAKE_METADATA_FILE": str(self.metadata_file),
                "FAKE_PACKAGE_FILE": str(self.package_fixture),
                "FAKE_METADATA_URL": self.metadata_url,
                "FAKE_PACKAGE_URL": self.package_url,
                "BREW_PRESENT_FILE": str(self.brew_present),
                "SUDO_TEMP_FILE": str(self.sudo_temp),
                "APPLY_COUNT_FILE": str(self.apply_count),
                "CALLS": str(self.f.calls),
                "FAKE_REGISTRATION": str(self.f.registration),
            }
        )
        self.install_fake_commands()

    def write_host(self, path, sdk_file, runtime_file):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "#!/bin/sh\n"
            'case "$1" in\n'
            f'  --list-sdks) cat {shlex.quote(str(sdk_file))} ;;\n'
            f'  --list-runtimes) cat {shlex.quote(str(runtime_file))} ;;\n'
            '  workload) printf \'NuGet signature verification skipped.\\n==workloadListJsonOutputStart==\\n{"workloads":[]}\\n==workloadListJsonOutputEnd==\\n\' ;;\n'
            '  tool) printf \'Package Id Version Commands\\n\\n\' ;;\n'
            '  --info) printf \'fixture dotnet info\\n\' ;;\n'
            '  --version) printf \'10.0.401\\n\' ;;\n'
            '  *) exit 0 ;;\n'
            'esac\n',
            encoding="utf-8",
        )
        path.chmod(0o755)

    def write_python_command(self, name, body):
        path = self.f.bin / name
        path.write_text("#!" + sys.executable + "\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def install_fake_commands(self):
        self.f.command(
            "mise",
            '''if [ "$1" = --version ]; then echo '2026.10.17 macos-arm64'; exit 0; fi
if [ "$1" = settings ]; then
  [ -n "${MISE_DOTNET_ROOT:-}" ] || exit 1
  exit 0
fi
if [ "$1" = upgrade ] && [ "$2" = --help ]; then echo '--global --exclude --no-prune'; exit 0; fi
echo "mise:$*" >> "$CALLS"
if [ "$1" = install ]; then
  if [ -n "${MISE_FAIL_ON:-}" ] && [ "$2" = "$MISE_FAIL_ON" ]; then exit 17; fi
  printf '10.0.401 [/shared/sdk]\\n9.0.100 [/shared/sdk]\\n8.0.404 [/shared/sdk]\\n7.0.410 [/shared/sdk]\\n6.0.403 [/shared/sdk]\\n' > "$SHARED_SDKS_FILE"
fi
exit 0''',
        )
        curl_body = (
            "#!" + sys.executable + "\n"
            "import os, pathlib, sys\n"
            "args=sys.argv[1:]\n"
            "output_index=args.index('-o')\n"
            "url=args[output_index-1]\n"
            "output=pathlib.Path(args[output_index+1])\n"
            "with open(os.environ['CALLS'],'a',encoding='utf-8') as log: log.write('curl:'+url+'\\n')\n"
            "if url.endswith('releases-index.json'): source=os.environ['FAKE_INDEX_FILE']\n"
            "elif url == os.environ['FAKE_METADATA_URL']: source=os.environ['FAKE_METADATA_FILE']\n"
            "else: source=os.environ['FAKE_PACKAGE_FILE']\n"
            "output.write_bytes(pathlib.Path(source).read_bytes())\n"
        )
        self.write_python_command("curl", curl_body.split("\n", 1)[1])
        self.f.command(
            "brew",
            '''echo "brew:$*" >> "$CALLS"
case "$1:$2" in
  info:--cask) printf '{"casks":[]}\\n' ;;
  list:--cask)
    case "$*" in
      'list --cask --versions dotnet-sdk')
        if [ -f "$BREW_PRESENT_FILE" ]; then echo 'dotnet-sdk 10.0.401'
        else echo "Error: Cask 'dotnet-sdk' is not installed." >&2; exit 1; fi ;;
      *--versions*) echo "Error: Cask 'orchard' is not installed." >&2; exit 1 ;;
      *) [ -f "$BREW_PRESENT_FILE" ]; exit $? ;;
    esac ;;
  uninstall:--cask)
    rm -f "$BREW_PRESENT_FILE"
    : > "$SYSTEM_SDKS_FILE"
    [ "${BREW_FAIL_AFTER_UNINSTALL:-0}" != 1 ] || exit 17 ;;
esac
exit 0''',
        )
        self.f.command(
            "pkgutil",
            '''if [ "$1" = --pkgs ]; then echo com.microsoft.dotnet.sdk; exit 0; fi
if [ "$1" = --check-signature ]; then
  [ "${SIGNATURE_FAIL:-0}" != 1 ] || exit 1
  echo 'Status: signed by a certificate trusted by Mac OS X'
  echo 'Developer ID Installer: Microsoft Corporation (UBF8T346G9)'
  exit 0
fi
exit 1''',
        )
        self.write_python_command(
            "chezmoi",
            "import json, os, pathlib, sys\n"
            "args=sys.argv[1:]\n"
            "if 'apply' not in args: raise SystemExit(0)\n"
            "path=pathlib.Path(args[-1])\n"
            "count_path=pathlib.Path(os.environ['APPLY_COUNT_FILE'])\n"
            "count=int(count_path.read_text() if count_path.exists() else '0')+1\n"
            "count_path.write_text(str(count))\n"
            "with open(os.environ['CALLS'],'a',encoding='utf-8') as log: log.write('chezmoi:'+json.dumps({'target':str(path),'excludeScripts':'--exclude=scripts' in args,'parentDirs':'--parent-dirs' in args})+'\\n')\n"
            "if count == int(os.environ.get('APPLY_FAIL_AT','0')): raise SystemExit(17)\n"
            "path.parent.mkdir(parents=True,exist_ok=True)\n"
            "path.write_text('managed:'+str(path)+'\\n',encoding='utf-8')\n",
        )
        self.f.command(
            "installer",
            '''echo "installer:$*" >> "$CALLS"
printf '10.0.401 [/system/sdk]\\n' > "$SYSTEM_SDKS_FILE"
exit 0''',
        )
        self.f.command(
            "sudo",
            '''echo "sudo:$*" >> "$CALLS"
case "$1" in
  mktemp) : > "$SUDO_TEMP_FILE"; echo "$SUDO_TEMP_FILE" ;;
  tee) cat > "$2" ;;
  chown|chmod) exit 0 ;;
  mv) shift; /bin/mv "$@" ;;
  rm) rm -f "$2" ;;
  *) "$@" ;;
esac''',
        )
        self.f.command("file", 'echo "Mach-O 64-bit arm64"')
        actual_stat = shutil.which("stat")
        self.write_python_command(
            "stat",
            "import os,sys\n"
            "args=sys.argv[1:]\n"
            "fake_registration=os.environ.get('FAKE_REGISTRATION')\n"
            "if len(args)>=3 and args[0]=='-f' and args[2] in (fake_registration, os.path.dirname(fake_registration or '')):\n"
            "    values={'%Su':'root','%u':'0','%Lp':'644'}\n"
            "    if args[1] in values: print(values[args[1]]); raise SystemExit(0)\n"
            f"os.execv({actual_stat!r}, [{actual_stat!r}, *args])\n",
        )

    def flow_prefix(self, *, ide_confirmed=False, mise_fail_on=""):
        projects = shlex.quote(str(self.project))
        return (
            self.f.source_prefix()
            + f"MIGRATION_PROJECTS=({projects})\n"
            + "MIGRATION_SDKS=(6.0.403)\n"
            + f"MIGRATION_FILE_BIN={shlex.quote(str(self.f.bin / 'file'))}\n"
            + f"MIGRATION_IDE_CHECKS_CONFIRMED={1 if ide_confirmed else 0}\n"
            + r'''migration_registration_snapshot() {
  local kind mode uid sha backup
  kind=$(migration_kind "$MIGRATION_REGISTRATION")
  mode=$(stat -f '%Lp' "$MIGRATION_REGISTRATION") || return 1
  uid=$(stat -f '%u' "$MIGRATION_REGISTRATION") || return 1
  sha=$(migration_sha "$MIGRATION_REGISTRATION") || return 1
  backup="$MIGRATION_STATE_DIR/registration.original"
  cp "$MIGRATION_REGISTRATION" "$backup" || return 1
  chmod 600 "$backup" || return 1
  "$MIGRATION_JQ_BIN" -n --arg path "$MIGRATION_REGISTRATION" --arg kind "$kind" --arg mode "$mode" --arg uid "$uid" --arg sha "$sha" --arg backup "$backup" --arg desired "$MIGRATION_SHARED_ROOT" '{path:$path,kind:$kind,mode:$mode,uid:$uid,originalSha256:$sha,backupFile:$backup,desired:$desired}'
}
migration_running_apps() { return 0; }
migration_write_registration() { printf '%s\n' "$1" > "$MIGRATION_REGISTRATION"; echo "registration:$1" >> "$CALLS"; }
migration_verify_critical_consumers() { echo consumer-checks >> "$CALLS"; return 0; }
'''
            + (f"export MISE_FAIL_ON={shlex.quote(mise_fail_on)}\n" if mise_fail_on else "")
        )

    def run_flow(self, script, *, ide_confirmed=False, mise_fail_on="", timeout=40):
        return subprocess.run(
            [BASH, "-c", self.flow_prefix(ide_confirmed=ide_confirmed, mise_fail_on=mise_fail_on) + script],
            env=self.f.env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def state(self):
        return json.loads((self.f.state / "state.json").read_text(encoding="utf-8"))

    def call_lines(self):
        return self.f.call_log().splitlines()

    def prepare_successfully(self):
        result = self.run_flow("migration_prepare")
        self.assertEqual(result.returncode, 0, result.stderr + "\n" + self.f.call_log())
        self.assertEqual(self.state()["phase"], "prepared")

    def set_phase(self, phase):
        result = self.run_flow(f"migration_update_state --arg p {shlex.quote(phase)} '.phase=$p'")
        self.assertEqual(result.returncode, 0, result.stderr)

    def register_shared_root(self):
        result = self.run_flow('migration_write_registration "$MIGRATION_SHARED_ROOT"')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_prepare_archives_fixture_package_and_unions_inventory_and_manifest_pins(self):
        result = self.run_flow("migration_prepare")
        self.assertEqual(result.returncode, 0, result.stderr + "\n" + self.f.call_log())
        state = self.state()
        self.assertEqual(state["phase"], "prepared")
        expected = {"10.0.401", "8.0.404", "9.0.100", "6.0.403", "7.0.410"}
        self.assertTrue(expected.issubset(set(state["retainedVersions"])))
        self.assertEqual(set(state["inventory"]["oldSystemSdks"]), {"10.0.401"})
        self.assertEqual(set(state["inventory"]["oldUserSdks"]), {"8.0.404"})
        self.assertEqual(state["inventory"]["oldSharedSdks"], [])
        self.assertEqual(json.loads(Path(state["inventory"]["workloadsFile"]).read_text()), {"workloads": []})
        self.assertEqual(state["package"]["sha512"], self.package_hash)
        self.assertTrue(state["package"]["signatureVerified"])
        self.assertEqual(set(json.loads(self.manifest.read_text())["versions"]), expected)
        self.assertTrue((self.f.state / "original.pkg").exists() is False)
        self.assertTrue(Path(state["package"]["file"]).is_file())
        self.assertIn("mise:install dotnet@10.0.401", self.f.call_log())
        self.assertIn("mise:install dotnet@8.0.404", self.f.call_log())

    def test_failed_prepare_remains_resumable_and_keeps_original_backups(self):
        first = self.run_flow("migration_prepare", mise_fail_on="dotnet@8.0.404")
        self.assertNotEqual(first.returncode, 0)
        state_before = self.state()
        self.assertEqual(state_before["phase"], "preparing")
        before_switch = self.f.call_log()
        switch = self.run_flow("migration_switch")
        self.assertNotEqual(switch.returncode, 0)
        self.assertIn("switch requires prepared state", switch.stderr)
        self.assertEqual(self.f.registration.read_text(encoding="utf-8"), self.registration_original)
        self.assertEqual(
            [line for line in self.f.call_log().splitlines() if line.startswith("chezmoi:")],
            [line for line in before_switch.splitlines() if line.startswith("chezmoi:")],
        )
        backup_files = [Path(target["backupFile"]) for target in state_before["targets"] if target["backupFile"]]
        backup_files.append(Path(state_before["manifest"]["backupFile"]))
        backup_bytes = {path: path.read_bytes() for path in backup_files}
        self.assertEqual(backup_bytes[Path(state_before["manifest"]["backupFile"])],
                         json.dumps({"schemaVersion": 1, "versions": ["8.0.404", "7.0.410"]}).encode())
        second = self.run_flow("migration_prepare")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.state()["phase"], "prepared")
        for path, content in backup_bytes.items():
            self.assertEqual(path.read_bytes(), content, f"prepare resume replaced original backup {path}")

    def test_switch_applies_every_approved_target_and_excludes_scripts(self):
        self.prepare_successfully()
        result = self.run_flow("migration_switch")
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.state()
        self.assertEqual(state["phase"], "switched")
        expected = {
            str(self.f.home / rel)
            for rel in (
                ".config/mise/config.toml",
                ".profile",
                "PowerShell_profile.ps1",
                ".gitconfig",
                ".local/bin/dotfiles-dotnet10",
                ".local/share/dotfiles/dotnet10-runner/global.json",
                ".codex/config.toml",
                ".claude/settings.json",
            )
        }
        applies = [json.loads(line[len("chezmoi:") :]) for line in self.call_lines() if line.startswith("chezmoi:")]
        self.assertEqual({item["target"] for item in applies}, expected)
        self.assertEqual(len(applies), len(expected))
        self.assertTrue(all(item["excludeScripts"] for item in applies))
        self.assertTrue(all(item["parentDirs"] for item in applies))
        self.assertEqual(set(state["checkpoints"]["appliedTargets"]), expected)

    def test_failed_second_target_resume_refuses_to_overwrite_user_edit(self):
        self.prepare_successfully()
        self.f.env["APPLY_FAIL_AT"] = "2"
        failed = self.run_flow("migration_switch")
        self.assertNotEqual(failed.returncode, 0)
        state = self.state()
        first_target = str(self.f.home / ".config/mise/config.toml")
        self.assertIn(first_target, state["checkpoints"]["appliedTargets"])
        managed_target = Path(first_target)
        managed_target.write_text("user edit after partial switch\n", encoding="utf-8")
        previous_calls = len([line for line in self.call_lines() if line.startswith("chezmoi:")])
        self.f.env.pop("APPLY_FAIL_AT")
        resumed = self.run_flow("migration_switch")
        self.assertNotEqual(resumed.returncode, 0)
        self.assertIn("changed since checkpoint", resumed.stderr)
        self.assertEqual(managed_target.read_text(encoding="utf-8"), "user edit after partial switch\n")
        new_calls = len([line for line in self.call_lines() if line.startswith("chezmoi:")])
        self.assertEqual(new_calls, previous_calls)

    def test_resume_retries_checkpointed_target_that_was_not_created(self):
        self.prepare_successfully()
        self.f.env["APPLY_FAIL_AT"] = "6"
        failed = self.run_flow("migration_switch")
        self.assertNotEqual(failed.returncode, 0)
        missing_target = self.f.home / ".local/share/dotfiles/dotnet10-runner/global.json"
        self.assertFalse(missing_target.exists())
        self.assertIn(str(missing_target), self.state()["checkpoints"]["appliedTargets"])

        self.f.env.pop("APPLY_FAIL_AT")
        resumed = self.run_flow("migration_switch")
        self.assertEqual(resumed.returncode, 0, resumed.stderr + "\\n" + self.f.call_log())
        self.assertTrue(missing_target.is_file())

    def prepare_verified(self):
        self.prepare_successfully()
        self.set_phase("verified")
        self.register_shared_root()

    def test_finalize_checks_attestation_and_package_integrity_before_homebrew(self):
        self.prepare_verified()
        self.f.calls.write_text("", encoding="utf-8")
        no_attestation = self.run_flow("migration_finalize")
        self.assertNotEqual(no_attestation.returncode, 0)
        self.assertIn("ide-checks-confirmed", no_attestation.stderr)
        self.assertNotIn("brew:", self.f.call_log())

        self.f.calls.write_text("", encoding="utf-8")
        package = Path(self.state()["package"]["file"])
        package.write_bytes(b"corrupt package")
        corrupt = self.run_flow("migration_finalize", ide_confirmed=True)
        self.assertNotEqual(corrupt.returncode, 0)
        self.assertIn("installer is missing or has changed", corrupt.stderr)
        self.assertNotIn("brew:", self.f.call_log())
        self.assertTrue(self.brew_present.exists())

    def test_finalize_resumes_after_uninstall_without_uninstalling_twice(self):
        self.prepare_verified()
        self.f.calls.write_text("", encoding="utf-8")
        self.f.env["BREW_FAIL_AFTER_UNINSTALL"] = "1"
        interrupted = self.run_flow("migration_finalize", ide_confirmed=True)
        self.assertNotEqual(interrupted.returncode, 0)
        self.assertEqual(self.state()["phase"], "finalizing")
        self.assertFalse(self.brew_present.exists())
        self.f.env.pop("BREW_FAIL_AFTER_UNINSTALL")
        resumed = self.run_flow("migration_finalize", ide_confirmed=True)
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(self.state()["phase"], "awaiting-final-attestation")
        finalized = self.run_flow("migration_finalize", ide_confirmed=True)
        self.assertEqual(finalized.returncode, 0, finalized.stderr)
        self.assertEqual(self.state()["phase"], "finalized")
        uninstall_calls = [line for line in self.call_lines() if line == "brew:uninstall --cask dotnet-sdk"]
        self.assertEqual(len(uninstall_calls), 1)

    def test_rollback_keeps_unapplied_user_file_and_restores_manifest(self):
        self.prepare_successfully()
        user_file = self.f.home / ".profile"
        original = user_file.read_text(encoding="utf-8")
        user_file.write_text("user content created after prepare\n", encoding="utf-8")
        result = self.run_flow("migration_rollback")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(user_file.read_text(encoding="utf-8"), "user content created after prepare\n")
        self.assertEqual(
            json.loads(self.manifest.read_text(encoding="utf-8")),
            {"schemaVersion": 1, "versions": ["8.0.404", "7.0.410"]},
        )
        self.assertEqual(self.state()["phase"], "rolled-back")
        self.assertNotEqual(original, user_file.read_text(encoding="utf-8"))

    def test_rollback_conflicts_preserve_manifest_and_registration(self):
        self.prepare_successfully()
        self.manifest.write_text('{"schemaVersion":1,"versions":["5.0.100"]}', encoding="utf-8")
        user_profile = self.f.home / ".profile"
        user_profile.write_text("user edit that must survive\n", encoding="utf-8")
        registration_conflict = "unexpected registration value\n"
        self.f.registration.write_text(registration_conflict, encoding="utf-8")
        result = self.run_flow("migration_rollback")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retained SDK manifest changed", result.stderr)
        self.assertEqual(self.manifest.read_text(encoding="utf-8"), '{"schemaVersion":1,"versions":["5.0.100"]}')
        self.assertEqual(user_profile.read_text(encoding="utf-8"), "user edit that must survive\n")
        self.assertEqual(self.f.registration.read_text(encoding="utf-8"), registration_conflict)
        self.assertEqual(self.state()["phase"], "prepared")

    def test_rollback_refuses_registration_conflict_without_touching_manifest(self):
        self.prepare_successfully()
        manifest_before = self.manifest.read_bytes()
        registration_conflict = "unexpected registration value\n"
        self.f.registration.write_text(registration_conflict, encoding="utf-8")
        result = self.run_flow("migration_rollback")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("architecture registration changed", result.stderr)
        self.assertEqual(self.manifest.read_bytes(), manifest_before)
        self.assertEqual(self.f.registration.read_text(encoding="utf-8"), registration_conflict)

    def test_rollback_restores_runtime_before_registration(self):
        self.prepare_successfully()
        switched = self.run_flow("migration_switch")
        self.assertEqual(switched.returncode, 0, switched.stderr)
        self.system_sdks.write_text("", encoding="utf-8")
        self.f.calls.write_text("", encoding="utf-8")
        result = self.run_flow("migration_rollback")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("10.0.401", self.system_sdks.read_text(encoding="utf-8"))
        self.assertEqual(self.f.registration.read_text(encoding="utf-8"), self.registration_original)
        calls = self.call_lines()
        installer_index = next(index for index, line in enumerate(calls) if line.startswith("installer:"))
        register_index = next(index for index, line in enumerate(calls) if line.startswith("sudo:mktemp"))
        self.assertLess(installer_index, register_index)
        self.assertEqual(self.state()["phase"], "rolled-back")


if __name__ == "__main__":
    unittest.main()
