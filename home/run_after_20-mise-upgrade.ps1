# Windows: run_after_20-mise-upgrade.ps1
# Keep mise-managed tools up to date on every chezmoi apply/update.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
  Write-Warning 'Skipping mise upgrade because this host is not Windows.'
  exit 0
}

if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
  Write-Warning 'Skipping mise upgrade because mise was not found in PATH.'
  exit 0
}

Write-Output '==> Running mise install...'
mise install

Write-Output '==> Running mise upgrade...'
mise upgrade

Write-Output '==> mise install/upgrade complete'
