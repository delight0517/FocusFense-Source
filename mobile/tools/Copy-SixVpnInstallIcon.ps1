# Copies branded app_icon.ico next to the installed exe for shortcuts/taskbar.
param(
  [string] $MobileRoot = "",
  [string] $InstallDir = ""
)

$ErrorActionPreference = 'Stop'

if (-not $MobileRoot) {
  $MobileRoot = Split-Path -Parent $PSScriptRoot
}
if (-not $InstallDir) {
  $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\SixVPNBlocker'
}

$sources = @(
  (Join-Path $MobileRoot 'windows\runner\resources\app_icon.ico'),
  (Join-Path $MobileRoot 'assets\app_icon.ico')
)

$dest = Join-Path $InstallDir 'app_icon.ico'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

foreach ($src in $sources) {
  if (Test-Path -LiteralPath $src) {
    Copy-Item -LiteralPath $src -Destination $dest -Force
    Write-Host "Install icon: $dest" -ForegroundColor Green
    exit 0
  }
}

Write-Host 'WARN: app_icon.ico source not found — shortcuts will use exe icon.' -ForegroundColor Yellow
exit 1
