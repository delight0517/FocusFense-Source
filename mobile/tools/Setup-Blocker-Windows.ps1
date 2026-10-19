# 6 VPN Blocker — one-click browser extension setup (Windows).
# UAC optional: -Admin for Firefox Program Files policies; default skips HKLM.
#
# Usage (from repo):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "mobile\tools\Setup-Blocker-Windows.ps1"
# With admin (Firefox distribution\policies.json in Program Files):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "mobile\tools\Setup-Blocker-Windows.ps1" -Admin

param(
  [switch] $Admin,
  [string] $MobileRoot = ""
)

$ErrorActionPreference = "Stop"

function New-AppShortcut {
  param(
    [string] $LinkPath,
    [string] $TargetExe,
    [string] $Arguments = "",
    [string] $WorkDir,
    [string] $Description = "6 VPN Blocker"
  )
  $parent = Split-Path -Parent $LinkPath
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $shell = New-Object -ComObject WScript.Shell
  $sc = $shell.CreateShortcut($LinkPath)
  $sc.TargetPath = $TargetExe
  if ($Arguments) { $sc.Arguments = $Arguments }
  $sc.WorkingDirectory = $WorkDir
  $sc.IconLocation = "$TargetExe,0"
  $sc.Description = $Description
  $sc.WindowStyle = 1
  $sc.Save()
}

function Find-ChromeExe {
  $candidates = @(
    (Join-Path ${env:ProgramFiles} "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
    (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
  )
  foreach ($p in $candidates) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  return $null
}

function Find-EdgeExe {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
    (Join-Path ${env:ProgramFiles} "Microsoft\Edge\Application\msedge.exe")
  )
  foreach ($p in $candidates) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  return $null
}

if (-not $MobileRoot) {
  $MobileRoot = Split-Path -Parent $PSScriptRoot
}

$installDir = Join-Path $env:LOCALAPPDATA "Programs\SixVPNBlocker"
$chromeExtDest = Join-Path $env:LOCALAPPDATA "SixVPNBlocker\chrome_blocker"
$chromeExtSrc = Join-Path $MobileRoot "assets\browser_extensions\chrome"
$programDataFirefox = Join-Path $env:ProgramData "SixVPNBlocker\firefox"
$xpiName = "sixvpn-blocker@sixvpnblocker.app.xpi"
$xpiPath = Join-Path $programDataFirefox $xpiName
$firefoxId = "sixvpn-blocker@sixvpnblocker.app"

Write-Host "6 VPN Blocker setup (UAC-free first)" -ForegroundColor Cyan

# --- Chrome extension folder ---
if (-not (Test-Path -LiteralPath $chromeExtDest)) {
  New-Item -ItemType Directory -Force -Path $chromeExtDest | Out-Null
}
if (Test-Path -LiteralPath $chromeExtSrc) {
  Copy-Item -Path (Join-Path $chromeExtSrc '*') -Destination $chromeExtDest -Recurse -Force
  Write-Host "Chrome ext copied -> $chromeExtDest" -ForegroundColor Green
} elseif (-not (Test-Path -LiteralPath (Join-Path $chromeExtDest "manifest.json"))) {
  Write-Host "Chrome assets missing at $chromeExtSrc — run app easy setup or rebuild first." -ForegroundColor Yellow
}

# --- Firefox XPI (ProgramData, no admin) ---
if (-not (Test-Path -LiteralPath $programDataFirefox)) {
  New-Item -ItemType Directory -Force -Path $programDataFirefox | Out-Null
}
$bundledXpi = Join-Path $MobileRoot "assets\browser_extensions\firefox\sixvpn_blocker_signed.xpi"
$firefoxSrc = Join-Path $MobileRoot "assets\browser_extensions\firefox"
if (Test-Path -LiteralPath $bundledXpi) {
  Copy-Item -LiteralPath $bundledXpi -Destination $xpiPath -Force
  Write-Host "Firefox XPI (signed) -> $xpiPath" -ForegroundColor Green
} else {
  throw 'Bundled signed Firefox XPI missing; refusing to replace it with an unsigned package.'
}

# --- Firefox policies (admin optional) ---
$policyBody = @"
{
  "policies": {
    "ExtensionSettings": {
      "$firefoxId": {
        "installation_mode": "force_installed",
        "install_url": "file:///$($xpiPath.Replace('\','/'))"
      }
    }
  }
}
"@

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Admin -and $isAdmin) {
  $ffRoots = @(
    (Join-Path ${env:ProgramFiles} "Mozilla Firefox"),
    (Join-Path ${env:ProgramFiles(x86)} "Mozilla Firefox")
  )
  foreach ($ff in $ffRoots) {
    if (-not (Test-Path -LiteralPath $ff)) { continue }
    $dist = Join-Path $ff "distribution"
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Set-Content -Path (Join-Path $dist "policies.json") -Value $policyBody -Encoding UTF8
    Write-Host "Firefox policies.json -> $dist" -ForegroundColor Green
  }
} else {
  Write-Host "Firefox policies.json: skipped (use -Admin for Program Files)" -ForegroundColor Yellow
}

# --- Chrome/Edge desktop shortcuts (--load-extension) ---
$desktop = [Environment]::GetFolderPath("Desktop")
$sixVpnDir = Join-Path $env:LOCALAPPDATA "SixVPNBlocker"
New-Item -ItemType Directory -Force -Path $sixVpnDir | Out-Null

$chromeExe = Find-ChromeExe
$edgeExe = Find-EdgeExe
$extArg = "--load-extension=`"$chromeExtDest`""

if ($chromeExe) {
  $bat = Join-Path $sixVpnDir "Launch-6VPN-Chrome.bat"
  @"
@echo off
taskkill /F /IM chrome.exe /T 2>nul
timeout /t 2 /nobreak >nul
start "" "$chromeExe" $extArg
"@ | Set-Content -Path $bat -Encoding ASCII
  New-AppShortcut -LinkPath (Join-Path $desktop "6 VPN Blocker (Chrome).lnk") `
    -TargetExe $bat -WorkDir $sixVpnDir -Description "6 VPN Blocker Chrome"
  Write-Host "Chrome shortcut -> $desktop\6 VPN Blocker (Chrome).lnk" -ForegroundColor Green
}

if ($edgeExe) {
  $bat = Join-Path $sixVpnDir "Launch-6VPN-Edge.bat"
  @"
@echo off
taskkill /F /IM msedge.exe /T 2>nul
timeout /t 2 /nobreak >nul
start "" "$edgeExe" $extArg
"@ | Set-Content -Path $bat -Encoding ASCII
  New-AppShortcut -LinkPath (Join-Path $desktop "6 VPN Blocker (Edge).lnk") `
    -TargetExe $bat -WorkDir $sixVpnDir -Description "6 VPN Blocker Edge"
  Write-Host "Edge shortcut -> $desktop\6 VPN Blocker (Edge).lnk" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Use desktop 6 VPN Blocker (Chrome) — not the normal Chrome icon." -ForegroundColor Cyan
Write-Host "Firefox: about:addons — no Remove/Toggle = success." -ForegroundColor Cyan
