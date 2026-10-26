# Codex and Claude Code configuration ownership

`~/.codex/config.toml` and `~/.claude/settings.json` are written by both this repository and the apps themselves. The repository therefore does not own the whole file. It owns a set of **managed keys** and merges them into the real file on every `chezmoi apply`; every other key stays as the local app left it.

## Ownership model

| Layer | Content | Owner |
| --- | --- | --- |
| common | OS-independent shared settings (sub-agents, model, approval policy, allowed domains) | repository |
| os overlay | Windows / macOS / Linux specifics (paths, sandbox, notify, permission lists) | repository |
| local | Values the apps rewrite: plugins, project trust, app version values, injected hooks | local machine |

The local layer is never written by the repository. A key belongs to the repository only when it appears in a managed fragment.


## macOS .NET execution environment

The Darwin overlay adds an absolute managed PATH and DOTNET_ROOT/architecture-specific runtime root under shell_environment_policy.set. It retains allow_login_shell=false, the existing DOTNET_CLI_HOME/NuGet cache values, model/auth settings and secret exclusions. Values are rendered by chezmoi; shell expressions such as a literal $PATH are not expansion mechanisms in the set table.

macOS repository-owned Claude C# hooks invoke the absolute .NET 10 runner. Its private global.json/cwd avoids an unrelated project's SDK pin while preserving hook input/output. SDK installation stays in user-run migration/chezmoi operations outside agent sandboxes; this change adds no installer-host allowlist or sandbox bypass. See [macOS .NET management](macos-dotnet-management.md).

## Mechanism

Each file is produced by a chezmoi `modify_` template (a file whose body contains the `chezmoi:modify-template` marker, without a `.tmpl` suffix). chezmoi passes the current target to the template as `.chezmoi.stdin`; the template parses it, merges the managed fragments into it, and prints the result.

- No interpreter, Python, or uv is needed, so the same source works on Windows, macOS, Linux/WSL, and Dev Containers.
- `modify_` targets are not subject to the "has changed since chezmoi last wrote it" prompt, so an app rewriting the file never breaks `chezmoi apply`.
- `chezmoi diff` and `chezmoi apply --dry-run` show the merge result.

| Source | Target |
| --- | --- |
| `home/dot_codex/modify_private_config.toml` | `~/.codex/config.toml` |
| `home/dot_claude/modify_settings.json` | `~/.claude/settings.json` |
| `home/.chezmoitemplates/codex/{common,darwin,linux,windows}.toml` | managed Codex fragments |
| `home/.chezmoitemplates/claude/{common,unix,windows}.json` | managed Claude fragments |
| `home/.chezmoitemplates/merge/deep` | shared deep-merge template with array-union paths |
| `home/.chezmoitemplates/{codex,claude}/paths` | shared path helpers (home, cache root, Claude home) |

A fragment set is common first, then the overlay for `.chezmoi.os`. The overlay wins on conflicts.

## Merge rules

- Tables and scalars: the managed value overwrites the local value; unmanaged keys are preserved.
- Arrays: replaced by the managed value, except at the union paths below, where managed items are always present and local extras are kept.
- Repository-owned Claude hooks: an entry whose command references the repository hook directory under the Claude home is repository-owned. It is removed and re-added from the fragment, so edits do not leave duplicates. Other hook entries (for example, ones injected by other tools) are kept.
- An empty or missing target is treated as an empty document.
- A target that cannot be parsed makes the template fail, so `chezmoi apply` stops with an error and the file is not overwritten.

Because the result is re-serialized, comments in the target are dropped, tables are re-indented, and keys are sorted. This is a known cost of the template mechanism.

Removing an item from a union array in the repository does not remove it from machines that already have it. Remove it by hand, or temporarily move it to a managed replace path.

## Key classification

### Codex (`config.toml`)

| Managed (repository) | Local (app-owned) |
| --- | --- |
| `approval_policy`, `approvals_reviewer`, `default_permissions`, `allow_login_shell`, `model`, `model_reasoning_effort`, `web_search` | `mcp_servers.node_repl` and its `env` (`BROWSER_USE_*`, `NODE_REPL_*`, `CODEX_*`, `SKY_*`) |
| `notify` (macOS only) | `marketplaces.*` |
| `permissions.*`, `features.*`, `shell_environment_policy.*`, `windows.sandbox` (Windows only) | `plugins.*` |
| `agents.*`, `desktop.*`, `mcp_servers.learn_mcp` | `projects.*` |

Codex has no union paths; all arrays are replaced.

### Claude Code (`settings.json`)

| Managed (repository) | Local |
| --- | --- |
| `model`, `advisorModel`, `effortLevel`, `env`, `language`, `cleanupPeriodDays`, `subagentPromptCacheTtl`, `attribution`, notification flags, `enableWorkflows` | `enabledPlugins` |
| `permissions`, `sandbox`, `statusLine`, `extraKnownMarketplaces` | hook entries not owned by the repository |
| `hooks` entries for the repository hook scripts | any other key the app adds |

Union paths: `permissions.allow`, `permissions.ask`, `permissions.deny`, `permissions.additionalDirectories`, `sandbox.network.allowedDomains`, `sandbox.filesystem.allowWrite`, `sandbox.excludedCommands`, and each `hooks.<event>` array.

OS differences live in the overlays: the Windows overlay uses PowerShell read-only commands in `permissions.allow` and denies `curl` / `wget`; the Unix overlay uses the POSIX equivalents. Hook paths are built from `.chezmoi.homeDir` with backslashes replaced by slashes.

The Windows overlay also sets `permissions.additionalDirectories` to the Visual Studio and Codex for Visual Studio log folders, so reading them is not blocked by `blockReadsOutsideWorkingDirectories`. The folders under `VisualStudio/*/VSExtensions` contain a per-instance ID, and the setting does not document glob support, so the overlay expands the pattern with chezmoi's `glob` function at apply time. Run `chezmoi apply` again after a new Visual Studio instance appears. Folders in `additionalDirectories` are writable as well as readable.

The MCP server name appears in the tool name (`mcp__microsoft-learn__*` in `permissions.allow`), so the server must be registered under that name. `~/.claude.json` holds session state and is not managed by this repository; `home/run_after_70-setup-claude-mcp.{sh,ps1}` register the user-scope `microsoft-learn` server on every apply when it does not exist yet, and skip when `claude` is not in PATH.

### Git / gh outside the sandbox

Credential manager access (keychain, GUI) and the `gh` TLS trust store are blocked inside the sandbox, and .NET needs a fixed `/tmp/.dotnet/shm` work directory. Both tools are relaxed the same way:

| Tool | Networked git and `gh` outside the sandbox | `/tmp/.dotnet` writable |
| --- | --- | --- |
| Claude Code | `sandbox.excludedCommands`: `gh *`, `git push/fetch/pull/clone/ls-remote *` (common fragment) | `sandbox.filesystem.allowWrite` (Unix overlay) |
| Codex | `home/dot_codex/rules/dotfiles.rules` (`prefix_rule` with `decision = "allow"`; `config.toml` has no equivalent option) | `permissions.dotnet-dev.filesystem` (darwin / linux fragments) |

Excluded commands run without sandbox restrictions. Local-only git operations such as `git commit` and `git status` are not excluded. Force pushes stay behind a prompt in Codex and are denied in Claude Code.

## Operations

- Add or change a shared setting: edit the fragment, then run `chezmoi diff` and `chezmoi apply`.
- Let an app own a key: leave it out of the fragments. Nothing else is needed.
- Move a key from local to managed: add it to a fragment. The next apply overwrites the local value.
- First apply after migration: the file is re-serialized once (comments dropped, keys sorted); app-owned keys are kept.

bash (macOS / Linux):

```bash
chezmoi diff ~/.codex/config.toml
chezmoi apply ~/.codex/config.toml ~/.claude/settings.json
```

PowerShell 7:

```powershell
chezmoi diff ~/.codex/config.toml
chezmoi apply ~/.codex/config.toml ~/.claude/settings.json
```

## Verification

`scripts/tests` applies the templates to fixture files in a scratch chezmoi source, destination, and state, and checks: managed keys applied, app-owned keys preserved, union and replace behavior, hook ownership, idempotence on a second apply, and that invalid input fails without changing the file. The `lint.yml` workflow runs it on Linux, Windows, and macOS, including isolated migration/runner tests.

## .NET decision change history

| Date | Previous decision | New decision | Reason | Approval |
|---|---|---|---|---|
| 2026-10-26 | System SDK and inherited PATH; shared OS tool hook execution | Stable mise root, one updater per OS, explicit agent environment and isolated SDK 10 runner | Manual migration design review; see macos-dotnet-management.md | User approved design; host migration remains an explicit user-run operation |
