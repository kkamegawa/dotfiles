# Install Volta-managed global npm packages listed in apm.yml
$ErrorActionPreference = 'Stop'

if (-not (Get-Command volta -ErrorAction SilentlyContinue)) {
    Write-Host "volta not found, skipping global npm package install"
    exit 0
}

volta install @microsoft/workiq
