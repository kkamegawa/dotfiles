"""Isolated contract tests for the macOS mise/.NET environment configuration.

These tests render templates in scratch homes and use fake executables. They do
not install, upgrade, prune, or execute a real .NET SDK.
Run: python -m unittest scripts.tests.test_dotnet_environment -v
"""

import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CHEZMOI = shutil.which("chezmoi")
SHELL = shutil.which("sh")


@unittest.skipUnless(CHEZMOI, "chezmoi is not installed")
class MiseTemplateTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="dotnet-mise-template-"))
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.home = self.temp / "home"
        self.home.mkdir()
        self.config = self.temp / "chezmoi.toml"
        self.config.write_text(
            "[data]\n"
            "isLinux = false\n"
            "isMac = true\n"
            "isWindows = false\n"
            "isWSL = false\n"
            "isDevContainer = false\n",
            encoding="utf-8",
        )

    def render_mise_config(self, os_name="darwin", architecture="arm64"):
        override_data = json.dumps({"chezmoi": {"os": os_name, "arch": architecture}})
        return subprocess.run(
            [
                CHEZMOI,
                "--source",
                str(REPO),
                "--destination",
                str(self.home),
                "--config",
                str(self.config),
                "--override-data",
                override_data,
                "--no-tty",
                "execute-template",
                "--file",
                "home/dot_config/mise/config.toml.tmpl",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env={**os.environ, "HOME": str(self.home), "USERPROFILE": str(self.home)},
        )

    def test_absent_manifest_renders_base_channels(self):
        result = self.render_mise_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = tomllib.loads(result.stdout)
        self.assertEqual(data["tools"]["dotnet"], ["10", "8"])
        self.assertEqual(
            data["settings"]["dotnet"]["dotnet_root"],
            str(self.home / ".local/share/mise/dotnet-root"),
        )
        self.assertIs(data["settings"]["dotnet"]["isolated"], False)

    def test_dotnet_tool_and_root_are_darwin_only_across_os_matrix(self):
        for os_name, architecture in (
            ("darwin", "arm64"),
            ("darwin", "amd64"),
            ("linux", "amd64"),
            ("windows", "amd64"),
        ):
            with self.subTest(os=os_name, arch=architecture):
                result = self.render_mise_config(os_name, architecture)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = tomllib.loads(result.stdout)
                if os_name == "darwin":
                    self.assertEqual(data["tools"]["dotnet"], ["10", "8"])
                    self.assertEqual(
                        data["settings"]["dotnet"]["dotnet_root"],
                        str(self.home / ".local/share/mise/dotnet-root"),
                    )
                    self.assertIs(data["settings"]["dotnet"]["isolated"], False)
                else:
                    self.assertNotIn("dotnet", data["tools"])
                    self.assertNotIn("dotnet", data["settings"])

    def test_retained_sdk_manifest_is_merged_into_dotnet_tool_list(self):
        manifest = self.home / ".config/dotfiles/dotnet-retained-sdks.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(
            json.dumps({"schemaVersion": 1, "versions": ["10.0.401", "8.0.404"]}),
            encoding="utf-8",
        )
        result = self.render_mise_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = tomllib.loads(result.stdout)
        self.assertEqual(data["tools"]["dotnet"], ["10", "8", "10.0.401", "8.0.404"])

    def test_malformed_or_unknown_manifest_fails_closed(self):
        manifest = self.home / ".config/dotfiles/dotnet-retained-sdks.json"
        manifest.parent.mkdir(parents=True)
        invalid_documents = [
            "{invalid json",
            json.dumps({"schemaVersion": 2, "versions": ["10.0.401"]}),
            json.dumps({"schemaVersion": 1, "versions": ["10"]}),
            json.dumps({"schemaVersion": 1, "versions": ["10.0.401-preview.1"]}),
            json.dumps({"schemaVersion": 1, "versions": ["10.0.401"], "unexpected": True}),
        ]
        for content in invalid_documents:
            with self.subTest(content=content):
                manifest.write_text(content, encoding="utf-8")
                result = self.render_mise_config()
                self.assertNotEqual(result.returncode, 0, result.stdout)


@unittest.skipUnless(os.name == "posix" and SHELL, "POSIX runner fixture requires a POSIX host")
class Dotnet10RunnerTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="dotnet10-runner-"))
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.home = self.temp / "home"
        self.dotnet_root = self.home / ".local/share/mise/dotnet-root"
        self.runner_dir = self.home / ".local/share/dotfiles/dotnet10-runner"
        self.project = self.temp / "project"
        self.fake_bin = self.temp / "bin"
        for path in (self.dotnet_root, self.runner_dir, self.project, self.fake_bin):
            path.mkdir(parents=True, exist_ok=True)
        self.runner = REPO / "home/dot_local/bin/executable_dotfiles-dotnet10"
        self.source = self.project / "program.cs"
        self.source.write_text("// fake C# program\n", encoding="utf-8")
        (self.project / "global.json").write_text(
            json.dumps({"sdk": {"version": "8.0.404", "rollForward": "latestPatch"}}),
            encoding="utf-8",
        )
        (self.runner_dir / "global.json").write_text(
            json.dumps(
                {"sdk": {"version": "10.0.401", "rollForward": "latestFeature", "allowPrerelease": False}}
            ),
            encoding="utf-8",
        )
        self.log = self.temp / "dotnet-calls.jsonl"
        self.fake_dotnet = self.dotnet_root / "dotnet"
        self.fake_dotnet.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, pathlib, sys\n"
            "if sys.argv[1:] == ['--version']:\n"
            "    print(os.environ.get('DOTNET_FAKE_VERSION', '10.0.401'))\n"
            "    raise SystemExit(0)\n"
            "payload = sys.stdin.buffer.read()\n"
            "with open(os.environ['DOTNET_FAKE_LOG'], 'a', encoding='utf-8') as stream:\n"
            "    stream.write(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd(), 'stdin': payload.decode(), 'original_cwd': os.environ.get('DOTFILES_DOTNET10_ORIGINAL_CWD'), 'dotnet_root': os.environ.get('DOTNET_ROOT')}) + '\\n')\n"
            "sys.stdout.write('fake-stdout\\n')\n"
            "sys.stderr.write('fake-stderr\\n')\n"
            "raise SystemExit(int(os.environ.get('DOTNET_FAKE_STATUS', '0')))\n",
            encoding="utf-8",
        )
        self.fake_dotnet.chmod(0o755)
        self.write_command("uname", """case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) exit 1 ;; esac""")
        self.write_command("sysctl", "echo 1")

    def write_command(self, name, body):
        path = self.fake_bin / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        path.chmod(0o755)

    def run_runner(self, fake_version="10.0.401", fake_status="0", stdin=""):
        env = {
            **os.environ,
            "HOME": str(self.home),
            "PATH": str(self.fake_bin) + os.pathsep + os.environ.get("PATH", ""),
            "DOTNET_FAKE_LOG": str(self.log),
            "DOTNET_FAKE_VERSION": fake_version,
            "DOTNET_FAKE_STATUS": fake_status,
        }
        return subprocess.run(
            [SHELL, str(self.runner), "run", "--file", str(self.source), "argument with spaces", "--dry-run"],
            cwd=self.project,
            env=env,
            input=stdin,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )

    def test_private_sdk10_context_preserves_io_arguments_and_status(self):
        result = self.run_runner(fake_status="23", stdin="stdin payload")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(result.stdout, "fake-stdout\n")
        self.assertEqual(result.stderr, "fake-stderr\n")
        call = json.loads(self.log.read_text(encoding="utf-8").splitlines()[0])
        self.assertEqual(
            call["args"],
            ["run", "--file", str(self.source), "argument with spaces", "--dry-run"],
        )
        self.assertEqual(call["cwd"], str(self.runner_dir.resolve()))
        self.assertEqual(call["original_cwd"], str(self.project.resolve()))
        self.assertEqual(call["stdin"], "stdin payload")
        self.assertEqual(call["dotnet_root"], str(self.dotnet_root))
        self.assertEqual((self.project / "global.json").read_text(encoding="utf-8"),
                         json.dumps({"sdk": {"version": "8.0.404", "rollForward": "latestPatch"}}))

    def test_runner_refuses_to_use_sdk8_when_managed_host_reports_it(self):
        result = self.run_runner(fake_version="8.0.404")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a .NET 10 SDK", result.stderr)
        self.assertFalse(self.log.exists())

    @unittest.skipIf(platform.system() == "Darwin", "non-macOS refusal")
    def test_runner_refuses_non_macos_without_invoking_dotnet(self):
        result = subprocess.run(
            [SHELL, str(self.runner), "run", "--file", str(self.source)],
            cwd=self.project,
            env={**os.environ, "HOME": str(self.home), "PATH": os.environ.get("PATH", "")},
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("only on macOS", result.stderr)
        self.assertFalse(self.log.exists())


class MiseHookContractTest(unittest.TestCase):
    def test_macos_hook_installs_sdk_before_the_single_tool_update(self):
        hook = (REPO / "home/run_after_20-mise-upgrade.sh").read_text(encoding="utf-8")
        required = [
            "mise_global install",
            "mise_global upgrade --global --exclude dotnet",
            "mise_global upgrade --global --no-prune dotnet",
            "mise_global bootstrap packages apply",
            "update_dotnet_global_tools \"$dotnet_host\"",
        ]
        offsets = [hook.index(command) for command in required]
        self.assertEqual(offsets, sorted(offsets))
        managed_block = re.search(r"managed_tools='(.*?)'", hook, re.DOTALL).group(1)
        shell_tools = set(managed_block.splitlines())
        ps_hook = (REPO / "home/run_after_20-mise-upgrade.ps1").read_text(encoding="utf-8")
        ps_block = re.search(r"\$managedTools = @\((.*?)\n\s*\)", ps_hook, re.DOTALL).group(1)
        powershell_tools = set(re.findall(r"'([^']+)'", ps_block))
        self.assertEqual(powershell_tools, shell_tools | {"git-credential-manager"})
        self.assertIn("git-credential-manager", hook)
        self.assertIn('if ! is_macos; then', hook)

    def test_non_windows_chezmoi_filter_excludes_powershell_upgrade_hook(self):
        ignore = (REPO / "home/.chezmoiignore").read_text(encoding="utf-8")
        block = re.search(r'\{\{ if ne \.chezmoi\.os "windows" \}\}(.*?)\{\{ end \}\}', ignore, re.DOTALL)
        self.assertIsNotNone(block)
        self.assertIn("20-mise-upgrade.ps1", block.group(1))

    def test_first_setup_installs_mise_sdk_before_bootstrap_apply(self):
        setup = (REPO / "home/run_once_after_20-mise-install.sh").read_text(encoding="utf-8")
        self.assertLess(setup.index("mise install"), setup.index("bootstrap packages apply"))
        self.assertNotIn("dotnet tool update", setup)
        self.assertNotIn("dotnet tool install", setup)

    def test_power_shell_global_tool_work_is_guarded_to_windows(self):
        hook = (REPO / "home/run_after_20-mise-upgrade.ps1").read_text(encoding="utf-8")
        guard = hook.find("if (-not $isWindowsHost)")
        self.assertGreaterEqual(guard, 0, "non-Windows return guard is required")
        return_statement = hook.find("exit 0", guard)
        tool_work = hook.find("\nUpdate-DotnetGlobalToolSet\n")
        self.assertGreater(return_statement, guard)
        self.assertGreater(tool_work, return_statement)


@unittest.skipIf(platform.system() == "Darwin", "non-macOS PowerShell wrapper guard")
class PowerShellMigrationWrapperTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 is not installed")
    def test_wrapper_refuses_non_macos_before_invoking_bash(self):
        with tempfile.TemporaryDirectory(prefix="dotnet-ps-wrapper-") as temp_dir:
            state_dir = Path(temp_dir) / "state"
            result = subprocess.run(
                [
                    shutil.which("pwsh"),
                    "-NoProfile",
                    "-File",
                    str(REPO / "scripts/migrate-dotnet-macos.ps1"),
                    "-StateDirectory",
                    str(state_dir),
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=30,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("only on macOS", result.stderr)
            self.assertFalse(state_dir.exists())


@unittest.skipUnless(platform.system() == "Darwin", "macOS profile behavior")
class MacProfileTest(unittest.TestCase):
    def test_profile_refresh_is_idempotent_across_repeated_sources_and_path_reorder(self):
        zsh = shutil.which("zsh")
        self.assertIsNotNone(zsh, "zsh is available on macOS")
        with tempfile.TemporaryDirectory(prefix="dotnet-profile-") as temp_dir:
            home = Path(temp_dir)
            shared_root = home / ".local/share/mise/dotnet-root"
            shared_root.mkdir(parents=True)
            (shared_root / "dotnet").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (shared_root / "dotnet").chmod(0o755)
            (home / ".dotnet/tools").mkdir(parents=True)
            profile = home / ".profile"
            config = home / "chezmoi.toml"
            config.write_text(
                "[data]\nisLinux = false\nisMac = true\nisWindows = false\n"
                "isWSL = false\nisDevContainer = false\n",
                encoding="utf-8",
            )
            rendered = subprocess.run(
                [
                    CHEZMOI,
                    "--source",
                    str(REPO),
                    "--destination",
                    str(home),
                    "--config",
                    str(config),
                    "--no-tty",
                    "execute-template",
                    "--file",
                    "home/dot_profile.tmpl",
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                env={**os.environ, "HOME": str(home)},
            )
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            profile.write_text(rendered.stdout, encoding="utf-8")
            for target, source in (
                (home / ".zshenv", "home/dot_zshenv.tmpl"),
                (home / ".zprofile", "home/dot_zprofile.tmpl"),
                (home / ".zshrc", "home/dot_zshrc.tmpl"),
            ):
                zsh_render = subprocess.run(
                    [
                        CHEZMOI,
                        "--source",
                        str(REPO),
                        "--destination",
                        str(home),
                        "--config",
                        str(config),
                        "--no-tty",
                        "execute-template",
                        "--file",
                        source,
                    ],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    env={**os.environ, "HOME": str(home)},
                )
                self.assertEqual(zsh_render.returncode, 0, zsh_render.stderr)
                target.write_text(zsh_render.stdout, encoding="utf-8")
            command = (
                ". \"$HOME/.zshenv\"; . \"$HOME/.zprofile\"; "
                "PATH='/usr/bin:/bin:/usr/local/bin'; . \"$HOME/.zprofile\"; "
                ". \"$HOME/.zshrc\"; "
                "print -r -- \"$DOTNET_ROOT|$DOTNET_ROOT_ARM64|$PATH\""
            )
            result = subprocess.run(
                [zsh, "-fc", command],
                capture_output=True,
                text=True,
                encoding="utf-8",
                env={
                    **os.environ,
                    "HOME": str(home),
                    "PATH": "/usr/bin:/bin:/usr/local/bin",
                    "__DOTFILES_PROFILE_LOADED": "1",
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            root, arch_root, path = result.stdout.strip().split("|", 2)
            entries = path.split(os.pathsep)
            self.assertEqual(root, str(shared_root))
            self.assertEqual(arch_root, str(shared_root))
            self.assertEqual(entries[0], str(shared_root))
            self.assertIn(str(home / ".dotnet/tools"), entries)
            self.assertEqual(len(entries), len(set(entries)))


if __name__ == "__main__":
    unittest.main()
