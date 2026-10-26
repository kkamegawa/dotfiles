# Windows: run_after_20-mise-upgrade.ps1
# Keep mise-managed tools up to date on every chezmoi apply/update.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Update-DotnetGlobalToolSet {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Warning 'Skipping dotnet global tool update because dotnet was not found in PATH.'
    return
  }

  $managedTools = @(
    'dotnet-ef',
    'csharpier',
    'docfx',
    'dotnet-counters',
    'git-credential-manager',
    'ilspycmd',
    'microsoft.dotnet-scaffold',
    'microsoft.dataapibuilder',
    'microsoft.openapi.kiota',
    'microsoft.sqlpackage',
    'microsoft.web.librarymanager.cli',
    'nbgv',
    'microsoft.playwright.cli',
    'terminalguidesigner',
    'upgrade-assistant',
    'dotnet-outdated-tool'
  )

  Write-Output '==> Ensuring managed dotnet global tools...'
  Push-Location ([System.IO.Path]::GetTempPath())
  try {
    foreach ($toolName in $managedTools) {
      $installed = dotnet tool list --global 2>$null | Select-String -Pattern "^$([regex]::Escape($toolName))\s" -SimpleMatch:$false
      if ($installed) {
        if ($PSCmdlet.ShouldProcess($toolName, 'Update dotnet global tool')) {
          Write-Output "==> Updating dotnet global tool: $toolName"
          dotnet tool update --global $toolName
        }
      }
      else {
        if ($PSCmdlet.ShouldProcess($toolName, 'Install dotnet global tool')) {
          Write-Output "==> Installing dotnet global tool: $toolName"
          dotnet tool install --global $toolName
        }
      }
    }
  }
  finally {
    Pop-Location
  }
}

function Update-MiseWingetPackageSet {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  # WinGet uses a nonzero exit code when no upgrade applies.
  # Inspect native exit codes here even if the caller enables native error handling.
  $PSNativeCommandUseErrorActionPreference = $false
  $statusJson = mise bootstrap packages status --json
  if ($LASTEXITCODE -ne 0) {
    throw "mise bootstrap packages status failed with exit code $LASTEXITCODE."
  }

  $packageStatus = ($statusJson -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $packageStatus) {
    throw 'mise bootstrap packages status returned no package status.'
  }

  $wingetProperty = $packageStatus.PSObject.Properties['winget']
  if ($null -eq $wingetProperty) {
    Write-Output '==> No mise-managed winget packages configured.'
    return
  }

  $manager = $wingetProperty.Value
  if (-not $manager.available) {
    throw "mise winget package manager is unavailable: $($manager.reason)"
  }

  $packages = @($manager.packages | Where-Object {
      $_.desired_state -eq 'present' -and
      $_.state -in @('installed', 'version_mismatch', 'needs_repair')
    })
  if ($packages.Count -eq 0) {
    Write-Output '==> No installed mise-managed winget packages to upgrade.'
    return
  }

  if ($PSCmdlet.ShouldProcess('WinGet sources', 'Refresh')) {
    winget source update --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
      throw "winget source update failed with exit code $LASTEXITCODE."
    }
  }

  $failures = [System.Collections.Generic.List[string]]::new()
  foreach ($package in $packages) {
    $wingetArgs = @('upgrade', '--id', $package.package, '--exact', '--force')
    if ($package.requested_version -ne 'latest') {
      $wingetArgs += @('--version', $package.requested_version)
    }
    $wingetArgs += @(
      '--silent',
      '--accept-source-agreements',
      '--accept-package-agreements',
      '--disable-interactivity'
    )

    if ($PSCmdlet.ShouldProcess($package.package, 'Upgrade WinGet package with --force')) {
      Write-Output "==> Upgrading mise-managed winget package with --force: $($package.package)"
      try {
        winget @wingetArgs
        $upgradeExitCode = $LASTEXITCODE
        # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (0x8A15002B).
        if ($upgradeExitCode -notin @(0, -1978335189)) {
          $message = "winget upgrade '$($package.package)' failed with exit code 0x$($upgradeExitCode.ToString('X8'))."
          $failures.Add($message)
          Write-Warning $message
        }
      }
      catch {
        $message = "winget upgrade '$($package.package)' failed: $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
      }
    }
  }

  if ($failures.Count -gt 0) {
    Write-Warning ("WinGet upgrades completed with {0} failure(s):{1}{2}" -f
      $failures.Count, [Environment]::NewLine, ($failures -join [Environment]::NewLine))
  }
}

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
  Write-Warning 'Skipping the Windows-owned mise upgrade hook on this host.'
  exit 0
}

# This hook owns package and global-tool updates only on Windows.

if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
  Write-Warning 'Skipping mise upgrade because mise was not found in PATH.'
  exit 0
}

Write-Output '==> Running mise install...'
mise install
if ($LASTEXITCODE -ne 0) {
  throw "mise install failed with exit code $LASTEXITCODE."
}

Write-Output '==> Running mise upgrade...'
mise upgrade
if ($LASTEXITCODE -ne 0) {
  throw "mise upgrade failed with exit code $LASTEXITCODE."
}

Update-DotnetGlobalToolSet

Write-Output '==> Applying mise bootstrap packages...'
mise bootstrap packages apply --yes
if ($LASTEXITCODE -ne 0) {
  throw "mise bootstrap packages apply failed with exit code $LASTEXITCODE."
}

Write-Output '==> Upgrading mise-managed winget packages...'
Update-MiseWingetPackageSet

Write-Output '==> mise install/upgrade complete'
# Individual WinGet upgrade failures are warnings and must not stop chezmoi.
exit 0
