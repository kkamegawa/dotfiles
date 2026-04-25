# Windows ブートストラップスクリプト
# 使い方: ./install.ps1（PowerShell 7 以上を推奨）
#
# 手順:
#   1. chezmoi で dotfiles を適用
#   2. WinGet Configuration で Windows 環境を構成
#   3. mise でツールをインストール
#   4. APM で Copilot CLI 設定を適用

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==> dotfiles セットアップを開始します (Windows)" -ForegroundColor Cyan

# chezmoi がなければインストール
if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
  Write-Host "==> chezmoi をインストールします..."
  winget install --id twpayne.chezmoi --accept-package-agreements --accept-source-agreements
}

# chezmoi init & apply
Write-Host "==> chezmoi init & apply を実行します..."
chezmoi init --apply kkamegawa

# WinGet Configuration で Windows 環境を構成
$dscFile = "$(chezmoi source-path)\reference\windows\configuration.dsc.yaml"
if (Test-Path $dscFile) {
  Write-Host "==> WinGet Configuration を適用します..."
  winget configure -f $dscFile --accept-configuration-agreements
}

Write-Host ""
Write-Host "==> セットアップ完了。続けて以下を実行してください:" -ForegroundColor Green
Write-Host "    gh auth login"
Write-Host "    mise install"
Write-Host "    apm install"
