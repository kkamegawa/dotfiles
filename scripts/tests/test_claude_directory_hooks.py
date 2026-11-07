"""Behavior tests for real directory hooks; payload commands are never run."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HOOKS = Path(__file__).resolve().parents[2] / "home/dot_claude/hooks"
SH = shutil.which("sh")
NODE = shutil.which("node")
PWSH = shutil.which("pwsh")


class DirectoryHookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="claude directory 日本語 ")
        self.addCleanup(self.tmp.cleanup)
        self.hooks = Path(self.tmp.name)
        for name in ("deny-cd.sh", "deny-cd.ps1"):
            shutil.copyfile(HOOKS / name, self.hooks / name)

    def invoke(self, shell, payload, env=None):
        if shell == "sh":
            if not SH or not NODE:
                self.skipTest("sh and Node.js are required")
            argv = [SH, str(self.hooks / "deny-cd.sh").replace("\\", "/")]
        else:
            if not PWSH:
                self.skipTest("PowerShell 7 is required")
            argv = [
                PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                str(self.hooks / "deny-cd.ps1"),
            ]
        return subprocess.run(
            argv, input=payload, capture_output=True, text=True,
            encoding="utf-8", timeout=15, env=env,
        )

    def check_command(self, shell, command, blocked, tool="Bash"):
        result = self.invoke(shell, json.dumps({
            "tool_name": tool, "tool_input": {"command": command},
        }))
        self.assertEqual(result.returncode, 2 if blocked else 0, result.stderr)
        self.assertEqual(result.stdout, "")
        if blocked:
            self.assertIn("direct absolute paths", result.stderr)
            self.assertIn("git -C", result.stderr)
            self.assertIn("python3", result.stderr)
        else:
            self.assertEqual(result.stderr, "")

    def test_directory_commands_and_boundaries(self):
        for shell in ("sh", "pwsh"):
            for command in (
                "cd", " \tcd /repo", "cd -- /repo", "cd -",
                "pushd", "pushd '/a path/日本語'", "popd", "chdir /repo",
                "echo ok&&cd /repo", "echo ok||cd /repo",
                "echo ok;cd", "echo ok|cd /repo", "echo ok&cd /repo",
                "echo ok\ncd /repo", "echo ok\r\n\tcd /repo",
                "(cd /repo)", "{ cd /repo; }", "$(cd /repo; pwd)",
                "`cd /repo`", "if cd /repo; then echo ok; fi",
                "if true; then cd /repo; fi",
                "if false; then true; elif cd /repo; then true; else popd; fi",
                "while cd /repo; do true; done",
                "until cd /repo; do true; done",
                "for x in a; do cd /repo; done", "! cd /repo",
                "cd>/tmp/output", "# comment\ncd",
            ):
                with self.subTest(shell=shell, command=command):
                    self.check_command(shell, command, True)

    def test_allowed_paths_prefixes_and_keywords_in_arguments(self):
        for shell in ("sh", "pwsh"):
            for command in (
                "git -C '/a path/日本語' status",
                "python3 '/a path/日本語/script.py'",
                "git -C C:/repo status && python3 C:/repo/script.py",
                "echo cd", 'echo "cd /repo"', "echo then cd", "echo do cd",
                "echo else cd", "echo if cd", "echo undo cd",
                "echo somethingthen cd", "echo somethingelse cd",
                "cdrom /repo", "cd_tool", "cd~", "pushdown", "popdata", "chdirectory",
                "thenish cd /repo", "doing cd /repo", "elsewhere cd /repo",
                "echo ok; cdata", "echo ok\npushdown", "",
                "echo ok; python3 /absolute/script.py",
            ):
                with self.subTest(shell=shell, command=command):
                    self.check_command(shell, command, False)

    def test_windows_aliases_cmdlets_and_case(self):
        for tool in ("Bash", "PowerShell", "powershell"):
            for command in (
                "CD", "ChDiR C:/repo", "PuShD", "PoPd",
                "sl C:/repo", "Set-Location -LiteralPath 'C:/a path/日本語'",
                "push-location", "POP-LOCATION",
                "Write-Output ok | Set-Location C:/repo",
                "if ($true) { Set-Location C:/repo }",
                "& { sl C:/repo }", "& cd C:/repo",
            ):
                with self.subTest(tool=tool, command=command):
                    self.check_command("pwsh", command, True, tool)
        for command in ("slideshow", "Set-LocationExtra", "Push-LocationX", "Pop-LocationX"):
            self.check_command("pwsh", command, False, "PowerShell")
        for command in ("CD /repo", "sl /repo", "Set-Location /repo", "Push-Location", "Pop-Location"):
            self.check_command("sh", command, False)
        for tool in ("PowerShell", "powershell"):
            self.check_command("sh", "cd /repo", False, tool)

    def test_documented_quoted_text_false_positives_and_bypasses(self):
        for shell in ("sh", "pwsh"):
            for command in ('echo "text; cd /repo"', "echo 'text\npushd /repo'"):
                self.check_command(shell, command, True)
            # Wrappers, escaped/quoted names and library calls are not resolved.
            for command in (
                "env cd /repo", "command cd /repo", "builtin cd /repo",
                "'cd' /repo", '"cd" /repo', "c\\d /repo",
                'python3 -c "import os; os.chdir(\\\"/repo\\\")"',
            ):
                self.check_command(shell, command, False)

    def test_invalid_payloads(self):
        payloads = [
            "", "{invalid", "null", "[]", "42", '"text"', "true", "{}",
            '{"tool_name":42}', '{"tool_name":""}', '{"tool_name":"  "}',
            '{"tool_name":"Bash"}', '{"tool_name":"Bash","tool_input":[]}',
            '{"tool_name":"Bash","tool_input":{"command":"cd"},}',
            '{"tool_name":"Bash",/* comment */"tool_input":{"command":"cd"}}',
        ]
        for tool in ("Bash", "PowerShell", "powershell"):
            for value in (None, 12, [], {}, True):
                payloads.append(json.dumps({"tool_name": tool, "tool_input": {"command": value}}))
        for shell in ("sh", "pwsh"):
            for payload in payloads:
                # Unix ignores PowerShell tool inputs, even if their command is invalid.
                if shell == "sh" and '"tool_name": "Power' in payload:
                    continue
                if shell == "sh" and '"tool_name": "powershell"' in payload:
                    continue
                with self.subTest(shell=shell, payload=payload):
                    result = self.invoke(shell, payload)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("Fix the hook payload", result.stderr)

    def test_unrelated_tools_and_payload_nonexecution(self):
        marker = self.hooks / "must-not-exist"
        for shell in ("sh", "pwsh"):
            for tool in ("Read", "mcp__example__Bash", "bash", "POWERSHELL"):
                result = self.invoke(shell, json.dumps({"tool_name": tool}))
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
                self.check_command(shell, "cd /repo", False, tool)
            # If executed, this allowed payload would create a file.
            command = f'python3 -c "from pathlib import Path; Path({str(marker)!r}).touch()"'
            self.check_command(shell, command, False)
            self.assertFalse(marker.exists())

    @unittest.skipUnless(SH and NODE and os.name != "nt", "POSIX sh required for isolated PATH")
    def test_missing_or_failed_node_blocks(self):
        env = {**os.environ, "PATH": str(self.hooks)}
        result = self.invoke("sh", "{}", env)
        self.assertEqual((result.returncode, result.stdout), (2, ""))
        self.assertIn("requires Node.js", result.stderr)
        # Mock only the runtime failure; the actual hook still runs via real sh.
        node = self.hooks / "node"
        node.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        node.chmod(0o700)
        result = self.invoke("sh", "{}", env)
        self.assertEqual((result.returncode, result.stdout), (2, ""))
        self.assertIn("failed to run", result.stderr)


if __name__ == "__main__":
    unittest.main()
