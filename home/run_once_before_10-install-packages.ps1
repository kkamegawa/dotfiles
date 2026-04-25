# Windows: run_once_before_10-install-packages.ps1
# winget でブートストラップに必要な最小パッケージをインストール
# chezmoi が Windows で初回実行時のみ実行する

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# winget で gitleaks をインストール（DSC 適用前の最低限のセキュリティツール）
$packages = @(
  'ZedFreeman.Gitleaks'
  'junegunn.fzf'
)

foreach ($id in $packages) {
  $installed = winget list --id $id --accept-source-agreements 2>&1 |
               Where-Object { $_ -match $id }
  if (-not $installed) {
    Write-Host "==> $id をインストールします..."
    winget install --id $id --accept-package-agreements --accept-source-agreements
  } else {
    Write-Host "==> $id は既にインストール済みです"
  }
}
