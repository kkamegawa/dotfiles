# Claude Code leading-assignment hooks

[日本語](claude-command-hooks_ja.md)

The managed `PreToolUse` assignment guard asks Claude Code to use direct
absolute paths instead of starting a command by assigning a path to a variable.
It is a syntax preference, **not an all-purpose shell security boundary**.
It does not execute any command from the hook payload.

## Installation

Requirements:

- chezmoi for rendering and applying the managed settings.
- Windows: PowerShell **7+**, available as `pwsh` on PATH. The hook uses native
  `ConvertFrom-Json`, without loading a PowerShell profile.
- macOS/Linux: a POSIX `sh` on PATH and Node.js (already required by the other
  managed Claude hooks). PowerShell is not required for this hook on Unix.
- Claude Code with command-hook support for the repository's `command` + `args`
  settings format.

Replace the source-directory placeholder below with your checkout. Preview
first, then apply **only the managed hook directory and settings file**. The
explicit script exclusion avoids unrelated chezmoi lifecycle scripts. Applying
settings still merges the repository's other managed settings; it is not a
patch that changes only this one hook.

Bash (macOS/Linux):

```bash
set -e
chezmoi --source "/absolute/path/to/dotfiles" diff --exclude scripts \
  "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
chezmoi --source "/absolute/path/to/dotfiles" apply --exclude scripts \
  "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
```

PowerShell 7 (Windows):

```powershell
chezmoi --source "C:/absolute/path/to/dotfiles" diff --exclude scripts `
  "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
if ($LASTEXITCODE -ne 0) { throw "chezmoi preview failed" }
chezmoi --source "C:/absolute/path/to/dotfiles" apply --exclude scripts `
  "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
if ($LASTEXITCODE -ne 0) { throw "chezmoi apply failed" }
```

`$HOME` above is an existing variable used as an **argument**, not a leading
assignment. Paths containing spaces or non-ASCII characters are JSON-serialized
as separate interpreter arguments.

No real user settings change merely by editing this repository or running the
scratch-destination tests. Settings change when you explicitly run chezmoi apply.
Open `/hooks` in Claude Code afterward and confirm the assignment guard appears
under `PreToolUse`. Restart Claude Code if necessary to reload settings.

## Registration and permissions

| Host | Interpreter and script | Exact tool-name matcher |
| --- | --- | --- |
| Windows | `pwsh -NoLogo -NoProfile -NonInteractive -File` with `leading-assignment.ps1` | `^(Bash\|PowerShell\|powershell)$` |
| macOS/Linux | `sh` with `leading-assignment.sh` | `^Bash$` |

Only the host's assignment script is deployed. The script path is absolute,
derived from the chezmoi Claude home template; the timeout is 10 seconds.
`PowerShell` and `powershell` are explicit Windows tool-name spellings, not a
wildcard for all MCP tools. If a client exposes a differently named tool or
uses a field other than `tool_input.command`, it is not covered without adapting
the registration and payload validation.

The original `guard.mjs` remains a separate hook with its original logic.
Other user-owned hooks survive the merge; repository-owned entries are
recreated without accumulating duplicates on repeated apply. Existing permission
allow/ask/deny rules retain their merge behavior. This guard never emits an
`allow` decision: success leaves the normal permission flow intact. Its blocking
exit takes precedence over another hook's approval in Claude Code.

## Exact coverage

After optional leading whitespace (including newlines):

- Both implementations reject shell-style `NAME=value` and `NAME+=value`,
  where `NAME` is an ASCII shell identifier. Examples: `R='/a path'; git ...`,
  `R=/repo git ...`, and assignment-only `R=/repo`. The shell check requires
  no whitespace between the name and assignment operator.
- Windows also rejects genuine PowerShell leading assignments such as
  `$root = 'C:/repo'`, `$env:ROOT='C:/repo'`, `${root}='C:/repo'`, and
  `${script:root}='C:/repo'`. Simple names use Unicode letters, digits and
  underscores, cannot start with a digit, and may have one such scope/provider
  prefix. Operators covered: `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `??=`.
  These are checked for both Bash and the listed native PowerShell tool names.
- Comparisons such as `$root -eq 'x'` and `$root == 'x'` are not assignments.
  Neither `git -C $root status`, `git -c key=value status`, nor
  `echo "R=/repo"` is rejected.

**Intentional limitations:** `export R=...` and `env R=... command` pass;
their first token is a wrapper, not an assignment. Assignments later in a
command, after a comment, within a script block/subshell, or inside a nested
`pwsh`/shell invocation are not scanned. Neither PowerShell member/index
assignments (`$object.Path=...`, `$root[0]=...`), unusual braced names, nor
`Set-Variable`/`New-Variable` is covered. Unix does not inspect PowerShell syntax.
Existing variable references in arguments are allowed. There are **no new
restrictions on `cd`, chaining, or other shell constructs**. This deliberately
does not prevent every equivalent variable use.

## Outcomes and testing

- Exit **0**, with no stdout/stderr: no covered leading assignment, or a
  well-formed payload for an unrelated tool. This is not permission approval.
- Exit **2**, no stdout, actionable stderr: covered leading assignment.
  Claude should rewrite the command with direct absolute paths.
- Exit **2**, no stdout, diagnostic stderr: malformed JSON, a non-object payload,
  missing/invalid `tool_name`, or missing/non-string `tool_input.command` for a
  covered tool. Fix the hook integration rather than silently allowing it.
  The Unix entrypoint also reports missing Node or a failed Node invocation.

Regression tests run the real scripts using paths with spaces/non-ASCII text,
check accepted commands and intentional gaps, and exercise real chezmoi merges
against scratch destinations. Template tests inspect all three OS registrations;
rendering an OS template is not proof of running on that OS.

Bash, from the repository root:

```bash
set -e
python -m unittest discover -s scripts/tests -p 'test_claude_assignment_hooks.py' -v
python -m unittest discover -s scripts/tests -p 'test_config_merge.py' -v
```

PowerShell 7, from the repository root:

```powershell
python -m unittest discover -s scripts/tests -p 'test_claude_assignment_hooks.py' -v
if ($LASTEXITCODE -ne 0) { throw "Hook tests failed" }
python -m unittest discover -s scripts/tests -p 'test_config_merge.py' -v
if ($LASTEXITCODE -ne 0) { throw "Merge tests failed" }
```

Missing runtime tools produce explicit test skips. These tests do not invoke
Claude Code or verify hook precedence in a live Claude session.
