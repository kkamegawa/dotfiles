# Windows: run_once_after_60-setup-apm-profile.ps1
# Prepare user-profile directories for APM-managed skills and agents.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $isWindowsHost) {
  Write-Warning 'Skipping APM profile setup because this host is not Windows.'
  exit 0
}

if (-not $env:XDG_CONFIG_HOME -or [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
  $env:XDG_CONFIG_HOME = "$HOME/.config"
}

if (-not $env:APM_PROFILE_HOME -or [string]::IsNullOrWhiteSpace($env:APM_PROFILE_HOME)) {
  $env:APM_PROFILE_HOME = "$($env:XDG_CONFIG_HOME)/apm"
}

if (-not $env:APM_AGENTS_DIR -or [string]::IsNullOrWhiteSpace($env:APM_AGENTS_DIR)) {
  $env:APM_AGENTS_DIR = "$($env:APM_PROFILE_HOME)/agents"
}

if (-not $env:APM_SKILLS_DIR -or [string]::IsNullOrWhiteSpace($env:APM_SKILLS_DIR)) {
  $env:APM_SKILLS_DIR = "$($env:APM_PROFILE_HOME)/skills"
}

$directories = @(
  $env:APM_PROFILE_HOME,
  $env:APM_AGENTS_DIR,
  $env:APM_SKILLS_DIR,
  "$HOME/.github",
  "$HOME/.copilot"
)

foreach ($path in $directories) {
  if (-not (Test-Path -LiteralPath $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

function Ensure-DirectoryLink {
  param(
    [Parameter(Mandatory = $true)] [string] $Target,
    [Parameter(Mandatory = $true)] [string] $LinkPath
  )

  if (Test-Path -LiteralPath $LinkPath) {
    $item = Get-Item -LiteralPath $LinkPath -Force

    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      try {
        $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $LinkPath) $item.Target))
        $expected = [IO.Path]::GetFullPath($Target)
        if ($resolved -eq $expected) {
          return
        }
      } catch {
        # If target resolution fails, recreate link below.
      }

      Remove-Item -LiteralPath $LinkPath -Force
    } elseif ($item.PSIsContainer) {
      $children = Get-ChildItem -LiteralPath $LinkPath -Force
      if ($children.Count -gt 0) {
        Write-Warning "Skip linking $LinkPath because the directory is not empty"
        return
      }

      Remove-Item -LiteralPath $LinkPath -Force
    } else {
      Write-Warning "Skip linking $LinkPath because it is not a directory"
      return
    }
  }

  try {
    New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -Force | Out-Null
  } catch {
    New-Item -ItemType Junction -Path $LinkPath -Target $Target -Force | Out-Null
  }

  Write-Output "==> Linked $LinkPath -> $Target"
}

Ensure-DirectoryLink -Target $env:APM_AGENTS_DIR -LinkPath "$HOME/.github/agents"
Ensure-DirectoryLink -Target $env:APM_SKILLS_DIR -LinkPath "$HOME/.copilot/skills"
