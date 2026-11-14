# macOS .NET SDK management

- Status: approved design and implementation; migration is a user-run operation, not a CI action
- Date: 2026-10-26
- Last updated: 2026-11-14 (Issue #128)
- Scope: macOS SDK ownership, CLI/IDE/agent environment, maintenance, and rollback
- Implementation tracking: parent Issue #83 and child issues #84-#86; latest-channel update in Issue #128.
- Japanese translation: [macOS .NET SDK 管理](macos-dotnet-management_ja.md)

## Goal and boundaries

Use core mise to maintain one stable .NET SDK root on macOS, so CLI, VS Code, VS Code Insiders, Rider, and repository-owned automation resolve compatible SDKs and runtimes. Project `global.json` remains the authority for project SDK selection. Runtime discovery for apphosts and GUI-launched processes is a separate concern from shell `PATH` and project SDK selection.

Windows and Linux SDK ownership is unchanged. The migration is a user-invoked script, never a chezmoi migration hook. Do not alter other repositories' project files, upgrade projects pinned to .NET 8, or assume that an IDE terminal proves its C# extension is using the same SDK. IDE-managed private runtimes and Rider's bundled runtime can remain installed.

## Ownership model

| Concern | macOS owner | Contract |
|---|---|---|
| SDK installation and updates | mise core `dotnet` backend | Shared root at `~/.local/share/mise/dotnet-root`; configured major channels plus explicitly retained exact versions |
| Project SDK selection | Project `global.json` | Keep each repository's existing roll-forward policy; install missing exact SDKs as retained requirements |
| CLI runtime discovery | Shell and agent environment | Set `DOTNET_ROOT` and the matching architecture variable; put the managed host and `~/.dotnet/tools` on `PATH` |
| GUI apphost discovery | Architecture-specific system registration | User-maintained `/etc/dotnet/install_location_arm64` or `_x64` points to the shared root |
| .NET global tools | macOS shell update hook | Run after successful mise install; preserve `~/.dotnet/tools` and do not auto-update the duplicate GCM tool |
| C# hooks and mise cleanup tasks | `dotfiles-dotnet10` runner | Select a .NET 10 SDK in a private runner directory, independent of the caller's project `global.json` |

Do not set `MSBuildSDKsPath` or global `DOTNET_HOST_PATH`. `mise activate` owns contextual `PATH` and `DOTNET_ROOT` updates after the profile establishes the stable base. Keep the architecture-specific variable aligned with `DOTNET_ROOT`. Report project-local mise settings that select another root or isolated mode as conflicts.

## mise configuration and retained SDKs

On macOS, configure `dotnet = ["sts", "lts"]` under `[tools]` to track the latest SDK in each supported channel. On 2026-11-14, these resolve to .NET 11 STS (SDK 11.0.100) and .NET 10 LTS (SDK 10.0.404). Keep `dotnet.dotnet_root` pointed at the shared root and `dotnet.isolated = false` under the existing `[settings]` table. Remove only the `brew-cask:dotnet-sdk` declaration. Do not create duplicate TOML tables. Other platforms and unrelated casks retain their existing owners.

The `sts` and `lts` channels follow the newest stable supported release of each support type. Do not retain historical .NET 8 or .NET 10 SDK patches by default. The template validates the legacy local `~/.config/dotfiles/dotnet-retained-sdks.json` manifest but ignores its version entries under this latest-only policy, so existing pins cannot re-add old SDKs. The current macOS installation therefore keeps only the latest SDK from each channel. For each installed SDK major, runtime cleanup keeps only the newest installed patch of `Microsoft.NETCore.App`, `Microsoft.AspNetCore.App`, and `host/fxr`; runtime versions for SDK majors that are no longer installed are removed from the managed root and the legacy `~/.dotnet` root. Keep `~/.dotnet/tools`. .NET 8 support ended on 2026-11-10; removing its SDK and runtimes does not upgrade projects that still target .NET 8. IDE-private runtimes and Rider's bundled runtime remain outside this cleanup.

Use mise 2026.10.17 or later for this repository configuration. Routine macOS updates use `mise upgrade --global --prune dotnet`, followed by `mise prune --tools dotnet`, to install the latest configured SDKs and remove SDK versions that are no longer requested. The macOS hook then removes outdated shared runtime and hostfxr directories, preserving the newest runtime patch for each installed SDK major and retaining `~/.dotnet/tools`. Do not use `--bump`. The updater installs the SDK before pruning or updating global tools and does not fall back to the old system SDK on failure. Bootstrap package apply does not uninstall undeclared packages; removal of the SDK cask is a separate, explicit finalization action.

The shell profile initializes the stable .NET environment before its idempotence guard and before `mise activate`. The PowerShell profile follows the same rule. Keep the setup idempotent across `.zshenv`, `.zprofile`, and `.zshrc` sourcing, including macOS `path_helper` ordering. On macOS the shell hook alone updates global tools; PowerShell returns before doing tool work. Initial setup installs the SDK before the ordinary post-setup tool updater runs.

## IDE, agent, and automation behavior

### VS Code and Insiders

The login profile provides the managed host to applications launched from Finder or the Dock. Test each app after a complete process restart. Do not use the C# extension's runtime acquisition paths to choose a project SDK. Inspect actual user, profile, and workspace settings for stale SDK overrides; preserve extension-private runtimes and unrelated settings. Confirm the C# project system's SDK/build logs and build, run, or test a representative project. An integrated terminal's `dotnet --info` is not sufficient evidence.

### Rider

For each solution, select the absolute managed `dotnet` executable in Toolset and Build, disable automatic SDK downloads, and verify that MSBuild uses the same selection policy. These settings are per solution; check existing configured solutions separately. Keep Rider's bundled runtime. The Bicep runtime may share the managed root and should be exercised after setup.

### Codex and Claude Code

Codex remains non-login-shell. Its managed Darwin environment explicitly supplies the absolute managed `PATH`, `DOTNET_ROOT`, and architecture-specific root while preserving cache, authentication, and unrelated environment settings. Claude Code hooks use the absolute .NET 10 runner, and Darwin child commands receive the managed environment through their settings. Keep the existing `DOTNET_CLI_HOME` behavior and `~/.dotnet/tools` inventory separate. Do not add SDK installer hosts or write permissions to agent sandboxes for this setup.

### .NET 10 runner

`dotfiles-dotnet10` uses the managed host and a private `global.json` directory to select .NET 10, then invokes an absolute C# file while preserving arguments, standard streams, and exit status. Route macOS Claude PostCompact and UserPromptSubmit hooks and the four .NET file-based mise tasks through it. Preserve other operating systems' invocation. The runner selects an SDK; it never installs one. This avoids a project-level .NET 8 `global.json` from breaking .NET 10 file programs.

## System registration and credential helper

GUI-launched apphosts may not inherit profile variables. The architecture-specific `/etc/dotnet/install_location_*` registration therefore points to the expanded absolute shared root. It is host-wide runtime discovery only: it does not select a CLI executable or project SDK. Do not write `~` or shell variables into the registration. Preserve the legacy unsuffixed and other-architecture registrations; never point an x64 registration at an ARM64 root. Do not redirect system `paths.d` entries or create substitute Homebrew links into a user directory.

On macOS, Git uses the native GCM package's absolute executable. Keep the duplicate dotnet global tool installed but stop updating it automatically. Verify the configured helper and a harmless version command; do not request or print credentials.

## User-run initial SDK migration script

The Bash script is the implementation; the PowerShell 7 script is its argument- and exit-code-preserving wrapper. Both refuse non-macOS execution. This is the original Homebrew-to-mise migration procedure; ongoing SDK updates use the STS/LTS policy above. Each phase is explicit except that omitting a phase runs the read-only `plan` phase.

```sh
bash scripts/migrate-dotnet-macos.sh plan \
  --state-dir "$HOME/.local/state/dotfiles-dotnet-migration" \
  --project /absolute/path/to/project \
  --sdk 10.0.401 --sdk 8.0.404
```

Repeat `--project` for every relevant repository and `--sdk` for every exact SDK requirement discovered during inventory. These versions match the migration script's original .NET 10/.NET 8 baseline; they are not the current STS/LTS channel configuration. The inventory reads ancestor and nested `global.json` policies under each selected project root or solution, and archives the exact SDK version reported by the installed `dotnet-sdk` cask for rollback. Use an absolute state directory and project roots. Review the proposed changes before running a mutating phase. Run `prepare`, `switch`, `verify`, and `finalize` explicitly and in order. Add `--ide-checks-confirmed` only after manually completing the IDE checks. Use `rollback` to restore the recorded prior configuration and registration if needed.

The script maintains phase checkpoints, locks against concurrent runs, and validates the baseline before resuming. It uses a private state directory for backups and inventories; it must not log credentials or dump the full process environment. It deploys only the approved target files with hooks excluded and does not run a whole-tree chezmoi apply, unrelated package upgrades, `mise prune`, `--zap`, or system-wide SDK installation. The privileged registration helper is limited to the expected architecture-specific registration file. The user runs that operation and any package uninstall.

| Phase | Effect | Evidence required to proceed |
|---|---|---|
| `plan` | Read-only host, SDK, runtime, project, and consumer inventory | Review exact proposed changes and missing dependencies |
| `prepare` | Back up affected state, record retained SDKs and inventory workloads, install the required SDKs | Confirm old roots remain intact and required SDKs are visible; existing workloads without a supported restore path stop preparation |
| `switch` | Deploy approved configuration and runner, update system registration, generate required shims | Confirm CLI, agents, and apphost discovery use the managed root |
| `verify` | Exercise selected projects, hooks/tasks, Codex, apphosts, GCM, and IDEs | Record automated and user-observed results separately |
| `finalize` | After explicit attestation, remove only the old SDK cask and repeat critical checks | Confirm all consumers still work and registration points to the shared root |
| `rollback` | Restore old runtime if needed, then registration and backed-up managed files | Confirm prior selection works and no registration points to a missing root |

The migration script itself does not remove the old `~/.dotnet` installation or runtime directories. After the SDK switch is complete, the regular macOS updater applies the runtime-retention policy above while preserving `~/.dotnet/tools`. Retain the migration backup and installer until the rollback point is explicitly retired. If the original Cask is uninstalled, restoring its SDK files does not recreate Homebrew's package-manager metadata; report any separate re-adoption step.

### PowerShell entry point

```powershell
& ./scripts/migrate-dotnet-macos.ps1 `
  -Phase plan `
  -StateDirectory "$HOME/.local/state/dotfiles-dotnet-migration" `
  -Project @('/absolute/path/to/project') `
  -Sdk @('10.0.401', '8.0.404')
```

Repeat `-Project` and `-Sdk` as required. The PowerShell wrapper forwards the same phase and inputs to the Bash implementation and returns its exit code.

## Verification and operational limits

Automated tests use isolated destinations and fake executables to cover read-only planning, failure stops, resume, rollback conflicts, SDK retention, hook ordering, profile idempotence, and config merging. CI does not run `sudo`, alter the user's SDKs, uninstall packages, or operate IDEs. Passing mocked tests does not establish the migration or GUI acceptance criteria.

During user-run verification, capture the exact selected SDK for each project, run the relevant build/test/run, test both SDK 8-pinned hook/task fixtures and .NET 10 runner, check apphost runtime discovery with profile variables absent, and launch Code/Insiders from Finder or Dock and Rider per solution. Repeat critical checks after finalization. Report failures and manual checks separately; do not infer GUI success from shell output.

The migration remains an explicit user-run operation. On 2026-10-26, the user completed finalization after recording the required post-removal IDE and agent attestation. This host-specific attestation is not reproduced by CI and does not change the migration procedure for other machines.

## References

Repository documentation uses placeholders for external URLs; the corresponding sources were checked during design review.

| Source | Supports |
|---|---|
| `<MISE_DOTNET_REFERENCE>` | mise .NET backend, root and isolated settings |
| `<MISE_LIFECYCLE_REFERENCE>` | upgrade retention and activation behavior |
| `<DOTNET_GLOBAL_JSON_REFERENCE>` | SDK selection and roll-forward |
| `<DOTNET_ENVIRONMENT_REFERENCE>` | runtime environment variables and architecture precedence |
| `<VSCODE_DOTNET_REFERENCE>` | C# extension runtime versus project SDK |
| `<RIDER_TOOLSET_REFERENCE>` | per-solution CLI selection and SDK download settings |
| `<DOTNET_SUPPORT_POLICY_REFERENCE>` | .NET 8 support lifecycle |
| [mise .NET](https://mise.jdx.dev/lang/dotnet.html) | Latest .NET `lts` and `sts` channels and shared SDK root (checked 2026-11-14) |
| [mise upgrade](https://mise.jdx.dev/cli/upgrade.html) | Upgrade ranges, and `--prune` removal of replaced versions (checked 2026-11-14) |
| [.NET 10 downloads](https://dotnet.microsoft.com/en-us/download/dotnet/10.0) | Latest LTS SDK (10.0.404 on 2026-11-14) |
| [.NET 11 downloads](https://dotnet.microsoft.com/en-us/download/dotnet/11.0) | Latest STS SDK (11.0.100 on 2026-11-14) |
| `<CODEX_ENVIRONMENT_REFERENCE>` | explicit environment for non-login command execution |
| `<CLAUDE_ENVIRONMENT_REFERENCE>` | environment settings for child commands |

## Decision history

| Date | Previous decision | Current decision | Reason | Approval |
|---|---|---|---|---|
| 2026-10-26 | Homebrew-owned SDK and inherited environment | macOS mise shared root, explicit shell/agent/IDE ownership, user-run reversible migration | Align SDK selection and runtime discovery while preserving project policies | User approved the design; user-run migration finalized on one host, outside CI |
| 2026-11-14 | Keep .NET 10 and .NET 8 channels plus exact historical SDK pins; preserve replaced SDKs | Keep only the latest .NET SDK from the STS and LTS channels, pruning replaced and unrequested SDK versions during routine macOS updates | .NET 11 STS is available, .NET 10 is the current LTS, and the user requested latest-only SDKs | User approved in this conversation; Issue #128 tracks the implementation |
| 2026-11-14 | Keep all installed shared runtime and hostfxr versions | Keep the latest runtime patch for each installed SDK major; remove older patches and runtimes for uninstalled SDK majors from the managed and legacy user roots while preserving `~/.dotnet/tools` | The user requested removal of old runtimes along with old SDKs | User approved in this conversation; Issue #128 and PR #129 track the implementation |
