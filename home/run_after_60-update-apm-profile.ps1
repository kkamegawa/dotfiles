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
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
  $python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $python) {
  Write-Warning 'PATH に Python がないため、APM プロファイル更新をスキップします。'
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
