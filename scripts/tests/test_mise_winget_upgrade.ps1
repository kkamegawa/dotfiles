# Exercise the Windows update hook without installing or upgrading applications.
param([switch]$RunFinalFailureHook)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$upgradeScript = Join-Path $PSScriptRoot '../../home/run_after_20-mise-upgrade.ps1'
$testCount = 0

function Assert-Condition {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

function Get-TestPackage {
  param(
    [string]$Name,
    [string]$State = 'installed',
    [string]$Version = 'latest',
    [string]$DesiredState = 'present'
  )
  @{
    package = $Name
    state = $State
    requested_version = $Version
    desired_state = $DesiredState
    installed_version = '1.0'
  }
}

function Invoke-UpgradeScenario {
  param(
    [string]$StatusJson,
    [int]$StatusExitCode = 0,
    [int]$SourceExitCode = 0,
    [hashtable]$UpgradeExitCodes = @{},
    [hashtable]$UpgradeExceptions = @{},
    [string]$FailMiseCommand = '',
    [switch]$RunHookDirectly
  )

  $calls = [System.Collections.Generic.List[object]]::new()
  $scenario = @{
    StatusJson = $StatusJson
    StatusExitCode = $StatusExitCode
    SourceExitCode = $SourceExitCode
    UpgradeExitCodes = $UpgradeExitCodes
    UpgradeExceptions = $UpgradeExceptions
    FailMiseCommand = $FailMiseCommand
  }

  # Function stubs take precedence over native executables, including Get-Command.
  function mise {
    $command = $args -join ' '
    $calls.Add(@{ Tool = 'mise'; Arguments = @($args) })
    $global:LASTEXITCODE = 0
    if ($command -eq 'bootstrap packages status --json') {
      $global:LASTEXITCODE = $scenario.StatusExitCode
      $scenario.StatusJson
    }
    elseif ($command -eq $scenario.FailMiseCommand) {
      $global:LASTEXITCODE = 19
    }
  }

  function winget {
    $calls.Add(@{ Tool = 'winget'; Arguments = @($args) })
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'source') {
      $global:LASTEXITCODE = $scenario.SourceExitCode
    }
    elseif ($scenario.UpgradeExceptions.ContainsKey($args[2])) {
      throw $scenario.UpgradeExceptions[$args[2]]
    }
    elseif ($scenario.UpgradeExitCodes.ContainsKey($args[2])) {
      $global:LASTEXITCODE = $scenario.UpgradeExitCodes[$args[2]]
    }
  }

  function dotnet {
    $global:LASTEXITCODE = 0
  }

  if ($RunHookDirectly) {
    & $upgradeScript
    return
  }

  $failure = $null
  $output = @()
  try {
    $output = @(& $upgradeScript 3>&1)
  }
  catch {
    $failure = $_.Exception.Message
  }

  [pscustomobject]@{
    Calls = $calls.ToArray()
    Failure = $failure
    Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    Output = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
    ExitCode = $LASTEXITCODE
  }
}

if ($RunFinalFailureHook) {
  $finalFailureStatus = @{
    winget = @{ available = $true; packages = @((Get-TestPackage 'OpenAI.Codex')) }
  } | ConvertTo-Json -Depth 8
  Invoke-UpgradeScenario -StatusJson $finalFailureStatus -UpgradeExitCodes @{ 'OpenAI.Codex' = -2147020496 } -RunHookDirectly
  exit $LASTEXITCODE
}

$packages = @(
  (Get-TestPackage 'Example.Latest'),
  (Get-TestPackage 'Example.Missing' -State 'missing'),
  (Get-TestPackage 'Example.Pinned' -State 'version_mismatch' -Version '2.41.1'),
  (Get-TestPackage 'Example.Skipped' -State 'skipped'),
  (Get-TestPackage 'Example.Absent' -State 'unexpectedly_installed' -DesiredState 'absent')
)
$status = @{
  winget = @{ available = $true; packages = $packages }
  scoop = @{ available = $false; reason = 'unavailable'; packages = @() }
} | ConvertTo-Json -Depth 8

$result = Invoke-UpgradeScenario -StatusJson $status
Assert-Condition ($null -eq $result.Failure) "Successful upgrade failed: $($result.Failure)"
Assert-Condition ($result.Warnings.Count -eq 0) 'Successful upgrades must not emit failure warnings.'
Assert-Condition ($result.ExitCode -eq 0) 'Successful upgrades must leave a zero exit code.'
$miseCalls = @($result.Calls | Where-Object { $_.Tool -eq 'mise' })
Assert-Condition (($miseCalls | ForEach-Object { $_.Arguments -join ' ' }) -join '|' -eq
  'install|upgrade|bootstrap packages apply --yes|bootstrap packages status --json') 'The existing mise sequence changed.'
$wingetCalls = @($result.Calls | Where-Object { $_.Tool -eq 'winget' })
Assert-Condition ($wingetCalls.Count -eq 3) 'Expected one refresh and two upgrades of configured, installed packages.'
Assert-Condition (($wingetCalls[0].Arguments -join ' ') -eq
  'source update --disable-interactivity') 'Sources must refresh once before upgrades.'
Assert-Condition (($wingetCalls[1].Arguments -join ' ') -eq
  'upgrade --id Example.Latest --exact --force --silent --accept-source-agreements --accept-package-agreements --disable-interactivity') 'Latest upgrade arguments are incorrect.'
Assert-Condition (($wingetCalls[2].Arguments -join ' ') -eq
  'upgrade --id Example.Pinned --exact --force --version 2.41.1 --silent --accept-source-agreements --accept-package-agreements --disable-interactivity') 'Pinned upgrade arguments are incorrect.'
$testCount++

$result = Invoke-UpgradeScenario -StatusJson $status -UpgradeExitCodes @{ 'Example.Latest' = -1978335189 }
Assert-Condition ($null -eq $result.Failure) 'No applicable upgrade must succeed.'
Assert-Condition ($result.Warnings.Count -eq 0) 'No applicable upgrade must not emit failure warnings.'
Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' -and $_.Arguments[0] -eq 'upgrade' }).Count -eq 2) 'No-op must not skip later packages.'
$testCount++

foreach ($exitCode in @(-1978335145, -2147020496)) {
  $result = Invoke-UpgradeScenario -StatusJson $status -UpgradeExitCodes @{ 'Example.Latest' = $exitCode }
  Assert-Condition ($null -eq $result.Failure) 'Individual upgrade failures must not stop the hook.'
  Assert-Condition ($result.Warnings.Count -eq 2) 'Expected an immediate warning and a final failure summary.'
  Assert-Condition ($result.Warnings[0] -like "*Example.Latest*0x$($exitCode.ToString('X8'))*") 'Failure warnings must include the package and HRESULT.'
  Assert-Condition ($result.Warnings[-1] -like '*1 failure(s):*Example.Latest*') 'The summary must include the failed package.'
  Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' -and $_.Arguments[0] -eq 'upgrade' }).Count -eq 2) 'Installer failure must not skip later packages.'
  Assert-Condition ($result.Output[-1] -eq '==> mise install/upgrade complete') 'The hook must reach its final completion message.'
  Assert-Condition ($result.ExitCode -eq 0) 'Tolerated upgrade failures must leave a zero exit code.'
  $testCount++
}

$result = Invoke-UpgradeScenario -StatusJson $status -UpgradeExitCodes @{ 'Example.Pinned' = -2147020496 }
Assert-Condition ($null -eq $result.Failure) 'Failure of the final package must not stop the hook.'
Assert-Condition ($result.Warnings[-1] -like '*1 failure(s):*Example.Pinned*0x80071130*') 'The final failure summary must include the final package and HRESULT.'
Assert-Condition ($result.ExitCode -eq 0) 'A final-package failure must leave a zero exit code.'
$testCount++

$result = Invoke-UpgradeScenario -StatusJson $status -UpgradeExitCodes @{ 'Example.Latest' = -2147020496; 'Example.Pinned' = -1978335145 }
Assert-Condition ($null -eq $result.Failure) 'Multiple upgrade failures must not stop the hook.'
Assert-Condition ($result.Warnings.Count -eq 3) 'Expected both immediate warnings and one summary.'
Assert-Condition ($result.Warnings[-1] -like '*2 failure(s):*Example.Latest*0x80071130*Example.Pinned*0x8A150057*') 'The summary must list every failed package and HRESULT.'
Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' -and $_.Arguments[0] -eq 'upgrade' }).Count -eq 2) 'Every package must be attempted despite multiple failures.'
Assert-Condition ($result.ExitCode -eq 0) 'Multiple failures must leave a zero exit code.'
$testCount++

$result = Invoke-UpgradeScenario -StatusJson $status -UpgradeExceptions @{ 'Example.Latest' = 'Simulated invocation failure' }
Assert-Condition ($null -eq $result.Failure) 'Invocation exceptions must not stop the hook.'
Assert-Condition ($result.Warnings[0] -like '*Example.Latest*Simulated invocation failure*') 'Invocation warnings must include the package and exception.'
Assert-Condition ($result.Warnings[-1] -like '*1 failure(s):*Example.Latest*Simulated invocation failure*') 'The summary must include invocation failures.'
Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' -and $_.Arguments[0] -eq 'upgrade' }).Count -eq 2) 'Invocation exceptions must not skip later packages.'
Assert-Condition ($result.ExitCode -eq 0) 'Invocation failures must leave a zero exit code.'
$testCount++

$enginePath = (Get-Process -Id $PID).Path
$childOutput = @(& $enginePath -NoLogo -NoProfile -File $PSCommandPath -RunFinalFailureHook 2>&1)
Assert-Condition ($LASTEXITCODE -eq 0) 'The hook process must succeed after a final-package failure so chezmoi can continue.'
Assert-Condition (($childOutput -join [Environment]::NewLine) -like '*OpenAI.Codex*0x80071130*1 failure(s):*mise install/upgrade complete*') 'The child process must report the Codex failure summary and reach completion.'
$testCount++

$result = Invoke-UpgradeScenario -StatusJson $status -SourceExitCode 42
Assert-Condition ($result.Failure -like '*source update*42*') 'Source refresh failure must propagate.'
Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' }).Count -eq 1) 'Failed refresh must not run upgrades.'
$testCount++

$result = Invoke-UpgradeScenario -StatusJson $status -StatusExitCode 23
Assert-Condition ($result.Failure -like '*packages status*23*') 'Status command failure must propagate.'
Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' }).Count -eq 0) 'Failed status must not change WinGet state.'
$testCount++

foreach ($invalidJson in @('invalid JSON', '', 'null')) {
  $result = Invoke-UpgradeScenario -StatusJson $invalidJson
  Assert-Condition ($null -ne $result.Failure) 'Invalid or empty status must fail.'
  Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' }).Count -eq 0) 'Invalid status must not change WinGet state.'
  $testCount++
}

foreach ($emptyStatus in @(
    '{}',
    '{"winget":{"available":true,"packages":[]}}',
    (@{ winget = @{ available = $true; packages = @((Get-TestPackage 'Example.Missing' -State 'missing')) } } | ConvertTo-Json -Depth 8)
  )) {
  $result = Invoke-UpgradeScenario -StatusJson $emptyStatus
  Assert-Condition ($null -eq $result.Failure) "Empty upgrade set must succeed: $($result.Failure)"
  Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' }).Count -eq 0) 'An empty upgrade set must not refresh sources or run upgrades.'
  $testCount++
}

$result = Invoke-UpgradeScenario -StatusJson '{"winget":{"available":false,"reason":"winget not found","packages":[]}}'
Assert-Condition ($result.Failure -like '*unavailable*winget not found*') 'Unavailable manager must report its reason.'
Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' }).Count -eq 0) 'Unavailable manager must not run WinGet.'
$testCount++

foreach ($command in @('install', 'upgrade', 'bootstrap packages apply --yes')) {
  $result = Invoke-UpgradeScenario -StatusJson $status -FailMiseCommand $command
  Assert-Condition ($result.Failure -like '*failed with exit code 19*') "mise $command failure must propagate."
  Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' }).Count -eq 0) "mise $command failure must prevent WinGet upgrades."
  $testCount++
}

Write-Output "Passed $testCount Windows update-hook scenarios; all application commands were mocked."
