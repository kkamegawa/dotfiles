# Windows: run_once_after_20-mise-install.ps1
# Install mise tools and apply [bootstrap.packages] (winget entries).
# chezmoi should only run this script on Windows.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
  Write-Warning 'Skipping mise install because this host is not Windows.'
  exit 0
}

if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
  Write-Warning 'Skipping mise install because mise was not found in PATH. Check run_once_before_10-install-packages.ps1.'
  exit 0
}

Write-Output '==> Running mise install...'
mise install

Write-Output '==> Applying mise bootstrap packages...'
mise bootstrap packages apply --yes

Write-Output '==> mise install complete'
