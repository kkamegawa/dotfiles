# Install Volta-managed global npm packages listed in apm.yml.
$ErrorActionPreference = 'Stop'

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
    Write-Warning 'Skipping Windows Volta package installation because this host is not Windows.'
    exit 0
}

if (-not (Get-Command volta -ErrorAction SilentlyContinue)) {
    Write-Output "volta not found, skipping global npm package install"
    exit 0
}

volta install @microsoft/workiq
