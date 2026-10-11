# Windows package management with mise

Windows packages that winget installs in **user scope** are declared as `winget:` entries under `[bootstrap.packages]` in `home/dot_config/mise/config.toml.tmpl`, using mise's built-in `winget` package manager. Each entry is limited to Windows with `os = ["windows"]`, the same way macOS packages use `brew:` and `brew-cask:`.

mise only records which packages should be present. winget still installs, upgrades, and uninstalls them, so packages that are already installed with winget are recognized as-is and do not need to be reinstalled.

## Which packages go where

| Location | Managed by | Examples |
| --- | --- | --- |
| User scope (`%LOCALAPPDATA%\Microsoft\WinGet\Packages`, `%LOCALAPPDATA%\Programs`, other per-user folders) | mise `winget:` entries | ghq, fzf, uv, azd, Bicep, Codex CLI, Claude Code CLI, Copilot CLI, VS Code, WinSCP, PowerToys |
| `C:\Program Files` (including MSIX apps in `Program Files\WindowsApps`) | `reference/windows/configuration.dsc.yaml` | PowerShell, Git, GitHub CLI, Azure CLI, Visual Studio, Docker Desktop, Windows Terminal, oh-my-posh |
| Microsoft Store (`msstore` source) | `reference/windows/configuration.dsc.yaml` | Desired State Configuration, Codex app, 1Password, Discord |
| Bootstrap | `install.ps1` / `run_once_before_10-install-packages.ps1` and the DSC file | chezmoi, mise |
| Fonts | `reference/windows/configuration.dsc.yaml` | JetBrains Mono Nerd Font and the GitHub Releases fonts |

To decide where a new package belongs, check where it installs. Packages that go under `C:\Program Files` stay in the DSC file. Everything else that winget can install per user goes to mise.

## When packages are applied

- `run_once_after_20-mise-install.ps1` runs `mise install` and `mise bootstrap packages apply --yes` once after the first `chezmoi apply`.
- `run_after_20-mise-upgrade.ps1` runs `mise bootstrap packages apply --yes` on Mondays, after `mise install` and `mise upgrade`.

`apply` only installs missing packages. It does not upgrade installed packages. To upgrade them, run `mise bootstrap packages upgrade` or `winget upgrade`.

## Daily operations

PowerShell 7:

```powershell
# Show which declared packages are installed or missing
mise bootstrap packages status

# Preview, then install missing packages
mise bootstrap packages apply --manager winget --dry-run
mise bootstrap packages apply --manager winget

# Upgrade installed packages that are declared in config
mise bootstrap packages upgrade
```

bash (Git Bash):

```bash
mise bootstrap packages status
mise bootstrap packages apply --manager winget --dry-run
mise bootstrap packages apply --manager winget
mise bootstrap packages upgrade
```

## Adding or removing a package

To add a package, find its winget ID with `winget search` or `winget show --id <ID>` and add an entry:

```toml
"winget:<PackageIdentifier>" = { os = ["windows"] }
```

Removing an entry does not uninstall the package, because the `winget` manager does not support `state = "absent"` or `prune`. Uninstall it with winget yourself.

PowerShell 7 / bash:

```bash
winget uninstall --id <PackageIdentifier>
```

## Moving a package from the DSC file to mise

1. Confirm that the package installs in user scope. Check its install location or run `winget show --id <ID> --scope user`.
2. Remove the `Microsoft.WinGet.DSC/WinGetPackage` resource from `reference/windows/configuration.dsc.yaml`.
3. Add the `winget:` entry to `home/dot_config/mise/config.toml.tmpl` and run `chezmoi apply`.
4. Run `mise bootstrap packages status` and confirm that the package shows as `installed`.

If a package is installed under `C:\Program Files`, keep it in the DSC file even if winget also offers a user-scope installer. Moving it would install a second copy instead of taking over the existing one.
