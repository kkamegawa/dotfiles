#Requires -Version 7.0
# PreToolUse syntax guard, not a shell parser. Never execute the payload.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
    $payload = $reader.ReadToEnd()
    # Reject comments/trailing commas too, consistently with the Unix entrypoint.
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

    # Keywords must follow a command boundary, not arbitrary argument text.
    # Quotes/escapes are not parsed: quoted separators can also trigger a match.
    $directoryChange = '(?:^|[;&|()\r\n{}`])[ \t]*(?:(?:if|then|elif|else|while|until|do|!)[ \t]+)*(?:cd|pushd|popd|chdir|sl|Set-Location|Push-Location|Pop-Location)(?=$|[\s;&|(){}<>`])'
    if ($data.tool_input.command -match $directoryChange) {
        [Console]::Error.WriteLine('Blocked: directory changes are not allowed. Use direct absolute paths instead (git -C C:/absolute/repo status; python3 C:/absolute/path/script.py), without cd or location cmdlets/aliases.')
        exit 2
    }
} catch {
    [Console]::Error.WriteLine('Blocked: directory guard expects a JSON object with tool_name and a string tool_input.command for Bash or PowerShell. Fix the hook payload and retry.')
    exit 2
}
exit 0
