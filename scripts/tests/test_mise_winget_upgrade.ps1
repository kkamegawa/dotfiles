# Exercise the Windows update hook without installing or upgrading applications.
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
    [string]$FailMiseCommand = ''
  )

  $calls = [System.Collections.Generic.List[object]]::new()
  $scenario = @{
    StatusJson = $StatusJson
    StatusExitCode = $StatusExitCode
    SourceExitCode = $SourceExitCode
    UpgradeExitCodes = $UpgradeExitCodes
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
    elseif ($scenario.UpgradeExitCodes.ContainsKey($args[2])) {
      $global:LASTEXITCODE = $scenario.UpgradeExitCodes[$args[2]]
    }
  }

  function dotnet {
    $global:LASTEXITCODE = 0
  }

  $failure = $null
  try {
    & $upgradeScript | Out-Null
  }
  catch {
    $failure = $_.Exception.Message
  }

  [pscustomobject]@{ Calls = $calls.ToArray(); Failure = $failure }
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
Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' -and $_.Arguments[0] -eq 'upgrade' }).Count -eq 2) 'No-op must not skip later packages.'
$testCount++

$result = Invoke-UpgradeScenario -StatusJson $status -UpgradeExitCodes @{ 'Example.Latest' = -1978335145 }
Assert-Condition ($result.Failure -like "*Example.Latest*0x8A150057*") 'Installer failures must include the package and HRESULT.'
Assert-Condition (@($result.Calls | Where-Object { $_.Tool -eq 'winget' -and $_.Arguments[0] -eq 'upgrade' }).Count -eq 1) 'Installer failure must stop further upgrades.'
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
