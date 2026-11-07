"""Opt-in response templates; fixtures only, no CLI sessions or actual HOME writes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOOKS = ROOT / "reference/ai-response-hooks"
ENGLISH = "This is a complete English explanation of the changes and their validation."
REASON = (
    "最終応答の説明文を日本語で書き直してください。コード・コマンド・パス・識別子は変更せず、"
    "作業やツール実行を繰り返さずに回答だけを修正してください。"
)


class JapaneseResponseHooksTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="response 日本語 ' ")
        self.addCleanup(self.tmp.cleanup)
        self.transcript = Path(self.tmp.name) / "events 日本語 'quote.jsonl"
        self.runners = []
        if os.name != "nt" and shutil.which("jq") and shutil.which("perl"):
            self.runners.append(("sh", ["sh", str(HOOKS / "japanese-response.sh")]))
        if shutil.which("pwsh"):
            self.runners.append(("pwsh", [
                shutil.which("pwsh"), "-NoLogo", "-NoProfile", "-NonInteractive",
                "-File", str(HOOKS / "japanese-response.ps1"),
            ]))
        if not self.runners:
            self.skipTest("requires sh/jq/Perl or PowerShell 7")

    def events(self, *events):
        self.transcript.write_text(
            "\n".join(json.dumps(event, ensure_ascii=False) for event in events) + "\n",
            encoding="utf-8",
        )

    def message(self, content, **extra):
        return {"type": "assistant.message", "data": {"content": content}, **extra}

    def payload(self, client, text, active=False):
        result = {"stop_hook_active": active}
        if client == "copilot":
            self.events(self.message(text))
            result["transcriptPath"] = str(self.transcript)
        else:
            result.update(hook_event_name="Stop", last_assistant_message=text)
        return result

    def run_hook(self, runner, client, payload, env=None):
        return subprocess.run(
            runner + [client],
            input=payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False),
            capture_output=True, text=True, encoding="utf-8", timeout=20, env=env,
        )

    def assert_result(self, result, block=False, error=False, diagnostic=False):
        self.assertEqual(result.returncode, 1 if error else 0, result.stderr)
        if block:
            self.assertEqual(json.loads(result.stdout), {"decision": "block", "reason": REASON})
        else:
            self.assertEqual(result.stdout, "")
        if error or diagnostic:
            self.assertTrue(result.stderr)
        else:
            self.assertEqual(result.stderr, "")

    def test_shared_language_and_markdown_policy(self):
        cases = [
            (ENGLISH, True),
            ("a" * 29, False),
            ("a" * 30, True),
            ("あ" * 6 + "a" * 24, False),  # exactly 20% passes
            ("あ" * 5 + "a" * 25, True),
            ("変更を完了しました。テストを実行して正常に動作することを確認しました。", False),
            ("カタカナ" * 10, False),
            ("漢字" * 20, False),
            ("ｶﾀｶﾅ" * 10, False),
            ("\U00020000" * 6 + "a" * 24, False),
            ("0123456789 !!! " * 20, False),
            ("\n", False),
            ("完了。\n```sh\n" + ENGLISH + "\n```", False),
            ("完了。\n~~~~python\n" + ENGLISH + "\n~~~~~", False),
            ("完了。\n```\n" + ENGLISH, False),  # unclosed fence
            ("完了。 `" + ENGLISH + "`", False),
            ("完了。 ``code ` " + ENGLISH + "``", False),
            (ENGLISH + "\n```sh\n" + "日本語" * 100 + "\n```", True),
            ("完了。\r\n```sh\r\n" + ENGLISH + "\r\n```", False),
        ]
        for name, runner in self.runners:
            for client in ("claude", "codex", "copilot"):
                for text, block in cases:
                    with self.subTest(shell=name, client=client, text=text[:35]):
                        self.assert_result(self.run_hook(runner, client, self.payload(client, text)), block=block)

    def test_continuation_bypasses_text_and_transcript(self):
        for name, runner in self.runners:
            for client in ("claude", "codex", "copilot"):
                with self.subTest(shell=name, client=client):
                    self.assert_result(self.run_hook(runner, client, {"stop_hook_active": True}))
                    # A new independent turn is checked again (no persistent latch).
                    self.assert_result(self.run_hook(runner, client, self.payload(client, ENGLISH)), block=True)

    def test_invalid_payloads(self):
        for name, runner in self.runners:
            for payload in ("{", "[]", "null", "{}",
                            '{"stop_hook_active":"false"}',
                            '{"stop_hook_active":false,"hook_event_name":"SessionEnd"}',
                            '{"stop_hook_active":false}\n{"stop_hook_active":false}'):
                with self.subTest(shell=name, payload=payload):
                    self.assert_result(self.run_hook(runner, "claude", payload), error=True)
            self.assert_result(self.run_hook(runner, "unknown", {}), error=True)
            self.assert_result(self.run_hook(runner, "codex", {
                "stop_hook_active": False, "last_assistant_message": 42,
            }), error=True)

    def test_unavailable_text_is_advisory(self):
        for name, runner in self.runners:
            for client in ("claude", "codex"):
                for text in (None, ""):
                    with self.subTest(shell=name, client=client, text=text):
                        # Do not read stale transcripts in these products.
                        payload = self.payload(client, text)
                        payload["transcript_path"] = "/not/a/real/file"
                        self.assert_result(self.run_hook(runner, client, payload), diagnostic=True)

    def test_copilot_transcript_selection(self):
        cases = [
            ([self.message(ENGLISH), {"type": "tool.execution_complete", "data": {"result": "日本語"}}], True),
            ([self.message("日本語" * 20), self.message(ENGLISH)], True),
            ([self.message(ENGLISH), self.message("日本語" * 20)], False),
            ([self.message(ENGLISH), self.message("日本語" * 20, agentId="child")], True),
            ([self.message(ENGLISH), self.message("日本語" * 20, checkpoint=True)], True),
            ([self.message(ENGLISH), {"type": "assistant.reasoning", "data": {"content": "日本語" * 20}}], True),
            ([{"type": "assistant.message", "data": {"content": ENGLISH, "phase": "final_answer"}}], True),
            ([self.message(ENGLISH), {"type": "assistant.message", "data": {
                "content": "日本語" * 20, "parentToolCallId": "child",
            }}], True),
        ]
        for name, runner in self.runners:
            for key, event_name in (("transcriptPath", None), ("transcript_path", "Stop")):
                payload = {"stop_hook_active": False, key: str(self.transcript)}
                if event_name:
                    payload["hook_event_name"] = event_name
                for events, block in cases:
                    self.events(*events)
                    with self.subTest(shell=name, key=key, events=events):
                        self.assert_result(self.run_hook(runner, "copilot", payload), block=block)
                for latest in (
                    self.message(""),
                    {"type": "assistant.message", "data": {"content": ENGLISH, "toolRequests": [{"name": "bash"}]}},
                    {"type": "assistant.message", "data": {"content": ENGLISH, "phase": "commentary"}},
                    {"type": "user.message", "data": {"content": "new turn"}},
                    {"type": "assistant.turn_start", "data": {}},
                ):
                    self.events(self.message(ENGLISH), latest)
                    self.assert_result(self.run_hook(runner, "copilot", payload), diagnostic=True)
                self.events({"type": "assistant", "message": {"content": [{"type": "text", "text": ENGLISH}]}})
                self.assert_result(self.run_hook(runner, "copilot", payload), diagnostic=True)

    def test_copilot_read_failures(self):
        for name, runner in self.runners:
            payload = {"stop_hook_active": False, "transcriptPath": str(self.transcript)}
            self.transcript.unlink(missing_ok=True)
            self.assert_result(self.run_hook(runner, "copilot", payload), error=True)
            self.transcript.write_text("{malformed\n", encoding="utf-8")
            self.assert_result(self.run_hook(runner, "copilot", payload), error=True)
            self.assert_result(self.run_hook(runner, "copilot", {"stop_hook_active": False}), error=True)

    def test_shell_missing_dependencies(self):
        if not any(name == "sh" for name, _ in self.runners):
            self.skipTest("Unix sh required")
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, PATH=directory)
            runner = [shutil.which("sh"), str(HOOKS / "japanese-response.sh")]
            self.assert_result(self.run_hook(runner, "claude", {}, env), error=True)
            # jq and cat available, but no Perl: detect only when inspection is needed.
            for name in ("jq", "cat"):
                Path(directory, name).symlink_to(shutil.which(name))
            self.assert_result(self.run_hook(runner, "claude", self.payload("claude", ENGLISH), env), error=True)
            self.assert_result(self.run_hook(runner, "claude", {"stop_hook_active": True}, env))

    def test_configuration_shapes(self):
        for filename in ("claude.settings.unix.json", "claude.settings.windows.json", "codex.hooks.json"):
            data = json.loads((HOOKS / filename).read_text(encoding="utf-8"))
            self.assertEqual(set(data["hooks"]), {"Stop"})
            handler = data["hooks"]["Stop"][0]["hooks"][0]
            self.assertEqual(handler["type"], "command")
            self.assertEqual(handler["timeout"], 30)
            self.assertNotIn("async", handler)
        codex = json.loads((HOOKS / "codex.hooks.json").read_text(encoding="utf-8"))
        self.assertIn("commandWindows", codex["hooks"]["Stop"][0]["hooks"][0])
        copilot = json.loads((HOOKS / "copilot.hooks.json").read_text(encoding="utf-8"))
        self.assertEqual(copilot["version"], 1)
        self.assertEqual(set(copilot["hooks"]), {"agentStop"})
        handler = copilot["hooks"]["agentStop"][0]
        self.assertEqual(handler["timeoutSec"], 30)
        self.assertIn("bash", handler)
        self.assertIn("powershell", handler)
        self.assertNotIn("exec", handler)

    def test_configuration_commands(self):
        # Exercise the actual template command strings from an unrelated cwd,
        # including shell-specific quoting for paths with spaces and apostrophes.
        directory = Path(self.tmp.name) / "ai-response-hooks"
        directory.mkdir()
        for suffix in ("sh", "ps1"):
            shutil.copyfile(HOOKS / f"japanese-response.{suffix}", directory / f"japanese-response.{suffix}")
        definitions = [
            ("claude.settings.unix.json", "claude", "command", "sh"),
            ("claude.settings.windows.json", "claude", "command", "pwsh"),
            ("codex.hooks.json", "codex", "command", "sh"),
            ("codex.hooks.json", "codex", "commandWindows", "pwsh"),
            ("copilot.hooks.json", "copilot", "bash", "sh"),
            ("copilot.hooks.json", "copilot", "powershell", "pwsh"),
        ]
        for filename, client, key, shell in definitions:
            if not any(name == shell for name, _ in self.runners):
                continue
            data = json.loads((HOOKS / filename).read_text(encoding="utf-8"))
            handler = data["hooks"].get("Stop", data["hooks"].get("agentStop"))[0]
            if "hooks" in handler:
                handler = handler["hooks"][0]
            command = handler[key]
            if shell == "sh":
                command = command.replace(
                    "/ABSOLUTE/PATH/ai-response-hooks", directory.as_posix().replace("'", "'\"'\"'"),
                )
                argv = ["sh", "-c", command]
            else:
                path = directory.as_posix()
                if key == "powershell":
                    path = path.replace("'", "''")
                command = command.replace("C:/ABSOLUTE/PATH/ai-response-hooks", path)
                argv = [shutil.which("pwsh"), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command]
            with self.subTest(template=filename, key=key):
                result = subprocess.run(
                    argv, input=json.dumps(self.payload(client, ENGLISH), ensure_ascii=False),
                    cwd=self.tmp.name, capture_output=True, text=True, encoding="utf-8", timeout=20,
                )
                self.assert_result(result, block=True)

    def test_encoding_and_line_endings(self):
        for path in [
            *HOOKS.iterdir(), ROOT / "docs/ai-response-hooks.md",
            ROOT / "docs/ai-response-hooks_ja.md", Path(__file__),
        ]:
            with self.subTest(path=path.name):
                content = path.read_bytes()
                content.decode("utf-8")
                self.assertFalse(content.startswith(b"\xef\xbb\xbf"))
                if path.suffix == ".sh":
                    self.assertNotIn(b"\r", content)
                elif path.suffix == ".ps1":
                    self.assertNotIn(b"\n", content.replace(b"\r\n", b""))
                elif b"\r\n" in content:
                    # text=auto may check out docs/JSON/Python with LF elsewhere.
                    self.assertNotIn(b"\n", content.replace(b"\r\n", b""))


if __name__ == "__main__":
    unittest.main()
