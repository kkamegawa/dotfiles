# Windows: run_once_after_05-setup-mise-path.ps1
# Add mise shims to the persistent user PATH.
# chezmoi should only run this script on Windows.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
  Write-Warning 'Skipping Windows mise PATH setup because this host is not Windows.'
  exit 0
}

$miseShims = "$env:LOCALAPPDATA\mise\shims"

if (-not (Test-Path $miseShims)) {
  Write-Warning "mise shims directory was not found: $miseShims"
  Write-Output '   Install mise with winget configure, then run this script again.'
  exit 0
}

$currentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
if ($currentPath -notlike "*$miseShims*") {
  Write-Output "==> Adding mise shims to the user PATH: $miseShims"
  $newPath = "$miseShims;$currentPath"
  [System.Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
  $env:PATH = "$miseShims;$env:PATH"
  Write-Output '==> PATH update complete. Open a new terminal to use it.'
} else {
  Write-Output '==> mise shims are already in PATH'
}
