# Consumer Chrome: profile CRX/policy install is unreliable - enforce --load-extension path.
param(
  [switch]$LaunchProtected,
  [switch]$ElevateProgramData
)

$ErrorActionPreference = 'Continue'
$six = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$vbs = Join-Path $six 'Launch-6VPN-Chrome.vbs'
$ext = Join-Path $six 'chrome_blocker'
$hijack = Join-Path $six 'shortcut_hijack.ps1'
$chromeExe = @(
  (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
  (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

Write-Host '=== Ensure Chrome --load-extension path ===' -ForegroundColor Cyan

& (Join-Path $PSScriptRoot 'Fix-ChromeLauncher-Now.ps1')

function Set-ProtectedChromeLnk {
  param(
    [string]$LnkPath,
    [string]$Launcher,
    [string]$WorkDir,
    [string]$IconExe
  )
  $parent = Split-Path -Parent $LnkPath
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $sh = New-Object -ComObject WScript.Shell
  $sc = $sh.CreateShortcut($LnkPath)
  $sc.TargetPath = $Launcher
  $sc.Arguments = ''
  $sc.WorkingDirectory = $WorkDir
  if ($IconExe) { $sc.IconLocation = "$IconExe,0" }
  $sc.Save()
}

$userLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk'
try {
  Set-ProtectedChromeLnk -LnkPath $userLnk -Launcher $vbs -WorkDir $six -IconExe $chromeExe
  Write-Host "OK: user Start Menu override -> $userLnk" -ForegroundColor Green
}
catch {
  Write-Host "WARN: user override failed - $($_.Exception.Message)" -ForegroundColor Yellow
}

if (Test-Path -LiteralPath $hijack) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $hijack 2>&1
  Write-Host "shortcut_hijack: $out"
}

$pdLnk = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk'
if ($ElevateProgramData -and (Test-Path -LiteralPath $pdLnk) -and $chromeExe) {
  $elev = Join-Path $six 'shortcut_hijack_elevate_once.ps1'
  $elevBody = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$sh = New-Object -ComObject WScript.Shell
`$sc = `$sh.CreateShortcut('$pdLnk')
`$sc.TargetPath = '$vbs'
`$sc.Arguments = ''
`$sc.WorkingDirectory = '$six'
`$sc.IconLocation = '$chromeExe,0'
`$sc.Save()
"@
  Set-Content -LiteralPath $elev -Value $elevBody -Encoding ASCII
  try {
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$elev) -Verb RunAs -Wait
    Write-Host 'OK: ProgramData Google Chrome.lnk elevated patch attempted' -ForegroundColor Green
  }
  catch {
    Write-Host "WARN: elevated patch skipped - $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

Write-Host ''
Write-Host '=== Profile CRX check (expected: NOT installed on consumer Chrome) ===' -ForegroundColor Cyan
$profiles = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') -Directory -EA SilentlyContinue |
  Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile ' }
$extId = 'popjkofklmidngceakpcokopghehjngo'
foreach ($p in $profiles) {
  $hit = Test-Path (Join-Path $p.FullName "Extensions\$extId")
  $label = if ($hit) { 'CRX present' } else { 'NOT installed (normal)' }
  Write-Host "$($p.Name): $label"
}

if ($LaunchProtected) {
  Write-Host ''
  Write-Host 'Launching protected Chrome (new window, existing Chrome untouched)...' -ForegroundColor Cyan
  Start-Process wscript.exe -ArgumentList @('//B','//Nologo',$vbs) -WindowStyle Hidden
  Start-Sleep -Seconds 4
}

$protected = @(Get-CimInstance Win32_Process -Filter "name='chrome.exe'" -EA SilentlyContinue |
  Where-Object { $_.CommandLine -notmatch '--type=' -and $_.CommandLine -match 'load-extension' })
Write-Host "Protected main chrome.exe processes: $($protected.Count)"
if ($protected.Count -gt 0) {
  Write-Host 'PASS: --load-extension Chrome is running' -ForegroundColor Green
  exit 0
}
if (-not $LaunchProtected) {
  Write-Host 'INFO: no protected Chrome yet - use -LaunchProtected or Start menu Google Chrome (user override)' -ForegroundColor Yellow
}
if (-not (Test-Path -LiteralPath (Join-Path $ext 'manifest.json'))) {
  Write-Host 'FAIL: chrome_blocker manifest missing' -ForegroundColor Red
  exit 1
}
exit 0
