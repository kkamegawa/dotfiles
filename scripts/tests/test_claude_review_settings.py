"""Tests for managed Claude Code permissions used by Codex review."""

import json
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CHEZMOI = shutil.which("chezmoi")


@unittest.skipUnless(CHEZMOI, "chezmoi is not installed")
class ClaudeReviewSettingsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="claude-review-settings-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home with spaces"
        self.home.mkdir()
        self.config = self.tmp / "chezmoi.toml"
        os_name = platform.system().lower()
        self.config.write_text(
            "[data]\n"
            f"isLinux = {str(os_name == 'linux').lower()}\n"
            f"isMac = {str(os_name == 'darwin').lower()}\n"
            f"isWindows = {str(os_name == 'windows').lower()}\n"
            "isWSL = false\nisDevContainer = false\n",
            encoding="utf-8",
        )
        self.target = self.home / ".claude/settings.json"

    def write_manifest(self, entry=None):
        plugins_dir = self.home / ".claude/plugins"
        plugins_dir.mkdir(parents=True, exist_ok=True)
        plugins = {"codex@openai-codex": [entry]} if entry else {}
        (plugins_dir / "installed_plugins.json").write_text(
            json.dumps({"version": 2, "plugins": plugins}), encoding="utf-8"
        )

    def install(self, version="1.2.3", scope="user", path=None):
        install_path = Path(path) if path else self.home / ".claude/plugins/cache/openai-codex/codex" / version
        script = install_path / "scripts/codex-companion.mjs"
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text("", encoding="utf-8")
        self.write_manifest(
            {"scope": scope, "version": version, "installPath": str(install_path)}
        )
        return install_path

    def apply(self, os_name="linux"):
        self.target.parent.mkdir(parents=True, exist_ok=True)
        override = {"chezmoi": {"homeDir": str(self.home), "os": os_name}}
        return subprocess.run(
            [
                CHEZMOI,
                "--source", str(REPO),
                "--destination", str(self.home),
                "--persistent-state", str(self.tmp / "state.boltdb"),
                "--override-data", json.dumps(override),
                "--config", str(self.config),
                "--no-tty",
                "apply", "--exclude", "scripts", str(self.target),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    def load(self):
        return json.loads(self.target.read_text(encoding="utf-8"))

    def commands(self, data):
        return data.get("sandbox", {}).get("excludedCommands", [])

    def test_installed_user_plugin_defaults_enabled_and_adds_review_commands(self):
        install_path = self.install().as_posix()
        self.assertEqual(self.apply().returncode, 0)
        data = self.load()
        self.assertIs(data["enabledPlugins"]["codex@openai-codex"], True)
        self.assertEqual(data["env"]["DOTFILES_CODEX_FROM_CLAUDE"], "1")
        scripts = f"{install_path}/scripts"
        self.assertIn(scripts, data["permissions"]["additionalDirectories"])
        absolute_prefix = "/" if scripts.startswith("/") else "//"
        self.assertIn(f"Edit({absolute_prefix}{scripts}/**)", data["permissions"]["deny"])
        self.assertIn(scripts, data["sandbox"]["filesystem"]["denyWrite"])
        commands = self.commands(data)
        self.assertEqual(len([c for c in commands if "codex-companion.mjs" in c]), 4)
        self.assertEqual(
            commands[-4:],
            [
                f'node "{install_path}/scripts/codex-companion.mjs" review *',
                f'node "{install_path}/scripts/codex-companion.mjs" status *',
                f'node "{install_path}/scripts/codex-companion.mjs" result *',
                f'node "{install_path}/scripts/codex-companion.mjs" cancel *',
            ],
        )
        self.assertIn("gh *", commands)

    def test_stale_version_is_replaced_and_unrelated_rules_survive(self):
        old = self.install("1.0.6").as_posix()
        old_commands = [
            f'node "{old}/scripts/codex-companion.mjs" {name} *'
            for name in ("review", "status", "result", "cancel")
        ]
        unmanaged = ['node "/custom/path" review *', f'node "{old}/scripts/codex-companion.mjs" setup *']
        old_scripts = f"{old}/scripts"
        absolute_prefix = "/" if old_scripts.startswith("/") else "//"
        old_edit = f"Edit({absolute_prefix}{old_scripts}/**)"
        self.target.parent.mkdir(parents=True, exist_ok=True)
        self.target.write_text(
            json.dumps(
                {
                    "sandbox": {
                        "excludedCommands": old_commands + unmanaged,
                        "filesystem": {"denyWrite": [old_scripts, "~/keep-protected"]},
                    },
                    "permissions": {"additionalDirectories": [old_scripts, "~/keep"], "deny": [old_edit]},
                    "enabledPlugins": {"other@market": True},
                }
            ),
            encoding="utf-8",
        )
        current = self.install("1.0.7").as_posix()
        self.assertEqual(self.apply().returncode, 0)
        data = self.load()
        commands = self.commands(data)
        self.assertTrue(set(old_commands).isdisjoint(commands))
        self.assertEqual(sum(f'"{current}/scripts/codex-companion.mjs"' in c for c in commands), 4)
        self.assertTrue(set(unmanaged).issubset(commands))
        self.assertEqual(data["enabledPlugins"]["other@market"], True)
        self.assertNotIn(old_scripts, data["permissions"]["additionalDirectories"])
        self.assertNotIn(old_edit, data["permissions"]["deny"])
        self.assertCountEqual(data["permissions"]["additionalDirectories"], [f"{current}/scripts", "~/keep"])
        self.assertCountEqual(data["sandbox"]["filesystem"]["denyWrite"], [f"{current}/scripts", "~/keep-protected"])

    def test_explicit_disable_removes_managed_commands_and_is_preserved(self):
        scripts = f"{self.install().as_posix()}/scripts"
        self.assertEqual(self.apply().returncode, 0)
        enabled = self.load()
        enabled["enabledPlugins"]["codex@openai-codex"] = False
        self.target.write_text(json.dumps(enabled), encoding="utf-8")
        self.assertEqual(self.apply().returncode, 0)
        data = self.load()
        self.assertIs(data["enabledPlugins"]["codex@openai-codex"], False)
        self.assertFalse(any("codex-companion.mjs" in c for c in self.commands(data)))
        self.assertIn("gh *", self.commands(data))
        self.assertNotIn(scripts, data["permissions"]["additionalDirectories"])
        self.assertNotIn(scripts, data["sandbox"]["filesystem"]["denyWrite"])

    def test_non_user_invalid_or_missing_installation_does_not_add_commands(self):
        for entry in (
            {"scope": "local", "version": "1.2.3", "installPath": "/tmp/cache"},
            {"scope": "user", "version": "../escape", "installPath": "/tmp/cache"},
            {"scope": "user", "version": "1.2.3", "installPath": "/tmp/untrusted"},
        ):
            with self.subTest(entry=entry):
                self.write_manifest(entry)
                self.target.parent.mkdir(parents=True, exist_ok=True)
                self.target.write_text(json.dumps({"sandbox": {"excludedCommands": [
                    'node "' + (self.home / ".claude/plugins/cache/openai-codex/codex/1.0.6/scripts/codex-companion.mjs").as_posix() + '" review *',
                    "gh *",
                ]}}), encoding="utf-8")
                self.assertEqual(self.apply().returncode, 0)
                data = self.load()
                self.assertFalse(any("codex-companion.mjs" in c for c in self.commands(data)))
                self.assertIn("gh *", self.commands(data))
                self.assertIs(data["enabledPlugins"]["codex@openai-codex"], True)

    def test_windows_does_not_add_shell_sandbox_exceptions(self):
        scripts = f"{self.install().as_posix()}/scripts"
        self.assertEqual(self.apply(os_name="windows").returncode, 0)
        data = self.load()
        self.assertFalse(any("codex-companion.mjs" in c for c in self.commands(data)))
        self.assertIn(scripts, data["permissions"]["additionalDirectories"])
        self.assertNotIn(scripts, data["sandbox"]["filesystem"].get("denyWrite", []))


if __name__ == "__main__":
    unittest.main()
