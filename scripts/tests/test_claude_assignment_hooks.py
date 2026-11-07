"""Behavior tests for real Claude assignment hooks; no payload commands are run."""

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


class AssignmentHookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="claude hooks 日本語 ")
        self.addCleanup(self.tmp.cleanup)
        self.hooks = Path(self.tmp.name)
        for name in ("leading-assignment.sh", "leading-assignment.ps1"):
            shutil.copyfile(HOOKS / name, self.hooks / name)

    def invoke(self, shell, payload):
        if shell == "sh":
            if not SH or not NODE:
                self.skipTest("sh and Node.js are required")
            script = str(self.hooks / "leading-assignment.sh")
            # Git for Windows sh accepts forward-slash drive paths.
            argv = [SH, script.replace("\\", "/")]
        else:
            if not PWSH:
                self.skipTest("PowerShell 7 is required")
            argv = [
                PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                str(self.hooks / "leading-assignment.ps1"),
            ]
        return subprocess.run(
            argv, input=payload, capture_output=True, text=True,
            encoding="utf-8", timeout=15,
        )

    def check_command(self, shell, command, blocked, tool="Bash"):
        result = self.invoke(shell, json.dumps({
            "tool_name": tool, "tool_input": {"command": command},
        }))
        self.assertEqual(result.returncode, 2 if blocked else 0, result.stderr)
        self.assertEqual(result.stdout, "")
        if blocked:
            self.assertIn("direct absolute paths", result.stderr)
        else:
            self.assertEqual(result.stderr, "")

    def test_shell_leading_assignments(self):
        for shell in ("sh", "pwsh"):
            for command in (
                "R='/a path'; git -C \"$R\" status",
                "R=/repo git status",
                " \t\r\nR='/日本語 path'; gh issue list",
                "R=/repo", "_root2+=/repo git status", "R=\n",
            ):
                with self.subTest(shell=shell, command=command):
                    self.check_command(shell, command, True)

    def test_normal_commands_and_intentional_gaps(self):
        for shell in ("sh", "pwsh"):
            for command in (
                "git -C '/a path/日本語' status", "gh issue list",
                "git -c key=value status", 'echo "R=/repo"',
                "'R=/repo'", "1R=/repo git status", "R-X=/repo git status",
                "export R=/repo; git status", "env R=/repo git status",
                "git status; R=/repo", "# comment\nR=/repo",
                "R = /repo", "",
            ):
                with self.subTest(shell=shell, command=command):
                    self.check_command(shell, command, False)

    def test_powershell_assignments_in_bash_and_native_tool(self):
        for tool in ("Bash", "PowerShell", "powershell"):
            for command in (
                "$R='C:/a path'; git -C $R status",
                " \n$root = 'C:/日本語'; gh issue list",
                "$env:ROOT='C:/repo'", "${root} = 'C:/repo'",
                "${script:root}='C:/repo'", "$ルート='C:/repo'",
                "$root += 'x'", "$root -= 1", "$root *= 2",
                "$root /= 2", "$root %= 2", "$root ??= 'C:/repo'",
            ):
                with self.subTest(tool=tool, command=command):
                    self.check_command("pwsh", command, True, tool)

    def test_powershell_nonassignments(self):
        for command in (
            "$root -eq 'x'", "$root == 'x'", "$root -ne 'x'",
            "git -C $root status", "Write-Output '$root=x'",
            "$root.Equals('x')", "$root[0] = 'x'",
            "$object.Path = 'x'", "Set-Variable root 'x'",
            "git status; $root='x'", "& { $root='x' }",
        ):
            with self.subTest(command=command):
                self.check_command("pwsh", command, False, "PowerShell")
        # Unix entrypoint intentionally covers Bash only, not PowerShell syntax.
        self.check_command("sh", "$root='x'", False)

    def test_invalid_payloads_block_with_clean_stdout(self):
        payloads = [
            "", "{invalid", "null", "[]", "42", '"text"', "true",
            '{"tool_name":"Bash","tool_input":{"command":"git status"},}',
            '{"tool_name":"Bash",/* comment */"tool_input":{"command":"git status"}}',
            "{}", '{"tool_name":42}', '{"tool_name":""}',
            '{"tool_name":"Bash"}', '{"tool_name":"Bash","tool_input":[]}',
        ]
        for value in (None, 12, [], {}, True):
            payloads.append(json.dumps({
                "tool_name": "Bash", "tool_input": {"command": value},
            }))
        for shell in ("sh", "pwsh"):
            for payload in payloads:
                with self.subTest(shell=shell, payload=payload):
                    result = self.invoke(shell, payload)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("Fix the hook payload", result.stderr)

    def test_unrelated_tool_is_ignored(self):
        for shell in ("sh", "pwsh"):
            result = self.invoke(shell, '{"tool_name":"Read","tool_input":{"file_path":"x"}}')
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    @unittest.skipUnless(SH and NODE and os.name != "nt", "POSIX sh required for isolated PATH")
    def test_missing_node_blocks(self):
        result = subprocess.run(
            [SH, str(self.hooks / "leading-assignment.sh")],
            input="{}", capture_output=True, text=True,
            env={**os.environ, "PATH": str(self.hooks)}, timeout=15,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("requires Node.js", result.stderr)


if __name__ == "__main__":
    unittest.main()
