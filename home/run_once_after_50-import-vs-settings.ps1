# Visual Studio settings import reminder (Windows only)
# The .vssettings file has been deployed to ~/.visualstudio/
# Import manually via: Tools > Import and Export Settings > Import selected environment settings

if (-not $IsWindows) { exit 0 }

$settingsFile = Join-Path $HOME ".visualstudio\vscode2026insider.vssettings"
if (Test-Path $settingsFile) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Visual Studio Settings" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "To import your saved settings, open Visual Studio and go to:"
    Write-Host "  Tools > Import and Export Settings > Import selected environment settings"
    Write-Host ""
    Write-Host "Settings file: $settingsFile" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}
