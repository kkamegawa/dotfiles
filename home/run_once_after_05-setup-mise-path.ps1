# Windows: run_once_after_05-setup-mise-path.ps1
# mise shims を User PATH に永続追加する
# chezmoi が Windows で初回実行時のみ実行する

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$miseShims = "$env:LOCALAPPDATA\mise\shims"

if (-not (Test-Path $miseShims)) {
  Write-Warning "mise shims ディレクトリが見つかりません: $miseShims"
  Write-Output "   winget configure で mise をインストール後に再実行してください。"
  exit 0
}

$currentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
if ($currentPath -notlike "*$miseShims*") {
  Write-Output "==> mise shims を User PATH に追加します: $miseShims"
  $newPath = "$miseShims;$currentPath"
  [System.Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
  $env:PATH = "$miseShims;$env:PATH"
  Write-Output "==> PATH 更新完了。新しいターミナルで有効になります。"
} else {
  Write-Output "==> mise shims は既に PATH にあります"
}
