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

# プロセスをタイムアウト付きで実行する。標準入力は即座に閉じる。
# Store スタブや mise shim は、入力待ちや Store 起動待ちで無期限にブロックすることがあり、
# shim は起動時間も 0.5〜10 秒以上とばらつくため、通常の呼び出し (& ...) ではなく、
# 期限を超えたらプロセスツリーごと終了させる。
function Invoke-BoundedProcess {
  param(
    [Parameter(Mandatory = $true)] [string] $Path,
    [Parameter(Mandatory = $true)] [string[]] $Arguments,
    [int] $TimeoutSeconds = 60
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
      Write-Warning "'$Path' が $TimeoutSeconds 秒以内に応答しなかったため、打ち切ります。"
      return [pscustomobject]@{ TimedOut = $true; ExitCode = -1; Output = '' }
    }
    $output = ''
    foreach ($task in @($stdoutTask, $stderrTask)) {
      if ($task.Wait(5000) -and $task.Result) { $output += $task.Result + "`n" }
    }
    return [pscustomobject]@{ TimedOut = $false; ExitCode = $process.ExitCode; Output = $output }
  } catch {
    return [pscustomobject]@{ TimedOut = $false; ExitCode = -1; Output = '' }
  } finally {
    if ($process) { $process.Dispose() }
  }
}

function Test-PythonCandidate {
  param([Parameter(Mandatory = $true)] $Candidate)

  # WindowsApps には動作する Store 版 Python や py.exe のエイリアスもあるため、パスでは除外せず、
  # 起動して "Python X.Y" が返るかで判定する。起動失敗やタイムアウトした候補は次へ進む。
  $versionArgs = if ($Candidate.Name -in 'py.exe', 'py') { @('-3', '--version') } else { @('--version') }
  $result = Invoke-BoundedProcess -Path $Candidate.Source -Arguments $versionArgs
  return ((-not $result.TimedOut) -and $result.ExitCode -eq 0 -and $result.Output -match '^\s*Python\s+\d+\.\d+')
}

# 候補の順序: mise が解決した実体 (shim を経由しない) → PATH 上の python → mise shim → py。
$candidates = [System.Collections.Generic.List[object]]::new()
if (Get-Command mise -ErrorAction SilentlyContinue) {
  $miseWhich = Invoke-BoundedProcess -Path (Get-Command mise -CommandType Application | Select-Object -First 1).Source -Arguments @('which', 'python')
  $miseRealPython = ($miseWhich.Output -split "`n" | Select-Object -First 1)
  if (-not $miseWhich.TimedOut -and $miseWhich.ExitCode -eq 0 -and $miseRealPython -and (Test-Path -LiteralPath $miseRealPython.Trim() -PathType Leaf)) {
    $candidates.Add([pscustomobject]@{ Name = 'python.exe'; Source = $miseRealPython.Trim() })
  }
}
$miseShimPython = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' }) 'mise/shims/python.exe'
foreach ($found in @(
    @(Get-Command python -All -CommandType Application -ErrorAction SilentlyContinue)
    @(Get-Command $miseShimPython -CommandType Application -ErrorAction SilentlyContinue)
    @(Get-Command py -All -CommandType Application -ErrorAction SilentlyContinue)
  )) {
  foreach ($cmd in $found) { $candidates.Add([pscustomobject]@{ Name = $cmd.Name; Source = $cmd.Source }) }
}

# 同じ実体を二重にプローブして待ち時間を増やさないよう、パスで重複を除く。
$probed = @{}
foreach ($cmd in $candidates) {
  $key = $cmd.Source.ToLowerInvariant()
  if ($probed.ContainsKey($key)) { continue }
  $probed[$key] = $true
  if (Test-PythonCandidate -Candidate $cmd) { $python = $cmd; break }
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
