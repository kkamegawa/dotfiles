"""Tests for the managed-key merge of ~/.codex/config.toml and ~/.claude/settings.json.

Each test applies the modify_ templates with a real chezmoi binary against a
scratch destination and persistent state, so the real home directory is never touched.
Run: python -m unittest discover -s scripts/tests
"""

import json
import os
import platform
import re
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
                "apply", "--exclude", "scripts", str(target),
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
            '[shell_environment_policy.set]\nPATH = "/opt/unmanaged/bin:/usr/bin"\nAPP_CACHE = "/app/cache"\n'
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
        env = data["shell_environment_policy"]["set"]
        self.assertEqual(env["APP_CACHE"], "/app/cache")
        if platform.system() == "Darwin":
            self.assertIn("/opt/unmanaged/bin", env["PATH"].split(":"))
        else:
            self.assertEqual(env["PATH"], "/opt/unmanaged/bin:/usr/bin")

    def test_integers_stay_integers(self):
        self.apply(self.dest / self.REL)
        data = self.load()
        self.assertIsInstance(data["features"]["multi_agent_v2"]["min_wait_timeout_ms"], int)

    def test_environment_overlay_keeps_common_dotnet_caches(self):
        self.apply(self.dest / self.REL)
        data = self.load()
        env = data["shell_environment_policy"]["set"]
        self.assertTrue(env["DOTNET_CLI_HOME"].endswith("dotnet-cli"))
        self.assertTrue(env["NUGET_PACKAGES"].endswith("nuget-packages"))
        if platform.system() == "Darwin":
            shared_root = (Path.home() / ".local/share/mise/dotnet-root").as_posix()
            self.assertEqual(env["DOTNET_ROOT"], shared_root)
            self.assertIn("DOTNET_ROOT_ARM64" if platform.machine() == "arm64" else "DOTNET_ROOT_X64", env)
            managed_path = env["PATH"].split(os.pathsep)
            self.assertEqual(
                managed_path[:4],
                [
                    shared_root,
                    (Path.home() / ".dotnet/tools").as_posix(),
                    (Path.home() / ".local/bin").as_posix(),
                    (Path.home() / ".local/share/mise/shims").as_posix(),
                ],
            )
            self.assertEqual(len(managed_path), len(set(managed_path)))
        else:
            self.assertNotIn("DOTNET_ROOT", env)
            self.assertNotIn("PATH", env)

    def test_path_merge_preserves_entries_without_duplicate_growth(self):
        target = self.write(
            self.REL,
            '[shell_environment_policy.set]\nPATH = '
            f'"/opt/unmanaged/bin{os.pathsep}/usr/bin{os.pathsep}/opt/unmanaged/bin"\n',
        )
        self.assertEqual(self.apply(target).returncode, 0)
        first = target.read_bytes()
        merged_path = self.load()["shell_environment_policy"]["set"]["PATH"]
        if platform.system() == "Darwin":
            path_entries = merged_path.split(":")
            self.assertIn("/opt/unmanaged/bin", path_entries)
            self.assertEqual(len(path_entries), len(set(path_entries)))
        else:
            self.assertEqual(merged_path, f"/opt/unmanaged/bin{os.pathsep}/usr/bin{os.pathsep}/opt/unmanaged/bin")
        self.assertEqual(self.apply(target).returncode, 0)
        self.assertEqual(target.read_bytes(), first)

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

    def test_command_hook_registration_and_deployment(self):
        # Override homeDir as well as destination: all hook paths are scratch paths.
        self.dest = self.tmp / "home space 日本語"
        self.dest.mkdir()
        target = self.dest / self.REL
        target.parent.mkdir(parents=True)
        foreign = {"matcher": "^Bash$", "hooks": [{"type": "command", "command": "user-hook"}]}
        override = json.dumps({"chezmoi": {"homeDir": self.dest.as_posix()}})
        suffix = "ps1" if IS_WINDOWS else "sh"
        script = self.dest / ".claude/hooks" / f"leading-assignment.{suffix}"
        stale = {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "old", "args": [script.as_posix()]}],
        }
        directory_script = script.with_name(f"deny-cd.{suffix}")
        stale_directory = {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "old", "args": [directory_script.as_posix()]}],
        }
        target.write_text(
            json.dumps({"hooks": {"PreToolUse": [foreign, stale, stale_directory]}}),
            encoding="utf-8",
        )
        argv = [
            CHEZMOI, "--source", str(REPO), "--destination", str(self.dest),
            "--persistent-state", str(self.tmp / "state.boltdb"),
            "--config", str(self.config), "--override-data", override, "--no-tty",
            "apply", "--exclude", "scripts", str(self.dest / ".claude/hooks"), str(target),
        ]
        result = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stderr)
        first = target.read_bytes()
        data = self.load()
        entries = data["hooks"]["PreToolUse"]
        for managed_script in (script, directory_script):
            with self.subTest(script=managed_script.name):
                managed_entries = [
                    entry for entry in entries
                    if any(managed_script.as_posix() in hook.get("args", []) for hook in entry["hooks"])
                ]
                self.assertEqual(len(managed_entries), 1)
                entry = managed_entries[0]
                hook = entry["hooks"][0]
                self.assertEqual(entry["matcher"], "^(Bash|PowerShell|powershell)$" if IS_WINDOWS else "^Bash$")
                self.assertEqual(hook["command"], "pwsh" if IS_WINDOWS else "sh")
                self.assertEqual(
                    hook["args"],
                    ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", managed_script.as_posix()]
                    if IS_WINDOWS else [managed_script.as_posix()],
                )
                self.assertEqual(hook["timeout"], 10)
                self.assertEqual(hook["type"], "command")
                self.assertTrue(managed_script.is_file())
                other = managed_script.with_suffix(".sh" if IS_WINDOWS else ".ps1")
                self.assertFalse(other.exists())
        self.assertIn(foreign, entries)
        self.assertEqual(len(entries), 4)  # Three independent managed hooks + foreign.
        guards = [h for h in self.hook_commands(data, "PreToolUse") if h["command"] == "node"]
        self.assertEqual(len(guards), 1)
        self.assertEqual(guards[0]["args"], [f"{self.dest.as_posix()}/.claude/hooks/guard.mjs"])
        self.assertTrue((script.parent / "guard.mjs").is_file())
        result = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), first)

    def test_command_hook_templates_for_all_operating_systems(self):
        home = 'C:/home space 日本語 "quoted"'
        for os_name in ("windows", "darwin", "linux"):
            with self.subTest(os=os_name):
                result = subprocess.run(
                    [
                        CHEZMOI, "--source", str(REPO),
                        "--destination", str(self.dest),
                        "--persistent-state", str(self.tmp / "state.boltdb"),
                        "--config", str(self.config), "--no-tty",
                        "--override-data", json.dumps({"chezmoi": {"os": os_name, "homeDir": home}}),
                        "execute-template", '{{ includeTemplate "claude/common.json" . }}',
                    ],
                    capture_output=True, text=True, encoding="utf-8",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                # Other legacy paths are interpolated without JSON escaping.
                # Parse only the two serialized command entries, leaving legacy
                # interpolation unchanged, including the original node guard.
                entries = []
                for match in re.finditer(r'"matcher": "\^', result.stdout):
                    entry, _ = json.JSONDecoder().raw_decode("{" + result.stdout[match.start():])
                    entries.append(entry)
                self.assertEqual(len(entries), 2)
                windows = os_name == "windows"
                for name, entry in zip(("leading-assignment", "deny-cd"), entries):
                    hook = entry["hooks"][0]
                    path = f"{home}/.claude/hooks/{name}." + ("ps1" if windows else "sh")
                    self.assertEqual(hook["command"], "pwsh" if windows else "sh")
                    self.assertEqual(
                        hook["args"],
                        ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", path]
                        if windows else [path],
                    )
                    self.assertEqual(hook["timeout"], 10)
                    self.assertEqual(hook["type"], "command")
                    self.assertEqual(entry["matcher"], "^(Bash|PowerShell|powershell)$" if windows else "^Bash$")
                ignored = subprocess.run(
                    [
                        CHEZMOI, "--source", str(REPO),
                        "--destination", str(self.dest),
                        "--persistent-state", str(self.tmp / "state.boltdb"),
                        "--config", str(self.config), "--no-tty",
                        "--override-data", json.dumps({"chezmoi": {"os": os_name}}),
                        "execute-template",
                        (REPO / "home/.chezmoiignore").read_text(encoding="utf-8"),
                    ],
                    capture_output=True, text=True, encoding="utf-8",
                )
                self.assertEqual(ignored.returncode, 0, ignored.stderr)
                excluded = ignored.stdout.splitlines()
                for name in ("leading-assignment", "deny-cd"):
                    self.assertIn(f".claude/hooks/{name}." + ("sh" if windows else "ps1"), excluded)
                    self.assertNotIn(f".claude/hooks/{name}." + ("ps1" if windows else "sh"), excluded)
                self.assertNotIn(".claude/hooks/guard.mjs", excluded)

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

    def test_macos_environment_is_managed_without_dropping_other_env(self):
        self.apply(self.dest / self.REL)
        data = self.load()
        env = data["env"]
        if platform.system() == "Darwin":
            shared_root = (Path.home() / ".local/share/mise/dotnet-root").as_posix()
            self.assertEqual(env["DOTNET_ROOT"], shared_root)
            self.assertEqual(
                data["sandbox"]["filesystem"]["allowRead"],
                ["~/.local/share/mise", "~/.config/mise", "~/.dotnet", "~/.nuget"],
            )
            self.assertEqual(
                data["permissions"]["additionalDirectories"],
                ["~/.local/share/mise", "~/.config/mise", "~/.dotnet", "~/.nuget"],
            )
            self.assertIn("DOTNET_ROOT_ARM64" if platform.machine() == "arm64" else "DOTNET_ROOT_X64", env)
            managed_path = env["PATH"].split(os.pathsep)
            self.assertEqual(managed_path[0], shared_root)
            self.assertIn((Path.home() / ".local/bin").as_posix(), managed_path)
            self.assertIn((Path.home() / ".dotnet/tools").as_posix(), managed_path)
            self.assertIn((Path.home() / ".local/share/mise/shims").as_posix(), managed_path)
            self.assertEqual(len(managed_path), len(set(managed_path)))
        else:
            self.assertNotIn("DOTNET_ROOT", env)
            self.assertNotIn("PATH", env)
            self.assertNotIn("allowRead", data.get("sandbox", {}).get("filesystem", {}))
            dotnet_paths = {
                "~/.local/share/mise",
                "~/.config/mise",
                "~/.dotnet",
                "~/.nuget",
            }
            self.assertTrue(
                dotnet_paths.isdisjoint(data["permissions"].get("additionalDirectories", []))
            )

    def test_local_keys_and_extras_survive(self):
        target = self.write(
            self.REL,
            json.dumps(
                {
                    "model": "sonnet",
                    "env": {"APP_OWNED_VALUE": "preserve", "DOTNET_CLI_HOME": "/app/cache"},
                    "enabledPlugins": {"x@inline": True},
                    "permissions": {
                        "allow": ["Bash(make:*)"],
                        "deny": ["Bash(local-deny)"],
                        "additionalDirectories": ["/tmp/user-workspace"],
                    },
                    "sandbox": {"filesystem": {"allowRead": ["/tmp/user-readable"]}},
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
        self.assertEqual(data["env"]["APP_OWNED_VALUE"], "preserve")
        self.assertEqual(data["env"]["DOTNET_CLI_HOME"], "/app/cache")
        self.assertEqual(data["enabledPlugins"], {"x@inline": True})
        self.assertIn("Bash(make:*)", data["permissions"]["allow"])
        self.assertIn("Bash(git status:*)", data["permissions"]["allow"])
        self.assertIn("Bash(local-deny)", data["permissions"]["deny"])
        self.assertIn("/tmp/user-workspace", data["permissions"]["additionalDirectories"])
        self.assertIn("/tmp/user-readable", data["sandbox"]["filesystem"]["allowRead"])
        if platform.system() == "Darwin":
            self.assertEqual(
                set(data["sandbox"]["filesystem"]["allowRead"]),
                {
                    "/tmp/user-readable",
                    "~/.local/share/mise",
                    "~/.config/mise",
                    "~/.dotnet",
                    "~/.nuget",
                },
            )
            self.assertEqual(
                set(data["permissions"]["additionalDirectories"]),
                {
                    "/tmp/user-workspace",
                    "~/.local/share/mise",
                    "~/.config/mise",
                    "~/.dotnet",
                    "~/.nuget",
                },
            )
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
