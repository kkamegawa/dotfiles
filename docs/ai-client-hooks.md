# Shared Claude, Codex and Copilot CLI hooks

[日本語](ai-client-hooks_ja.md)

Claude's existing hook registrations and scripts are unchanged. Codex and
Copilot CLI receive the same actual command guards, not copies of their rules.
chezmoi includes the Claude sources into `~/.local/share/dotfiles/ai-hooks/`;
neither client needs an installed `~/.claude` directory.

## Coverage and limits

| Existing Claude feature | Codex | Copilot CLI |
| --- | --- | --- |
| `guard.mjs`: pipe-to-shell denial, trusted `gh pr`/`gh issue` approval | `PreToolUse` | `PreToolUse` |
| Leading-assignment and directory-change guards | `PreToolUse` | `PreToolUse` |
| `format.mjs` after Edit/Write | Async `PostToolUse` | Synchronous `PostToolUse` |
| Save compaction summary, restore once at next user prompt | `PostCompact` + `UserPromptSubmit`, best effort | Unsupported; not registered |
| `statusline.mjs` | Not ported | Not ported |

**The current formatter is a no-op**: it consumes JSON and exits without editing
files. The adapter preserves this behavior for actual Codex `apply_patch` and
Copilot `edit`/`create`/`apply_patch` input. Patch text is never interpreted as a
file path. Copilot's command-hook schema does not advertise Codex-style `async`;
the inexpensive no-op runs synchronously.

Codex does not expose Claude's `compact_summary` in its documented PostCompact
payload. Recovery accepts that field when available, otherwise reads only the
latest `{"type":"compacted","payload":{"message":"..."}}` record from
`transcript_path`. **The transcript is not a stable API**: absent/unknown formats
produce a visible skip diagnostic, not invented summaries. Read/parse/write
failures are reported as hook failures using exit 1, not Codex's prompt-blocking
exit 2. A new compaction clears stale saved state before attempting recovery.
Session identifiers are hashed, stored separately
under the shared directory's `state/codex`, and restored only once. This Node
adapter matches the existing C# hooks' save/restore behavior without changing
Claude's `.claude/hooks-state` or introducing a .NET dependency for other clients.

Copilot currently has only **PreCompact**, not PostCompact. Its configured
UserPromptSubmit command-hook output is dropped. Running recovery before
compression or registering a fictitious event would not provide parity; neither
is done. The status line is a separate Claude feature, not a lifecycle hook.
These are local CLI configurations, not Copilot cloud-agent or VS Code deployment.

## Configuration, errors and ownership

- Codex uses inline `[hooks]` in its existing merged `~/.codex/config.toml`.
  No managed `hooks.json` is added; existing hook files remain untouched.
  If you already use `~/.codex/hooks.json`, Codex combines both sources and warns.
  Review your local sources rather than adding the same hooks twice.
- Copilot uses `~/.copilot/hooks/dotfiles.json`, version 1, PascalCase events
  (compatible snake_case payloads), direct `exec` + `args`, and `timeoutSec`.
  No command/bash/powershell field is combined with exec. Other hook files and
  inline settings are untouched. Custom `COPILOT_HOME`/`CODEX_HOME` locations
  require adapting the deployment; the managed defaults assume standard homes.
- Merges replace handlers referencing the shared `ai-hooks/adapter.*` path,
  retain foreign handlers even in the same Codex matcher group, retain other
  lifecycle events and metadata, and are idempotent on repeated apply.
- macOS/Linux use POSIX `sh` + Node.js; Windows uses PowerShell **7+** (`pwsh`)
  + Node.js. Only the host's shell scripts are deployed. Shell commands arrive
  as canonical `Bash` in Codex even on a PowerShell host. Copilot native `bash`
  and `powershell` names are normalized to the shared guard payload.
- The adapter runs assignment and directory guards **before** trusted approval.
  Invalid shell payloads, missing scripts/interpreters and guard failures emit
  an explicit denial plus exit 2; payload commands are never executed.
  Successful unrelated commands emit nothing and keep normal permission flow.
  Copilot gets a direct permission decision; Codex gets `hookSpecificOutput`.
  The guards retain their existing host-specific syntax limits described in
  [Claude command hooks](claude-command-hooks.md); they are not complete shell
  security enforcement. Client trust, disable settings, tool coverage and
  timeout behavior still apply. In particular, Copilot hook timeouts can fail
  open; these user hooks are not an administrator policy boundary.

## Installation and verification

Preview with the appropriate shell, using your checkout's absolute path:

```bash
set -e
chezmoi --source "/absolute/path/to/dotfiles" diff --exclude scripts \
  "$HOME/.local/share/dotfiles/ai-hooks" "$HOME/.codex/config.toml" "$HOME/.copilot/hooks"
chezmoi --source "/absolute/path/to/dotfiles" apply --exclude scripts \
  "$HOME/.local/share/dotfiles/ai-hooks" "$HOME/.codex/config.toml" "$HOME/.copilot/hooks"
```

```powershell
chezmoi --source "C:/absolute/path/to/dotfiles" diff --exclude scripts `
  "$HOME/.local/share/dotfiles/ai-hooks" "$HOME/.codex/config.toml" "$HOME/.copilot/hooks"
if ($LASTEXITCODE -ne 0) { throw "chezmoi preview failed" }
chezmoi --source "C:/absolute/path/to/dotfiles" apply --exclude scripts `
  "$HOME/.local/share/dotfiles/ai-hooks" "$HOME/.codex/config.toml" "$HOME/.copilot/hooks"
if ($LASTEXITCODE -ne 0) { throw "chezmoi apply failed" }
```

For a selective apply, parent directories must already exist (a normal full
chezmoi apply creates them). The Codex target also merges its other managed
settings. No install, actual HOME apply or hook-trust bypass runs as part of tests.

Restart clients after application. In Codex, use **`/hooks` to review and trust
the exact new definitions**; untrusted hooks are skipped. Do not bypass this
review. In Copilot, check loaded hooks and test a harmless allowed command and
a denied directory change in a disposable session.

Tests use isolated temporary homes, render/deploy all three OS variants, run
generated command strings and direct executable arguments, verify foreign-hook
preservation/idempotence, malformed-input and missing-dependency denial, real
sh/PowerShell adapter behavior, and fixture-based one-shot Codex recovery.
Actual Windows/Linux hosts and live client sessions are separate checks; running
their rendered variants on macOS is not proof of native or live-service behavior.

## Reference contracts

- [GitHub Copilot hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)
- [Codex hooks](https://developers.openai.com/codex/hooks)

Coverage follows these public contracts; live CLI session checks remain separate.
