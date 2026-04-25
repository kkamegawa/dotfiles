# Windows bootstrap script.
# Usage: ./install.ps1 (PowerShell 7 or later is recommended)
#
# Steps:
#   1. Apply dotfiles with chezmoi.
#   2. Configure the Windows environment with WinGet Configuration.
#   3. Install tools with mise.
#   4. Apply Copilot CLI configuration with APM.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
  throw 'install.ps1 is Windows-only. Use ./install.sh on macOS, Linux, or WSL.'
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw 'winget was not found. Install App Installer before running the Windows bootstrap script.'
}

Write-Output '==> Starting dotfiles setup (Windows)'

if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
  Write-Output '==> Installing chezmoi...'
  winget install --id twpayne.chezmoi --accept-package-agreements --accept-source-agreements
}

Write-Output '==> Running chezmoi init & apply...'
chezmoi init --apply kkamegawa

$dscFile = "$(chezmoi source-path)\reference\windows\configuration.dsc.yaml"
if (Test-Path $dscFile) {
  Write-Output '==> Applying WinGet Configuration...'
  winget configure -f $dscFile --accept-configuration-agreements
}

Write-Output ""
Write-Output '==> Setup complete. Run the following commands next:'
Write-Output '    gh auth login'
Write-Output '    mise install'
Write-Output '    apm install'
