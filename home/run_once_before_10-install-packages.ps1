# Windows: run_once_before_10-install-packages.ps1
# Install minimal bootstrap packages with winget.
# chezmoi should only run this script on Windows.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
  Write-Warning 'Skipping Windows package installation because this host is not Windows.'
  exit 0
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw 'winget was not found. Install App Installer or run this script from a Windows environment that provides winget.'
}

$packages = @(
  'ZedFreeman.Gitleaks'
  'junegunn.fzf'
)

foreach ($id in $packages) {
  $escapedId = [regex]::Escape($id)
  $installed = winget list --id $id --accept-source-agreements 2>&1 |
               Where-Object { $_ -match $escapedId }
  if (-not $installed) {
    Write-Output "==> Installing $id..."
    winget install --id $id --accept-package-agreements --accept-source-agreements
  } else {
    Write-Output "==> $id is already installed"
  }
}
