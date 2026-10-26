[CmdletBinding()]
param(
    [ValidateSet('plan', 'prepare', 'switch', 'verify', 'finalize', 'rollback')]
    [string] $Phase = 'plan',

    [Parameter(Mandatory = $true)]
    [string] $StateDirectory,

    [string[]] $Project = @(),
    [string[]] $Sdk = @(),
    [switch] $IdeChecksConfirmed
)

$ErrorActionPreference = 'Stop'

if ($IsWindows -or $IsLinux -or -not $IsMacOS) {
    [Console]::Error.WriteLine('This migration is supported only on macOS.')
    exit 1
}

if (-not [IO.Path]::IsPathFullyQualified($StateDirectory)) {
    [Console]::Error.WriteLine('-StateDirectory must be an absolute path.')
    exit 2
}
foreach ($projectPath in $Project) {
    if (-not [IO.Path]::IsPathFullyQualified($projectPath)) {
        [Console]::Error.WriteLine("Project paths must be absolute: $projectPath")
        exit 2
    }
}
foreach ($version in $Sdk) {
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        [Console]::Error.WriteLine("SDK versions must be exact X.Y.Z values: $version")
        exit 2
    }
}

$bash = '/bin/bash'
if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) {
    [Console]::Error.WriteLine('macOS /bin/bash is unavailable.')
    exit 1
}
$bashScript = Join-Path $PSScriptRoot 'migrate-dotnet-macos.sh'
if (-not (Test-Path -LiteralPath $bashScript -PathType Leaf)) {
    [Console]::Error.WriteLine("Bash implementation not found: $bashScript")
    exit 1
}

$arguments = [Collections.Generic.List[string]]::new()
$arguments.Add($bashScript)
$arguments.Add($Phase)
$arguments.Add('--state-dir')
$arguments.Add($StateDirectory)
foreach ($projectPath in $Project) {
    $arguments.Add('--project')
    $arguments.Add($projectPath)
}
foreach ($version in $Sdk) {
    $arguments.Add('--sdk')
    $arguments.Add($version)
}
if ($IdeChecksConfirmed) {
    $arguments.Add('--ide-checks-confirmed')
}

& $bash @arguments
$exitCode = $LASTEXITCODE
exit $exitCode
