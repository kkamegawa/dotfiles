# Visual Studio settings import reminder (Windows only)
# The .vssettings file has been deployed to ~/.visualstudio/
# Import manually via: Tools > Import and Export Settings > Import selected environment settings

if (-not $IsWindows) { exit 0 }

$settingsFile = Join-Path $HOME ".visualstudio\vscode2026insider.vssettings"
if (Test-Path $settingsFile) {
    Write-Output ""
    Write-Output "========================================"
    Write-Output " Visual Studio Settings"
    Write-Output "========================================"
    Write-Output "To import your saved settings, open Visual Studio and go to:"
    Write-Output "  Tools > Import and Export Settings > Import selected environment settings"
    Write-Output ""
    Write-Output "Settings file: $settingsFile"
    Write-Output "========================================"
    Write-Output ""
}
