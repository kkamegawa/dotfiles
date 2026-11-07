#Requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateSet('codex', 'copilot')][string]$Client,
    [Parameter(Mandatory)][ValidateSet('PreToolUse', 'PostToolUse', 'PostCompact', 'UserPromptSubmit')][string]$Event
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $payload = [Console]::In.ReadToEnd()
    # Piping strings adds a newline but preserves the JSON document.
    $payload | & node (Join-Path $PSScriptRoot 'adapter.mjs') $Client $Event windows
    if ($LASTEXITCODE -ne 0) {
        if ($Event -eq 'PreToolUse') { exit 2 }
        exit 1
    }
} catch {
    [Console]::Error.WriteLine("Hook adapter failed: $($_.Exception.Message)")
    if ($Event -eq 'PreToolUse') { exit 2 }
    exit 1
}
