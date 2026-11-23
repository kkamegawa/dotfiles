# Windows: APM 依存関係をステージングし、インストール成功後に反映する。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateHome = Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'apm-profile'
$manifest = if ($env:APM_MANIFEST) { $env:APM_MANIFEST } else { Join-Path $HOME 'apm.yml' }
$publisher = if ($env:APM_PROFILE_PUBLISHER) { $env:APM_PROFILE_PUBLISHER } else { Join-Path $HOME '.config/apm-profile/apm-profile-publish.py' }

if (-not (Get-Command apm -ErrorAction SilentlyContinue)) {
  Write-Warning 'PATH に apm がないため、APM プロファイル更新をスキップします。'
  exit 0
}
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
  Write-Warning "$manifest がないため、APM プロファイル更新をスキップします。"
  exit 0
}
# Microsoft Store の python.exe スタブ (WindowsApps) は実体がなく、実行すると 9009 で失敗する。
# 実際にバージョンを取得できる Python のみ採用する。
# PATH に mise の shims がない (または WindowsApps より後ろにある) 場合に備え、shims を明示的に探す。
$python = $null
$miseShimPython = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' }) 'mise/shims/python.exe'
$candidates = @(
  @(Get-Command python -All -CommandType Application -ErrorAction SilentlyContinue)
  @(Get-Command $miseShimPython -CommandType Application -ErrorAction SilentlyContinue)
  @(Get-Command py -All -CommandType Application -ErrorAction SilentlyContinue)
)
foreach ($group in $candidates) {
  foreach ($cmd in $group) {
    # WindowsApps には動作する Store 版 Python や py.exe のエイリアスもあるため、パスでは除外せず、
    # 起動して "Python X.Y" が返るかで判定する。起動自体に失敗した候補は次へ進む。
    $versionArgs = if ($cmd.Name -in 'py.exe', 'py') { @('-3', '--version') } else { @('--version') }
    try {
      $versionOutput = (& $cmd.Source @versionArgs 2>&1 | Out-String)
      $probeExit = $LASTEXITCODE
    } catch {
      continue
    }
    if ($probeExit -eq 0 -and $versionOutput -match '^\s*Python\s+\d+\.\d+') { $python = $cmd; break }
  }
  if ($python) { break }
}
if (-not $python) {
  Write-Warning '利用可能な Python (PATH / mise shims) がないため、APM プロファイル更新をスキップします。'
  exit 0
}

New-Item -ItemType Directory -Path $stateHome -Force | Out-Null
$candidate = Join-Path $stateHome ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $candidate | Out-Null
try {
  Copy-Item -LiteralPath $manifest -Destination (Join-Path $candidate 'apm.yml')
  $output = $candidate
  Push-Location $candidate
  try {
    & apm install --refresh --root $candidate --target claude,codex,copilot
    if ($LASTEXITCODE -ne 0) { throw "APM のステージングに失敗しました (終了コード: $LASTEXITCODE)。" }
  } finally {
    Pop-Location
  }

  if ($python.Name -eq 'py.exe' -or $python.Name -eq 'py') {
    & $python.Source -3 $publisher $output $stateHome
  } else {
    & $python.Source $publisher $output $stateHome
  }
  if ($LASTEXITCODE -ne 0) { throw "APM プロファイルの反映に失敗しました (終了コード: $LASTEXITCODE)。" }
} finally {
  Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue
}
