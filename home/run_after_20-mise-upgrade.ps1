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
  foreach ($toolName in $managedTools) {
    $installed = dotnet tool list -g 2>$null | Select-String -Pattern "^$([regex]::Escape($toolName))\s" -SimpleMatch:$false
    if ($installed) {
      Write-Output "==> Updating dotnet global tool: $toolName"
      if ($PSCmdlet.ShouldProcess($toolName, 'Update dotnet global tool')) {
        dotnet tool update --global $toolName
      }
    }
    else {
      Write-Output "==> Installing dotnet global tool: $toolName"
      if ($PSCmdlet.ShouldProcess($toolName, 'Install dotnet global tool')) {
        dotnet tool install --global $toolName
      }
    }
  }
}

Update-DotnetGlobalToolSet

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
  Write-Warning 'Skipping mise upgrade because this host is not Windows.'
  exit 0
}

if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
  Write-Warning 'Skipping mise upgrade because mise was not found in PATH.'
  exit 0
}

Write-Output '==> Running mise install...'
mise install

Write-Output '==> Running mise upgrade...'
mise upgrade

Write-Output '==> mise install/upgrade complete'
