"""Tests for the managed-key merge of ~/.codex/config.toml and ~/.claude/settings.json.

Each test applies the modify_ templates with a real chezmoi binary against a
scratch destination and persistent state, so the real home directory is never touched.
Run: python -m unittest discover -s scripts/tests
"""

import json
import os
import platform
import shutil
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
IS_WINDOWS = platform.system() == "Windows"
CLAUDE_HOME = (Path.home() / ".claude").as_posix()
CHEZMOI = shutil.which("chezmoi")


@unittest.skipUnless(CHEZMOI, "chezmoi is not installed")
class MergeTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="cfg-merge-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.dest = self.tmp / "dest"
        self.dest.mkdir()
        self.config = self.tmp / "chezmoi.toml"
        self.config.write_text(
            "[data]\n"
            f"isLinux = {str(platform.system() == 'Linux').lower()}\n"
            f"isMac = {str(platform.system() == 'Darwin').lower()}\n"
            f"isWindows = {str(IS_WINDOWS).lower()}\n"
            "isWSL = false\nisDevContainer = false\n",
            encoding="utf-8",
        )

    def apply(self, target: Path) -> subprocess.CompletedProcess:
        # A whole-tree apply creates the parent directory; a single-target apply needs it to exist.
        target.parent.mkdir(parents=True, exist_ok=True)
        return subprocess.run(
            [
                CHEZMOI,
                "--source", str(REPO),
                "--destination", str(self.dest),
                "--persistent-state", str(self.tmp / "state.boltdb"),
                "--config", str(self.config),
                "--no-tty",
                "apply", str(target),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    def write(self, rel: str, text: str) -> Path:
        path = self.dest / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="")
        return path


class CodexMergeTest(MergeTestCase):
    REL = ".codex/config.toml"

    def load(self) -> dict:
        return tomllib.loads((self.dest / self.REL).read_text(encoding="utf-8"))

    def test_fresh_file_gets_managed_keys(self):
        result = self.apply(self.dest / self.REL)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.load()
        self.assertEqual(data["agents"]["default_subagent_model"], "gpt-6-luna")
        self.assertEqual(data["approval_policy"], "on-request")
        self.assertNotIn("node_repl", data.get("mcp_servers", {}))
        self.assertNotIn("plugins", data)

    def test_app_owned_keys_survive_and_managed_keys_win(self):
        target = self.write(
            self.REL,
            'allow_login_shell = true\n'
            '[agents]\ndefault_subagent_model = "old"\nkeep = 1\n'
            '[mcp_servers.node_repl.env]\nBROWSER_USE_CODEX_APP_VERSION = "9"\n'
            '[plugins."code-review@openai-bundled"]\nenabled = true\n'
            '[projects."/work/repo"]\ntrust_level = "trusted"\n',
        )
        result = self.apply(target)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.load()
        self.assertEqual(data["agents"]["default_subagent_model"], "gpt-6-luna")
        self.assertEqual(data["agents"]["keep"], 1)
        self.assertIs(data["allow_login_shell"], False)
        self.assertEqual(data["mcp_servers"]["node_repl"]["env"]["BROWSER_USE_CODEX_APP_VERSION"], "9")
        self.assertTrue(data["plugins"]["code-review@openai-bundled"]["enabled"])
        self.assertEqual(data["projects"]["/work/repo"]["trust_level"], "trusted")

    def test_integers_stay_integers(self):
        self.apply(self.dest / self.REL)
        data = self.load()
        self.assertIsInstance(data["features"]["multi_agent_v2"]["min_wait_timeout_ms"], int)

    def test_second_apply_changes_nothing(self):
        target = self.dest / self.REL
        self.assertEqual(self.apply(target).returncode, 0)
        first = target.read_bytes()
        self.assertEqual(self.apply(target).returncode, 0)
        self.assertEqual(target.read_bytes(), first)

    def test_invalid_input_fails_and_keeps_file(self):
        target = self.write(self.REL, "bad [[[\n")
        result = self.apply(target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(encoding="utf-8"), "bad [[[\n")

    @unittest.skipUnless(IS_WINDOWS, "Windows only")
    def test_windows_sandbox_is_managed_on_windows(self):
        self.apply(self.dest / self.REL)
        self.assertEqual(self.load()["windows"]["sandbox"], "mxc")

    @unittest.skipIf(IS_WINDOWS, "non-Windows only")
    def test_windows_sandbox_absent_elsewhere(self):
        self.apply(self.dest / self.REL)
        self.assertNotIn("windows", self.load())


class ClaudeMergeTest(MergeTestCase):
    REL = ".claude/settings.json"

    def load(self) -> dict:
        return json.loads((self.dest / self.REL).read_text(encoding="utf-8"))

    def hook_commands(self, data: dict, event: str) -> list:
        return [
            hook
            for entry in data["hooks"].get(event, [])
            for hook in entry.get("hooks", [])
        ]

    def test_fresh_file_gets_managed_keys(self):
        result = self.apply(self.dest / self.REL)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.load()
        self.assertEqual(data["env"]["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "60")
        self.assertEqual(data["statusLine"]["args"], [f"{CLAUDE_HOME}/hooks/statusline.mjs"])
        self.assertNotIn("enabledPlugins", data)

    def test_local_keys_and_extras_survive(self):
        target = self.write(
            self.REL,
            json.dumps(
                {
                    "model": "sonnet",
                    "enabledPlugins": {"x@inline": True},
                    "permissions": {"allow": ["Bash(make:*)"], "deny": ["Bash(local-deny)"]},
                    "hooks": {
                        "SessionStart": [{"hooks": [{"type": "command", "command": "/opt/orca/hook"}]}],
                    },
                }
            ),
        )
        result = self.apply(target)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.load()
        self.assertEqual(data["model"], "opusplan")
        self.assertEqual(data["enabledPlugins"], {"x@inline": True})
        self.assertIn("Bash(make:*)", data["permissions"]["allow"])
        self.assertIn("Bash(git status:*)", data["permissions"]["allow"])
        self.assertIn("Bash(local-deny)", data["permissions"]["deny"])
        self.assertEqual(self.hook_commands(data, "SessionStart")[0]["command"], "/opt/orca/hook")

    def test_owned_hook_is_replaced_not_duplicated(self):
        stale = {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "node", "args": [f"{CLAUDE_HOME}/hooks/guard.mjs"], "timeout": 99}],
        }
        foreign = {"matcher": "Bash", "hooks": [{"type": "command", "command": "/opt/other/hook"}]}
        target = self.write(self.REL, json.dumps({"hooks": {"PreToolUse": [stale, foreign]}}))
        self.assertEqual(self.apply(target).returncode, 0)
        hooks = self.hook_commands(self.load(), "PreToolUse")
        guards = [h for h in hooks if h.get("args") == [f"{CLAUDE_HOME}/hooks/guard.mjs"]]
        self.assertEqual(len(guards), 1)
        self.assertEqual(guards[0]["timeout"], 10)
        self.assertEqual(sum(1 for h in hooks if h.get("command") == "/opt/other/hook"), 1)

    def test_second_apply_changes_nothing(self):
        target = self.write(self.REL, json.dumps({"permissions": {"allow": ["Bash(make:*)"]}}))
        self.assertEqual(self.apply(target).returncode, 0)
        first = target.read_bytes()
        self.assertEqual(self.apply(target).returncode, 0)
        self.assertEqual(target.read_bytes(), first)

    def test_invalid_input_fails_and_keeps_file(self):
        target = self.write(self.REL, "{not json")
        result = self.apply(target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(encoding="utf-8"), "{not json")

    def test_os_overlay(self):
        self.apply(self.dest / self.REL)
        permissions = self.load()["permissions"]
        if IS_WINDOWS:
            self.assertIn("Bash(Get-Command:*)", permissions["allow"])
            self.assertIn("Bash(curl:*)", permissions["deny"])
            self.assertNotIn("Bash(ls:*)", permissions["allow"])
        else:
            self.assertIn("Bash(ls:*)", permissions["allow"])
            self.assertNotIn("Bash(curl:*)", permissions["deny"])
            self.assertNotIn("Bash(Get-Command:*)", permissions["allow"])


if __name__ == "__main__":
    unittest.main()
