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

if (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) {
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

$modules = @(
  "Az",
  "Microsoft.Entra",
  "Microsoft.Graph"
)

foreach ($name in $modules) {
  if (Get-Module -ListAvailable -Name $name) {
    Write-Host "==> $name は既にインストール済みです"
    continue
  }

  Write-Host "==> $name をインストールします..."
  Install-Module -Name $name -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}
'
