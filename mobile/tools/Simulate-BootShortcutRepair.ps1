# Simulates boot shortcut repair: plain chrome.exe .lnk -> protected VBS launcher.
param(
  [string]$SixVpnDir = "$env:LOCALAPPDATA\SixVPNBlocker"
)

$ErrorActionPreference = 'Continue'
$testLnk = Join-Path $env:USERPROFILE 'Desktop\6VPN_Test_Chrome_Plain.lnk'
$hijack = Join-Path $SixVpnDir 'shortcut_hijack.ps1'
$vbs = Join-Path $SixVpnDir 'Launch-6VPN-Chrome.vbs'
$chromeExe = @(
  (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
  (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $chromeExe) {
  Write-Host 'FAIL: chrome.exe not found' -ForegroundColor Red
  exit 1
}
if (-not (Test-Path -LiteralPath $hijack)) {
  Write-Host "FAIL: missing $hijack" -ForegroundColor Red
  exit 1
}

try {
  $sh = New-Object -ComObject WScript.Shell
  $sc = $sh.CreateShortcut($testLnk)
  $sc.TargetPath = $chromeExe
  $sc.WorkingDirectory = Split-Path -Parent $chromeExe
  $sc.Save()
} catch {
  Write-Host "FAIL: could not create test lnk - $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

& powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $hijack | Out-Null

$patched = $false
try {
  $sh2 = New-Object -ComObject WScript.Shell
  $after = $sh2.CreateShortcut($testLnk)
  $tp = ($after.TargetPath -replace '/', '\').ToLowerInvariant()
  $patched = $tp -match 'launch-6vpn-chrome\.vbs$'
} catch {}

Remove-Item -LiteralPath $testLnk -Force -ErrorAction SilentlyContinue

if ($patched -and (Test-Path -LiteralPath $vbs)) {
  Write-Host 'OK: plain chrome.lnk patched to Launch-6VPN-Chrome.vbs' -ForegroundColor Green
  exit 0
}
Write-Host "FAIL: patched=$patched vbs=$(Test-Path $vbs)" -ForegroundColor Red
exit 1
