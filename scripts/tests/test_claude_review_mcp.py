"""Exercise the Claude review MCP server with a local stub CLI."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import queue
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SERVER = REPO / "home/dot_local/share/dotfiles/claude-review/server.mjs"
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "Node.js is required")
class ClaudeReviewMcpTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.capture = self.root / "capture.json"
        self.stub = self.root / "claude-stub.mjs"
        self.stub.write_text(
            """#!/usr/bin/env node
import fs from 'node:fs';
const input = fs.readFileSync(0, 'utf8');
fs.writeFileSync(process.env.STUB_CAPTURE, JSON.stringify({ args: process.argv.slice(2), input }));
if (process.env.STUB_MODE === 'wait') {
  process.on('SIGTERM', () => process.exit(143));
  setInterval(() => {}, 1000);
} else if (process.env.STUB_MODE === 'ignore-term') {
  process.on('SIGTERM', () => {});
  setInterval(() => {}, 1000);
} else if (process.env.STUB_MODE === 'exit') {
  process.stderr.write(input);
  process.exit(7);
} else if (process.env.STUB_MODE === 'invalid-json') {
  process.stdout.write('not json');
} else if (process.env.STUB_MODE === 'auth-error') {
  process.stdout.write(JSON.stringify({ type: 'result', subtype: 'error_during_execution', is_error: true, api_error_status: 401 }));
} else if (process.env.STUB_MODE === 'error-result') {
  process.stdout.write(JSON.stringify({ type: 'result', subtype: 'error_during_execution', is_error: true, result: input }));
} else {
  process.stdout.write(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: 'No actionable issues found.' }));
}
""",
            encoding="utf-8",
        )
        self.stub.chmod(0o755)
        env = os.environ.copy()
        env["DOTFILES_REVIEW_CLAUDE"] = str(self.stub)
        env["STUB_CAPTURE"] = str(self.capture)
        env["STUB_MODE"] = "success"
        env.pop("DOTFILES_CODEX_FROM_CLAUDE", None)
        self.start_server(env)
        self.addCleanup(self.stop_server)
        self.write({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        self.assertEqual(self.read()["result"]["serverInfo"]["name"], "claude-review")
        self.write({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def start_server(self, env):
        self.process = subprocess.Popen(
            [NODE, str(SERVER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8", env=env,
        )
        process = self.process
        self.output = queue.Queue()
        self.reader = threading.Thread(target=self.read_stdout, args=(process, self.output), daemon=True)
        self.reader.start()

    def stop_server(self):
        if self.process.poll() is None:
            if not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.reader.join(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()

    @staticmethod
    def read_stdout(process, output):
        for line in process.stdout:
            output.put(line)
        output.put(None)

    def write(self, message):
        self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.process.stdin.flush()

    def read(self, timeout=8):
        try:
            line = self.output.get(timeout=timeout)
        except queue.Empty:
            self.fail("Timed out waiting for an MCP response")
        self.assertIsNotNone(line, "MCP server closed stdout unexpectedly")
        return json.loads(line)

    def call_tool(self, request_id, arguments):
        self.write({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": "review_diff", "arguments": arguments},
        })
        return self.read()

    def test_lists_one_read_only_review_tool(self):
        self.write({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools = self.read()["result"]["tools"]
        self.assertEqual([tool["name"] for tool in tools], ["review_diff"])
        self.assertTrue(tools[0]["annotations"]["readOnlyHint"])
        self.assertTrue(tools[0]["annotations"]["openWorldHint"])
        self.assertEqual(tools[0]["inputSchema"]["required"], ["diff"])

    @unittest.skipIf(os.name == "nt", "Windows cannot launch the shebang-based Claude stub")
    def test_runs_fixed_read_only_claude_cli_and_returns_review(self):
        result = self.call_tool(2, {"diff": "diff --git a/a b/a", "context": "source context"})
        self.assertFalse(result["result"]["isError"])
        self.assertEqual(result["result"]["content"][0]["text"], "No actionable issues found.")

        capture = json.loads(self.capture.read_text(encoding="utf-8"))
        self.assertEqual(capture["args"], [
            "-p", "--safe-mode", "--no-session-persistence", "--tools", "", "--disallowedTools", "mcp__*",
            "--strict-mcp-config", "--model", "sonnet", "--effort", "medium",
            "--max-turns", "1", "--output-format", "json",
        ])
        self.assertIn("source context", capture["input"])
        self.assertIn("diff --git a/a b/a", capture["input"])
        self.assertIn("Do not change files, run commands", capture["input"])

    def test_rejects_invalid_or_oversized_input_before_spawn(self):
        missing = self.call_tool(2, {})
        self.assertTrue(missing["result"]["isError"])
        self.assertIn("non-empty string", missing["result"]["content"][0]["text"])

        oversized = self.call_tool(3, {"diff": "é" * (64 * 1024 + 1)})
        self.assertTrue(oversized["result"]["isError"])
        self.assertIn("128 KiB", oversized["result"]["content"][0]["text"])
        self.assertFalse(self.capture.exists())

    def test_rejects_unknown_tool_before_spawn(self):
        self.write({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "unexpected", "arguments": {"diff": "some changes"}},
        })
        self.assertEqual(self.read()["error"]["code"], -32602)
        self.assertFalse(self.capture.exists())

    def test_refuses_nested_review_before_spawn(self):
        self.stop_server()

        env = os.environ.copy()
        env["DOTFILES_REVIEW_CLAUDE"] = str(self.stub)
        env["DOTFILES_CODEX_FROM_CLAUDE"] = "1"
        env["STUB_CAPTURE"] = str(self.capture)
        self.start_server(env)
        self.write({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        self.read()
        self.write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        result = self.call_tool(2, {"diff": "some changes"})
        self.assertTrue(result["result"]["isError"])
        self.assertIn("disabled", result["result"]["content"][0]["text"])
        self.assertFalse(self.capture.exists())

    @unittest.skipIf(os.name == "nt", "Windows cannot launch the shebang-based Claude stub")
    def test_sanitizes_cli_failures_and_rejects_error_json(self):
        env = os.environ.copy()
        env["DOTFILES_REVIEW_CLAUDE"] = str(self.stub)
        env["STUB_CAPTURE"] = str(self.capture)
        env["STUB_MODE"] = "exit"
        self.stop_server()
        self.start_server(env)
        self.write({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        self.read()
        self.write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        result = self.call_tool(2, {"diff": "sensitive-diff-content"})
        self.assertTrue(result["result"]["isError"])
        self.assertIn("status 7", result["result"]["content"][0]["text"])
        self.assertNotIn("sensitive-diff-content", json.dumps(result))

    @unittest.skipIf(os.name == "nt", "Windows cannot launch the shebang-based Claude stub")
    def test_reports_authentication_errors_and_claude_error_subtypes(self):
        for mode, expected in (
            ("auth-error", "HTTP 401"),
            ("error-result", "error_during_execution"),
            ("invalid-json", "invalid JSON"),
        ):
            with self.subTest(mode=mode):
                self.stop_server()
                env = os.environ.copy()
                env["DOTFILES_REVIEW_CLAUDE"] = str(self.stub)
                env["STUB_CAPTURE"] = str(self.capture)
                env["STUB_MODE"] = mode
                self.start_server(env)
                self.write({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
                self.read()
                self.write({"jsonrpc": "2.0", "method": "notifications/initialized"})
                result = self.call_tool(2, {"diff": "changes"})
                self.assertTrue(result["result"]["isError"])
                self.assertIn(expected, result["result"]["content"][0]["text"])

    @unittest.skipIf(os.name == "nt", "Windows cannot launch the shebang-based Claude stub")
    def test_cancel_stops_running_claude_review(self):
        self.stop_server()
        env = os.environ.copy()
        env["DOTFILES_REVIEW_CLAUDE"] = str(self.stub)
        env["STUB_CAPTURE"] = str(self.capture)
        env["STUB_MODE"] = "wait"
        self.start_server(env)
        self.write({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        self.read()
        self.write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.write({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "review_diff", "arguments": {"diff": "changes"}},
        })
        deadline = time.monotonic() + 5
        while not self.capture.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.capture.exists(), "Claude stub was not started")
        self.write({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 2}})
        result = self.read()
        self.assertTrue(result["result"]["isError"])
        self.assertIn("cancelled", result["result"]["content"][0]["text"])

    @unittest.skipIf(os.name == "nt", "Windows cannot launch the shebang-based Claude stub")
    def test_cancel_force_kills_a_cli_that_ignores_sigterm(self):
        self.stop_server()
        env = os.environ.copy()
        env["DOTFILES_REVIEW_CLAUDE"] = str(self.stub)
        env["STUB_CAPTURE"] = str(self.capture)
        env["STUB_MODE"] = "ignore-term"
        self.start_server(env)
        self.write({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        self.read()
        self.write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.write({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "review_diff", "arguments": {"diff": "changes"}},
        })
        deadline = time.monotonic() + 5
        while not self.capture.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.capture.exists(), "Claude stub was not started")
        self.write({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 2}})
        started = time.monotonic()
        result = self.read(timeout=5)
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 1.3)
        self.assertTrue(result["result"]["isError"])
        self.assertIn("cancelled", result["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
