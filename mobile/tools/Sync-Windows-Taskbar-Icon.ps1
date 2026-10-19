# Embeds app icon into six_clean_room.exe (taskbar, title bar, Alt+Tab).
$ErrorActionPreference = 'Stop'
$MobileRoot = Split-Path -Parent $PSScriptRoot
Set-Location $MobileRoot

$png = Join-Path $MobileRoot 'assets\app_icon.png'
$ico = Join-Path $MobileRoot 'assets\app_icon.ico'
$iconsDir = Join-Path $MobileRoot 'assets\icons'
$master = Join-Path $iconsDir 'master_icon.png'

if (-not (Test-Path -LiteralPath $png)) {
  Write-Host '[icon] ERROR: missing assets\app_icon.png' -ForegroundColor Red
  exit 1
}

New-Item -ItemType Directory -Force -Path $iconsDir | Out-Null
Copy-Item -LiteralPath $png -Destination $master -Force
Write-Host "[icon] master -> $master"

Write-Host '[icon] flutter pub get...'
flutter pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host '[icon] dart run flutter_launcher_icons (windows)...'
dart run flutter_launcher_icons
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$runnerIco = Join-Path $MobileRoot 'windows\runner\resources\app_icon.ico'
if (Test-Path -LiteralPath $runnerIco) {
  Copy-Item -LiteralPath $runnerIco -Destination $ico -Force
  Write-Host "[icon] synced runner ICO -> assets\app_icon.ico"
} else {
  Write-Host '[icon] WARN: runner app_icon.ico not generated' -ForegroundColor Yellow
}

Write-Host '[icon] Done. Rebuild Windows exe to refresh taskbar cache.'
