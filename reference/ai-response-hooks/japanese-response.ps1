#Requires -Version 7.0
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '',
    Justification = 'PowerShell 7 reads UTF-8 without BOM; this hook intentionally uses BOMless UTF-8.')]
param(
    [Parameter(Mandatory)][ValidateSet('claude', 'codex', 'copilot')][string]$Client
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

try {
    try {
        $payload = ConvertFrom-Json -AsHashtable -InputObject ([Console]::In.ReadToEnd())
    } catch { throw 'cannot parse stdin JSON.' }
    if ($payload -isnot [System.Collections.IDictionary] -or
        $payload['stop_hook_active'] -isnot [bool] -or
        ($payload.Contains('hook_event_name') -and $payload['hook_event_name'] -cne 'Stop')) {
        throw 'expected one Stop JSON object with boolean stop_hook_active.'
    }
    if ($payload['stop_hook_active']) { exit 0 }

    $text = $null
    if ($Client -eq 'copilot') {
        $path = $payload['transcriptPath']
        if ($null -eq $path) { $path = $payload['transcript_path'] }
        if ($path -isnot [string] -or $path.Length -eq 0) {
            throw 'Copilot requires transcriptPath or transcript_path.'
        }
        try {
            # Read a snapshot; no writes to the transcript or persistent state.
            $lines = [System.IO.File]::ReadAllLines($path, [System.Text.UTF8Encoding]::new($false, $true))
        } catch { throw 'Copilot transcript is not a readable UTF-8 file.' }
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $sessionEvent = ConvertFrom-Json -AsHashtable -InputObject $line }
            catch { throw 'cannot parse Copilot transcript JSONL.' }
            if ($sessionEvent -isnot [System.Collections.IDictionary]) { throw 'invalid Copilot event.' }
            $data = $sessionEvent['data']
            if ($null -ne $sessionEvent['agentId'] -or $sessionEvent['checkpoint'] -eq $true -or
                ($data -is [System.Collections.IDictionary] -and $null -ne $data['parentToolCallId'])) {
                continue
            }
            if ($sessionEvent['type'] -cin @('user.message', 'assistant.turn_start')) {
                $text = $null
            } elseif ($sessionEvent['type'] -ceq 'assistant.message') {
                $text = $null
                if ($data -is [System.Collections.IDictionary] -and $data['content'] -is [string] -and
                    @($data['toolRequests']).Where({ $null -ne $_ }).Count -eq 0 -and
                    ($null -eq $data['phase'] -or $data['phase'] -cin @('final', 'final_answer'))) {
                    $text = $data['content']
                }
            }
        }
    } else {
        $text = $payload['last_assistant_message']
        if ($null -ne $text -and $text -isnot [string]) {
            throw 'last_assistant_message must be a string or null.'
        }
    }
    if ([string]::IsNullOrEmpty($text)) {
        [Console]::Error.WriteLine('Japanese response hook: final assistant text unavailable; check the client version/transcript format.')
        exit 0
    }

    $fence = $null
    $width = 0
    $prose = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [regex]::Split($text, '\r?\n')) {
        if ($null -ne $fence) {
            if ($line -match ('^ {0,3}' + [regex]::Escape($fence) + '{' + $width + ',}[ \t]*$')) {
                $fence = $null
            }
        } elseif ($line -match '^ {0,3}(`{3,}|~{3,})') {
            $fence = $Matches[1].Substring(0, 1)
            $width = $Matches[1].Length
        } else { $prose.Add($line) }
    }
    $text = [regex]::Replace(($prose -join "`n"), '(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)', '',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $letters = 0
    $japanese = 0
    # Enumerate Unicode scalars so supplementary Han is not split into surrogates.
    foreach ($rune in $text.EnumerateRunes()) {
        $category = [System.Text.Rune]::GetUnicodeCategory($rune)
        if ($category -notin @(
            [System.Globalization.UnicodeCategory]::UppercaseLetter,
            [System.Globalization.UnicodeCategory]::LowercaseLetter,
            [System.Globalization.UnicodeCategory]::TitlecaseLetter,
            [System.Globalization.UnicodeCategory]::ModifierLetter,
            [System.Globalization.UnicodeCategory]::OtherLetter
        )) { continue }
        $letters++
        $c = $rune.Value
        if (($c -ge 0x3040 -and $c -le 0x309F) -or ($c -ge 0x30A0 -and $c -le 0x30FF) -or
            ($c -ge 0x31F0 -and $c -le 0x31FF) -or ($c -ge 0x3400 -and $c -le 0x4DBF) -or
            ($c -ge 0x4E00 -and $c -le 0x9FFF) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFF66 -and $c -le 0xFF9D) -or ($c -ge 0x20000 -and $c -le 0x2FA1F) -or
            ($c -ge 0x30000 -and $c -le 0x323AF)) { $japanese++ }
    }
    if ($letters -ge 30 -and $japanese * 5 -lt $letters) {
        @{
            decision = 'block'
            reason = '最終応答の説明文を日本語で書き直してください。コード・コマンド・パス・識別子は変更せず、作業やツール実行を繰り返さずに回答だけを修正してください。'
        } | ConvertTo-Json -Compress
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("Japanese response hook: $($_.Exception.Message)")
    exit 1
}
