# Japanese final-response hook templates

[日本語](ai-response-hooks_ja.md)

`reference/ai-response-hooks/` is **opt-in**, outside the chezmoi source root.
It does not change existing hooks, configuration, or HOME. These templates check
the main agent's final response in Claude Code, Codex, and **Copilot CLI**.
They are not templates for Copilot VS Code/cloud agent/SDK callbacks or subagents.

## Policy and contracts

Both implementations remove fenced code (backticks/ tildes, including unclosed
tails) and inline code, then count Unicode letters. Fewer than 30 letters pass.
At least **20%** kana/Han letters pass, including ordinary kana, halfwidth
katakana, and extended Han. This is a heuristic, not language identification:
Chinese Han can pass; long English quotations and links remain in scope.

Rejected prose produces `{"decision":"block","reason":"..."}` on stdout with
exit **0**, requesting a Japanese rewrite without repeating tools or changing code.
It cannot erase or replace English already displayed. All clients skip immediately
when `stop_hook_active` is true, allowing only one rewrite attempt. No state file
is created; the next independent turn is checked again.

Passing checks have empty stdout. Missing/null/empty final text produces a
diagnostic on stderr and exits 0. Invalid JSON/types, unreadable transcripts, and
missing dependencies produce stderr and exit 1, not a rewrite request.
Timeouts, disabled hooks, and advisory errors mean this does not guarantee Japanese.

| Client | Event and input | Template |
| --- | --- | --- |
| Claude Code | `Stop`, `last_assistant_message` | `claude.settings.unix.json` / `.windows.json` |
| Codex | `Stop`, nullable `last_assistant_message` | `codex.hooks.json`, `commandWindows` override |
| Copilot CLI | `agentStop`, JSONL at `transcriptPath` | `copilot.hooks.json`, `bash` / `powershell` |

Claude's transcript may not contain the final message at Stop time. Claude and
Codex therefore use the direct message field, with **no transcript fallback**.
Copilot's main-agent Stop input has no direct response field. Its reader selects
the latest root persisted `assistant.message.data.content`, excluding subagents,
checkpoints, reasoning and tool results. Turn/user boundaries reset the candidate;
empty/tool-only/commentary final messages do not fall back to older prose.
The PascalCase `Stop` input's `transcript_path` is also accepted.
**Copilot transcript serialization is not a stable hook API**; check it after CLI
updates. Missing `stop_hook_active` is an error rather than risking a rewrite loop.

## Optional setup

macOS/Linux require POSIX `sh`, `jq`, and Perl on the hook's PATH. Windows requires
**PowerShell 7+ (`pwsh`)**, without jq/Perl/Node.js. Shell files use LF as required
by `.gitattributes`; other added files use CRLF, UTF-8 without BOM. Do not convert
the shell script to CRLF. Explicit `sh` invocation needs no executable bit.

1. Reference this directory or copy the appropriate OS script to a chosen location.
2. Replace `/ABSOLUTE/PATH` and `C:/ABSOLUTE/PATH` in the configuration templates
   with real absolute paths. Keep quotes around paths with spaces. Escape Unix
   path apostrophes as `'"'"'` and apostrophes inside Copilot's PowerShell
   single-quoted path as `''`, then preserve valid JSON escaping.
   Forward slashes in Windows paths avoid doubling JSON backslashes.
3. **Merge**, never overwrite existing settings:
   - Claude: append the OS template's `hooks.Stop` handlers to
     `~/.claude/settings.json`.
   - Codex: merge into `~/.codex/hooks.json`, or add equivalent handlers to the
     existing inline hooks in `config.toml`. Prefer existing inline hooks when
     present; avoid duplicate registrations and warnings from both representations
     in one layer. TOML accepts `command_windows` or `commandWindows` and
     `timeout = 30`. Review and trust the new definition using `/hooks`.
   - Copilot CLI: save the edited configuration as
     `~/.copilot/hooks/japanese-response.json`.
     Adjust configuration locations for custom `COPILOT_HOME` / `CODEX_HOME`.
4. Restart the client and inspect loaded hooks. Test harmless English and Japanese
   responses in a disposable session. Copilot also reads repo-local Claude settings:
   avoid duplicated or mismatched handlers if choosing project-level Claude config.

No automatic hook deployment is modified. Ensure your configuration manager
preserves manually added handlers. To disable, remove only the added handler
(or the standalone Copilot configuration file), preserving other hooks.

## Local validation

From the repository root, without applying to HOME or contacting a live CLI/service:

```bash
python3 -m unittest discover -s scripts/tests -p test_japanese_response_hooks.py -v
```

```powershell
python -m unittest discover -s scripts/tests -p test_japanese_response_hooks.py -v
if ($LASTEXITCODE -ne 0) { throw "Response hook tests failed" }
```

Only available interpreters run. PowerShell on macOS is not a Windows-machine test.
Fixtures cover letter/ratio boundaries, code exclusion, continuation avoidance,
invalid inputs, latest-message selection, and configuration structure.
Actual event firing, hook trust, sandbox access, and transcript flush timing still
require live client verification.

## References

Checked on 2026-11-07:

- [Claude Code Stop](https://code.claude.com/docs/en/hooks#stop)
- [Codex hooks](https://developers.openai.com/codex/hooks)
- [Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)
- [Copilot SDK persisted event types](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/session-events.ts)
