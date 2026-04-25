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

Write-Output "==> dotfiles セットアップを開始します (Windows)"

# chezmoi がなければインストール
if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
  Write-Output "==> chezmoi をインストールします..."
  winget install --id twpayne.chezmoi --accept-package-agreements --accept-source-agreements
}

# chezmoi init & apply
Write-Output "==> chezmoi init & apply を実行します..."
chezmoi init --apply kkamegawa

# WinGet Configuration で Windows 環境を構成
$dscFile = "$(chezmoi source-path)\reference\windows\configuration.dsc.yaml"
if (Test-Path $dscFile) {
  Write-Output "==> WinGet Configuration を適用します..."
  winget configure -f $dscFile --accept-configuration-agreements
}

Write-Output ""
Write-Output "==> セットアップ完了。続けて以下を実行してください:"
Write-Output "    gh auth login"
Write-Output "    mise install"
Write-Output "    apm install"
