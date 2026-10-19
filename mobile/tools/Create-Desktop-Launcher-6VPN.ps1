# Creates clearly named shortcuts to the Windows release runner so you can
# find the app by "6 VPN" in Start / search (the real .exe is six_clean_room.exe).
# From repo:  powershell -ExecutionPolicy Bypass -File "mobile\tools\Create-Desktop-Launcher-6VPN.ps1"
# From anywhere (use full paths):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\...\6VPN_Image_Blocker\mobile\tools\Create-Desktop-Launcher-6VPN.ps1" -ExePath "$env:LOCALAPPDATA\Programs\SixVPNBlocker\six_clean_room.exe"
# Optional:            ... -ExePath "C:\path\to\six_clean_room.exe"

param(
  [string] $ExePath = "",
  [switch] $Force
)

$ErrorActionPreference = "Stop"

# Desktop launcher auto-create disabled unless -Force (user request 2026-06-05).
$remove = Join-Path $PSScriptRoot "Remove-6VPN-Desktop-Artifacts.ps1"
if (Test-Path -LiteralPath $remove) { & $remove }
if (-not $Force) {
  Write-Host "Desktop shortcut creation is disabled. Start Menu integration still runs via Install-Windows-OsIntegration.ps1." -ForegroundColor Cyan
  Write-Host "To recreate desktop .lnk manually: re-run with -Force" -ForegroundColor Gray
  $osOnly = Join-Path $PSScriptRoot "Install-Windows-OsIntegration.ps1"
  if (Test-Path -LiteralPath $osOnly) { & $osOnly -ExePath $ExePath }
  exit 0
}

function Get-SixVpnIconPath {
  param([string] $WorkDir)
  $ico = Join-Path $WorkDir 'app_icon.ico'
  if (Test-Path -LiteralPath $ico) { return $ico }
  return $null
}

function New-LauncherShortcut {
  param(
    [string] $LinkPath,
    [string] $TargetExe,
    [string] $WorkDir
  )
  $parent = Split-Path -Parent $LinkPath
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $shell = New-Object -ComObject WScript.Shell
  $sc = $shell.CreateShortcut($LinkPath)
  $sc.TargetPath = $TargetExe
  $sc.WorkingDirectory = $WorkDir
  $icon = Get-SixVpnIconPath -WorkDir $WorkDir
  if ($icon) { $sc.IconLocation = $icon } else { $sc.IconLocation = "$TargetExe,0" }
  $sc.WindowStyle = 1
  $sc.Description = "6 VPN Blocker (Windows)"
  $sc.Save()
}

$desktop = [Environment]::GetFolderPath("Desktop")
$legacy = @(
  'Six VPN Blocker (Windows).lnk',
  'six_clean_room.lnk',
  '6VPN Blocker.lnk',
  'Six VPN Blocker.lnk'
)
foreach ($name in $legacy) {
  $p = Join-Path $desktop $name
  if (Test-Path -LiteralPath $p) {
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    Write-Host "Removed legacy shortcut: $p" -ForegroundColor Yellow
  }
}
$shortcutDesktop = Join-Path $desktop "6 VPN Blocker (Windows).lnk"
$startMenu = [Environment]::GetFolderPath("StartMenu")
$programsDir = Join-Path $startMenu "Programs"
$shortcutStart = Join-Path $programsDir "6 VPN Blocker (Windows).lnk"

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $ExePath) {
  $installed = Join-Path $env:LOCALAPPDATA "Programs\SixVPNBlocker\six_clean_room.exe"
  if (Test-Path -LiteralPath $installed) {
    $ExePath = (Resolve-Path -LiteralPath $installed).Path
  } else {
    $defaultExe = Join-Path $toolsDir "..\build\windows\x64\runner\Release\six_clean_room.exe"
    $rp = Resolve-Path -LiteralPath $defaultExe -ErrorAction SilentlyContinue
    if ($rp) { $ExePath = $rp.Path }
  }
}

if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) {
  Write-Host "Executable not found. Build first:" -ForegroundColor Yellow
  Write-Host '  powershell -ExecutionPolicy Bypass -File "mobile\tools\Rebuild-6VPN-Windows.ps1"' -ForegroundColor Gray
  Write-Host "  (or: cd mobile && flutter build windows --release)" -ForegroundColor Gray
  Write-Host "Then re-run this script, or pass -ExePath to your six_clean_room.exe" -ForegroundColor Yellow
  exit 1
}

$dir = Split-Path -Parent $ExePath
$iconScript = Join-Path $toolsDir 'Copy-SixVpnInstallIcon.ps1'
if (Test-Path -LiteralPath $iconScript) {
  & $iconScript -InstallDir $dir | Out-Null
}
# Prefer searchable alias when present.
$searchExe = Join-Path $dir "6VPNBlocker.exe"
if (Test-Path -LiteralPath $searchExe) { $ExePath = $searchExe }

New-LauncherShortcut -LinkPath $shortcutDesktop -TargetExe $ExePath -WorkDir $dir
New-LauncherShortcut -LinkPath $shortcutStart -TargetExe $ExePath -WorkDir $dir

$osIntegration = Join-Path $toolsDir "Install-Windows-OsIntegration.ps1"
if (Test-Path -LiteralPath $osIntegration) {
  & $osIntegration -ExePath $ExePath
}

Write-Host "Created:" -ForegroundColor Green
Write-Host "  $shortcutDesktop"
Write-Host "  $shortcutStart"
Write-Host "Target exe: $ExePath"
Write-Host ""
Write-Host 'Tip: Win+Search "6vpn" or "6 VPN Blocker".' -ForegroundColor Cyan
Write-Host 'Installed as 6VPNBlocker.exe (search alias) + six_clean_room.exe.' -ForegroundColor Cyan
