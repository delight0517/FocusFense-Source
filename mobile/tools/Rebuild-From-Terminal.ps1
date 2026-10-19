# One command to rebuild + install + relaunch (finds mobile folder automatically).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\...\mobile\tools\Rebuild-From-Terminal.ps1"
#
# Optional: -WaitAtEnd  (keep window open)
# Override path:  $env:SIXVPN_MOBILE_ROOT = "C:\...\mobile"

param(
  [switch] $WaitAtEnd,
  [switch] $NoLaunch
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-MobileRoot.ps1")

$mobileRoot = Resolve-SixVpnMobileRoot -PersistMarker
if (-not $mobileRoot) {
  Write-Host ""
  Write-Host "Could not find a valid mobile source folder." -ForegroundColor Red
  Write-Host "Need: pubspec.yaml + tools\Rebuild-6VPN-Windows.ps1 (not empty)." -ForegroundColor Red
  Write-Host ""
  Write-Host "Fix:" -ForegroundColor Yellow
  Write-Host "  1) Copy the full 6VPN_Image_Blocker repo (with mobile\tools)." -ForegroundColor Yellow
  Write-Host "  2) In app Settings, Windows dev build card: pick mobile folder and save." -ForegroundColor Yellow
  Write-Host '  3) Or: $env:SIXVPN_MOBILE_ROOT = "C:\path\to\mobile"' -ForegroundColor Yellow
  Write-Host ""
  if ($WaitAtEnd) { Read-Host "Press Enter to close" | Out-Null }
  exit 2
}

Write-Host "Using mobile root: $mobileRoot" -ForegroundColor Green
$rebuild = Join-Path $mobileRoot "tools\Rebuild-6VPN-Windows.ps1"
$rebuildArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $rebuild
)
if (-not $NoLaunch) { $rebuildArgs += '-LaunchAfter' }
if ($WaitAtEnd) { $rebuildArgs += '-WaitAtEnd' }

& powershell.exe @rebuildArgs
exit $LASTEXITCODE
