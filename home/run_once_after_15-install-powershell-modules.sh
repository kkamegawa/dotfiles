#!/bin/sh
# Install common PowerShell modules after PowerShell itself is available.

set -e

if ! command -v pwsh >/dev/null 2>&1; then
  echo "==> pwsh が見つからないため、PowerShell モジュールのインストールをスキップします" >&2
  exit 0
fi

echo "==> PowerShell モジュールをインストールします..."

pwsh -NoLogo -NoProfile -Command '
$ErrorActionPreference = "Stop"

$psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
$previousInstallationPolicy = $null

if ($psGallery) {
  $previousInstallationPolicy = $psGallery.InstallationPolicy
}

$modules = @(
  "Az",
  "Microsoft.Entra",
  "Microsoft.Graph"
)

try {
  if ($psGallery -and $previousInstallationPolicy -ne "Trusted") {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  }

  foreach ($name in $modules) {
    if (Get-Module -ListAvailable -Name $name) {
      Write-Host "==> $name は既にインストール済みです"
      continue
    }

    Write-Host "==> $name をインストールします..."
    Install-Module -Name $name -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
  }
}
finally {
  if ($psGallery -and $previousInstallationPolicy -and $previousInstallationPolicy -ne "Trusted") {
    Set-PSRepository -Name PSGallery -InstallationPolicy $previousInstallationPolicy
  }
}
'
