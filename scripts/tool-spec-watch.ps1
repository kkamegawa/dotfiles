[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$FindingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Write-WorkflowOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function Write-StepSummaryLine {
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Line
    }
}

function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($null -eq $ErrorRecord.Exception.Response) {
        return $null
    }

    return [int]$ErrorRecord.Exception.Response.StatusCode
}

function Get-MajorVersion {
    param(
        [AllowNull()]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    $match = [regex]::Match($Version.TrimStart('v', 'V'), '^(\d+)')
    if (-not $match.Success) {
        return $null
    }

    return [int]$match.Groups[1].Value
}

function Get-MatchedKeyword {
    param(
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string[]]$Keywords
    )

    $keywordMatches = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $keywordMatches.ToArray()
    }

    $normalized = $Text.ToLowerInvariant()
    foreach ($keyword in $Keywords) {
        if ([string]::IsNullOrWhiteSpace($keyword)) {
            continue
        }

        if ($normalized.Contains($keyword.ToLowerInvariant())) {
            $keywordMatches.Add($keyword)
        }
    }

    return ($keywordMatches | Select-Object -Unique)
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) {
            return $null
        }

        $property = $current.PSObject.Properties[$segment]
        if ($null -ne $property) {
            $current = $property.Value
            continue
        }

        if ($current -is [System.Collections.IDictionary] -and $current.Contains($segment)) {
            $current = $current[$segment]
            continue
        }

        return $null
    }

    return $current
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        $DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Convert-ToDisplayString {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    return [string]$Value
}

function Get-GitHubJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $headers = @{
        'User-Agent' = 'dotfiles-tool-spec-watch'
        'Accept'     = 'application/vnd.github+json'
    }

    $response = Invoke-WebRequest -Uri $Uri -Headers $headers
    return ($response.Content | ConvertFrom-Json -Depth 100)
}

function Get-GitHubReleaseInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )

    try {
        $latest = Get-GitHubJson -Uri "https://api.github.com/repos/$Repo/releases/latest"
        return [pscustomobject]@{
            Version     = [string]$latest.tag_name
            PublishedAt = [string]$latest.published_at
            Body        = [string]$latest.body
            Url         = [string]$latest.html_url
        }
    } catch {
        if ((Get-HttpStatusCode -ErrorRecord $_) -ne 404) {
            throw
        }

        $releases = @(Get-GitHubJson -Uri "https://api.github.com/repos/$Repo/releases?per_page=1")
        if ($releases.Count -gt 0) {
            $release = $releases[0]
            return [pscustomobject]@{
                Version     = [string]$release.tag_name
                PublishedAt = [string]$release.published_at
                Body        = [string]$release.body
                Url         = [string]$release.html_url
            }
        }

        $tags = @(Get-GitHubJson -Uri "https://api.github.com/repos/$Repo/tags?per_page=1")
        if ($tags.Count -eq 0) {
            throw "No releases or tags found for $Repo."
        }

        return [pscustomobject]@{
            Version     = [string]$tags[0].name
            PublishedAt = ''
            Body        = ''
            Url         = "https://github.com/$Repo/tags"
        }
    }
}

function ConvertTo-Finding {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Tool,

        [Parameter(Mandatory = $true)]
        [string]$Signal,

        [Parameter(Mandatory = $true)]
        [string]$Baseline,

        [Parameter(Mandatory = $true)]
        [string]$Current,

        [Parameter(Mandatory = $true)]
        [string]$UpstreamUrl,

        [Parameter(Mandatory = $true)]
        [string[]]$Reasons
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<!-- tool-spec-watch:$($Tool.id) -->")
    $lines.Add('## 概要')
    $lines.Add('')
    $lines.Add("- 監視対象: $($Tool.displayName)")
    $lines.Add("- 検知種別: $Signal")
    $lines.Add("- 既知の基準: $Baseline")
    $lines.Add("- 現在値: $Current")
    $lines.Add("- 監視元: $UpstreamUrl")
    $lines.Add("- 検知日時 (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add('')
    $lines.Add('## 検知理由')
    $lines.Add('')

    foreach ($reason in $Reasons) {
        $lines.Add("- $reason")
    }

    $lines.Add('')
    $lines.Add('## 影響候補ファイル')
    $lines.Add('')
    foreach ($file in @($Tool.impactFiles)) {
        $lines.Add('- `' + $file + '`')
    }

    $lines.Add('')
    $lines.Add('## 対応手順')
    $lines.Add('')
    $lines.Add('1. 上流のリリースノートまたは仕様ページを確認する。')
    $lines.Add('2. 影響候補ファイルの記述と実装を見直す。')
    $lines.Add('3. 対応が完了したら `reference\ci\tool-spec-watch.json` の基準値を更新する。')

    $toolNotes = Convert-ToDisplayString (Get-OptionalPropertyValue -InputObject $Tool -PropertyName 'notes' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($toolNotes)) {
        $lines.Add('')
        $lines.Add('## メモ')
        $lines.Add('')
        $lines.Add($toolNotes)
    }

    return [pscustomobject]@{
        toolId      = [string]$Tool.id
        displayName = [string]$Tool.displayName
        signal      = $Signal
        baseline    = $Baseline
        current     = $Current
        upstreamUrl = $UpstreamUrl
        issueTitle  = "[tool-spec-watch] $($Tool.displayName)"
        issueBody   = ($lines -join "`n")
    }
}

$absoluteConfigPath = Resolve-AbsolutePath -Path $ConfigPath
$absoluteFindingsPath = Resolve-AbsolutePath -Path $FindingsPath
$findingsDirectory = Split-Path -Parent $absoluteFindingsPath
if (-not (Test-Path $findingsDirectory)) {
    New-Item -ItemType Directory -Force -Path $findingsDirectory | Out-Null
}

$config = Get-Content -Path $absoluteConfigPath -Raw | ConvertFrom-Json -Depth 100
$defaultKeywords = @($config.defaults.keywords)
$findings = [System.Collections.Generic.List[object]]::new()

foreach ($tool in @($config.tools)) {
    switch ([string]$tool.kind) {
        'github-release' {
            $release = Get-GitHubReleaseInfo -Repo ([string]$tool.repo)
            $reasons = [System.Collections.Generic.List[string]]::new()
            $knownVersion = Convert-ToDisplayString (Get-OptionalPropertyValue -InputObject $tool -PropertyName 'knownVersion')
            $currentVersion = Convert-ToDisplayString $release.Version
            $knownMajor = Get-MajorVersion -Version $knownVersion
            $currentMajor = Get-MajorVersion -Version $currentVersion

            if ($null -ne $knownMajor -and $null -ne $currentMajor -and $knownMajor -ne $currentMajor) {
                $reasons.Add("メジャーバージョンが変化しました。($knownVersion -> $currentVersion)")
            }

            $keywords = @($defaultKeywords + @(Get-OptionalPropertyValue -InputObject $tool -PropertyName 'keywords' -DefaultValue @())) | Select-Object -Unique
            $matchedKeywords = @(Get-MatchedKeyword -Text ([string]$release.Body) -Keywords $keywords)
            if ($matchedKeywords.Count -gt 0) {
                $reasons.Add("リリースノートに注目キーワードが含まれています。($($matchedKeywords -join ', '))")
            }

            if ((Get-OptionalPropertyValue -InputObject $tool -PropertyName 'alertOnAnyVersionChange' -DefaultValue $false) -and $knownVersion -ne $currentVersion) {
                $reasons.Add("バージョンが変化しました。($knownVersion -> $currentVersion)")
            }

            if ($reasons.Count -gt 0) {
                $findings.Add((ConvertTo-Finding `
                    -Tool $tool `
                    -Signal 'upstream release change' `
                    -Baseline $knownVersion `
                    -Current $currentVersion `
                    -UpstreamUrl ([string]$release.Url) `
                    -Reasons $reasons.ToArray()))
            }
        }

        'web-page' {
            $response = Invoke-WebRequest -Uri ([string]$tool.url)
            $content = [string]$response.Content
            $reasons = [System.Collections.Generic.List[string]]::new()
            $currentDocumentDate = ''

            $documentDatePattern = [string](Get-OptionalPropertyValue -InputObject $tool -PropertyName 'documentDatePattern' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($documentDatePattern)) {
                $match = [regex]::Match($content, $documentDatePattern)
                if ($match.Success) {
                    $currentDocumentDate = [string]$match.Groups[1].Value
                }
            }

            $knownDocumentDate = Convert-ToDisplayString (Get-OptionalPropertyValue -InputObject $tool -PropertyName 'knownDocumentDate')
            if ($knownDocumentDate -ne $currentDocumentDate) {
                $reasons.Add("ドキュメントの更新日が変化しました。($knownDocumentDate -> $currentDocumentDate)")
            }

            if ($reasons.Count -gt 0) {
                $findings.Add((ConvertTo-Finding `
                    -Tool $tool `
                    -Signal 'documentation update' `
                    -Baseline $knownDocumentDate `
                    -Current $currentDocumentDate `
                    -UpstreamUrl ([string]$tool.url) `
                    -Reasons $reasons.ToArray()))
            }
        }

        'json-url' {
            $response = Invoke-WebRequest -Uri ([string]$tool.url)
            $json = $response.Content | ConvertFrom-Json -Depth 100
            $reasons = [System.Collections.Generic.List[string]]::new()
            $currentValues = [System.Collections.Generic.List[string]]::new()
            $baselineValues = [System.Collections.Generic.List[string]]::new()

            foreach ($check in @($tool.checks)) {
                $currentValue = Convert-ToDisplayString (Get-ObjectValue -InputObject $json -Path ([string]$check.path))
                $expectedValue = Convert-ToDisplayString $check.expected
                $currentValues.Add("$($check.name)=$currentValue")
                $baselineValues.Add("$($check.name)=$expectedValue")

                if ($currentValue -ne $expectedValue) {
                    $reasons.Add("[$($check.name)] が変化しました。($expectedValue -> $currentValue)")
                }
            }

            if ($reasons.Count -gt 0) {
                $findings.Add((ConvertTo-Finding `
                    -Tool $tool `
                    -Signal 'schema change' `
                    -Baseline ($baselineValues -join '; ') `
                    -Current ($currentValues -join '; ') `
                    -UpstreamUrl ([string]$tool.url) `
                    -Reasons $reasons.ToArray()))
            }
        }

        default {
            throw "Unsupported tool kind: $($tool.kind)"
        }
    }
}

$findingsJson = @($findings.ToArray()) | ConvertTo-Json -Depth 20 -AsArray
Set-Content -Path $absoluteFindingsPath -Value $findingsJson

Write-WorkflowOutput -Name 'has_findings' -Value ($(if ($findings.Count -gt 0) { 'true' } else { 'false' }))
Write-WorkflowOutput -Name 'findings_path' -Value $absoluteFindingsPath

Write-StepSummaryLine -Line '## Tool spec watch'
Write-StepSummaryLine -Line ''

if ($findings.Count -eq 0) {
    Write-StepSummaryLine -Line 'No actionable upstream changes detected.'
    Write-Output 'No actionable upstream changes detected.'
    exit 0
}

Write-StepSummaryLine -Line '| Tool | Signal | Current | Baseline |'
Write-StepSummaryLine -Line '|------|--------|---------|----------|'

foreach ($finding in $findings) {
    Write-StepSummaryLine -Line "| $($finding.displayName) | $($finding.signal) | $($finding.current) | $($finding.baseline) |"
}

Write-Output "Detected $($findings.Count) actionable upstream change(s)."
