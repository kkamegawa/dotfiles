# PowerShell module cleanup

The global mise configuration includes a cleanup task for old PowerShell module versions.
It runs the C# file-based app at `~/.config/mise/oldpowershellmodule.cs`.

## Targets

The task keeps the latest installed version and removes older versions for modules matching:

- `Az*`
- `Microsoft.Entra*`
- `Microsoft.Graph*`

The app scans `PSModulePath` plus common PowerShell module directories, then detects installed versions from version folder names.
This works with the standard user module locations on both Windows and macOS.

## Run on macOS

```bash
# Preview removals.
mise run clean-old-pwsh-modules-dry-run

# Remove old versions.
mise run clean-old-pwsh-modules
```

## Run on Windows

```powershell
# Preview removals.
mise run clean-old-pwsh-modules-dry-run

# Remove old versions.
mise run clean-old-pwsh-modules
```

## Requirements

- .NET SDK 10 or later
- PowerShell 7
- A PowerShellGet-compatible `Uninstall-Module` command
