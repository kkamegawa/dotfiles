#Requires -Version 7.0
# PreToolUse syntax guard. The payload is data and is never executed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $payload = [Console]::In.ReadToEnd()
    # ConvertFrom-Json also accepts comments and trailing commas. Require strict
    # JSON first so malformed input has the same blocking behavior as Unix.
    $jsonDocument = [System.Text.Json.JsonDocument]::Parse($payload)
    $jsonDocument.Dispose()
    $data = $payload | ConvertFrom-Json -AsHashtable
    if ($data -isnot [System.Collections.IDictionary] -or
        $data.tool_name -isnot [string] -or
        [string]::IsNullOrWhiteSpace($data.tool_name)) {
        throw 'Invalid tool payload'
    }
    if ($data.tool_name -cnotin @('Bash', 'PowerShell', 'powershell')) {
        exit 0
    }
    if ($data.tool_input -isnot [System.Collections.IDictionary] -or
        $data.tool_input.command -isnot [string]) {
        throw 'Invalid command field'
    }

    # Recognize shell assignments too: Bash may carry either syntax on Windows.
    $shellAssignment = '^\s*[A-Za-z_][A-Za-z0-9_]*(?:\+)?='
    # Simple, scoped and braced PowerShell variables; not comparison operators.
    $name = '[\p{L}_][\p{L}\p{N}_]*(?::[\p{L}_][\p{L}\p{N}_]*)?'
    $powershellAssignment = '^\s*\$(?:' + $name + '|\{' + $name + '\})\s*(?:=(?!=)|[+\-*/%]=|\?\?=)'
    if ($data.tool_input.command -match $shellAssignment -or
        $data.tool_input.command -match $powershellAssignment) {
        [Console]::Error.WriteLine('Blocked: leading variable assignments are not allowed. Rewrite the command using direct absolute paths instead of assigning a path to a variable.')
        exit 2
    }
} catch {
    [Console]::Error.WriteLine('Blocked: assignment guard expects a JSON object with tool_name and a string tool_input.command for Bash or PowerShell. Fix the hook payload and retry.')
    exit 2
}
exit 0
