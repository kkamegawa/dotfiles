# Windows: run_after_70-setup-claude-mcp.ps1
# Register the user-scope MCP servers that the managed Claude Code permissions refer to by name.
# Runs on every chezmoi apply and is idempotent: servers that already exist are left untouched.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Warning 'Skipping Claude Code MCP setup because claude was not found in PATH.'
  exit 0
}

function Add-ClaudeHttpMcpServer {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)] [string] $Name,
    [Parameter(Mandatory = $true)] [string] $Url
  )

  & claude mcp get $Name *> $null
  if ($LASTEXITCODE -eq 0) {
    return
  }

  if ($PSCmdlet.ShouldProcess($Name, 'Register Claude Code MCP server')) {
    Write-Output "==> Registering Claude Code MCP server: $Name"
    & claude mcp add --scope user --transport http $Name $Url
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Failed to register Claude Code MCP server: $Name"
    }
  }
}

# The tool name mcp__microsoft-learn__* in permissions.allow depends on this server name.
Add-ClaudeHttpMcpServer -Name 'microsoft-learn' -Url 'https://learn.microsoft.com/api/mcp'
