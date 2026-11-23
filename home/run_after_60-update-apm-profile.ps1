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

# 候補の --version をタイムアウト付きで実行する。標準入力は即座に閉じる。
# Store スタブや mise shim は、入力待ちや Store 起動待ちで無期限にブロックすることがあるため、
# 通常の呼び出し (& ...) ではなく、期限を超えたらプロセスツリーごと終了させる。
function Test-PythonCandidate {
  param(
    [Parameter(Mandatory = $true)] [string] $Path,
    [Parameter(Mandatory = $true)] [string[]] $Arguments,
    [int] $TimeoutSeconds = 15
  )

  # Windows PowerShell 5.1 (.NET Framework) でも動くよう、ArgumentList は使わず Arguments 文字列を組み立てる。
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $Path
  $startInfo.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = $null
  try {
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $process.StandardInput.Close()
    # ReadToEnd は孫プロセスがパイプを握っていると EOF が来ず戻らないため、1 行だけ読む。
    $stdoutTask = $process.StandardOutput.ReadLineAsync()
    $stderrTask = $process.StandardError.ReadLineAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      & taskkill.exe /PID $process.Id /T /F *> $null
      Write-Warning "Python 候補 '$Path' が $TimeoutSeconds 秒以内に応答しなかったため、次の候補へ進みます。"
      return $false
    }
    $output = ''
    foreach ($task in @($stdoutTask, $stderrTask)) {
      if ($task.Wait(5000) -and $task.Result) { $output += $task.Result + "`n" }
    }
    return ($process.ExitCode -eq 0 -and $output -match '^\s*Python\s+\d+\.\d+')
  } catch {
    return $false
  } finally {
    if ($process) { $process.Dispose() }
  }
}

foreach ($group in $candidates) {
  foreach ($cmd in $group) {
    # WindowsApps には動作する Store 版 Python や py.exe のエイリアスもあるため、パスでは除外せず、
    # 起動して "Python X.Y" が返るかで判定する。起動失敗やタイムアウトした候補は次へ進む。
    $versionArgs = if ($cmd.Name -in 'py.exe', 'py') { @('-3', '--version') } else { @('--version') }
    if (Test-PythonCandidate -Path $cmd.Source -Arguments $versionArgs) { $python = $cmd; break }
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
