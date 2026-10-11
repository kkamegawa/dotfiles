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

# winget adds mise to the persistent PATH, which this process does not inherit
# when mise was installed earlier in the same chezmoi apply. Reload it here.
$env:PATH = @(
  [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
  [System.Environment]::GetEnvironmentVariable('PATH', 'User')
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
  $env:PATH
) -join ';'

# Fail instead of skipping so chezmoi does not record this run_once_ script as done.
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
  throw 'mise was not found in PATH. Check run_once_before_10-install-packages.ps1.'
}

Write-Output '==> Running mise install...'
mise install
if ($LASTEXITCODE -ne 0) {
  throw "mise install failed with exit code $LASTEXITCODE."
}

Write-Output '==> Applying mise bootstrap packages...'
mise bootstrap packages apply --yes
if ($LASTEXITCODE -ne 0) {
  throw "mise bootstrap packages apply failed with exit code $LASTEXITCODE."
}

Write-Output '==> mise install complete'
