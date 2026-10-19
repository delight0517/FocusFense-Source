# Simulates Windows logon autostart: validates Run registry + optional launch probe.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File mobile\tools\Test-AutostartSimulate.ps1
#        add -LaunchProbe to start the exe when not already running (then leave it up).

param([switch] $LaunchProbe)

$ErrorActionPreference = 'Stop'
$fail = 0

function Assert($label, $pass) {
  if ($pass) {
    Write-Host "[OK] $label" -ForegroundColor Green
  } else {
    Write-Host "[FAIL] $label" -ForegroundColor Red
    $script:fail++
  }
}

$exe = Join-Path $env:LOCALAPPDATA 'Programs\SixVPNBlocker\six_clean_room.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'

Write-Host '=== 6 VPN Blocker autostart simulate ===' -ForegroundColor Cyan

Assert 'install exe exists' (Test-Path -LiteralPath $exe)

$runVal = (Get-ItemProperty -LiteralPath $runKey -Name SixVPNBlocker -ErrorAction SilentlyContinue).SixVPNBlocker
Assert 'Run registry present' ($null -ne $runVal)
Assert 'Run points at six_clean_room.exe' ($runVal -match 'six_clean_room\.exe')
Assert 'Run has no cmd.exe wrapper' ($runVal -notmatch 'cmd\.exe')

$approved = (Get-ItemProperty -LiteralPath $approvedKey -Name SixVPNBlocker -ErrorAction SilentlyContinue).SixVPNBlocker
$enabled = ($null -ne $approved) -and ($approved.Length -ge 1) -and ($approved[0] -eq 0x02)
Assert 'StartupApproved enabled (0x02)' $enabled

foreach ($tn in @('SixVPNBlockerAutostart', 'SixVPNBlockerBootGuard', 'SixVPNBlockerWatchdog', 'SixVPNBlockerWatchdog2')) {
  $q = schtasks /Query /TN $tn /FO LIST 2>$null
  Assert "scheduled task $tn" ($LASTEXITCODE -eq 0)
}

$running = Get-Process -Name six_clean_room -ErrorAction SilentlyContinue
if ($LaunchProbe) {
  if (-not $running) {
    $launchPath = $runVal.Trim('"')
    if (-not (Test-Path -LiteralPath $launchPath)) { $launchPath = $exe }
    Write-Host "Launch probe: Start-Process $launchPath" -ForegroundColor Yellow
    Start-Process -FilePath $launchPath -WorkingDirectory (Split-Path -Parent $launchPath)
    Start-Sleep -Seconds 3
    $running = Get-Process -Name six_clean_room -ErrorAction SilentlyContinue
  }
  Assert 'process running after launch probe' ($null -ne $running)
} else {
  if ($running) {
    Write-Host "[INFO] six_clean_room already running (pid=$($running.Id -join ','))" -ForegroundColor DarkGray
  } else {
    Write-Host '[INFO] app not running — add -LaunchProbe to test Start-Process path' -ForegroundColor DarkGray
  }
}

Write-Host ''
if ($fail -eq 0) {
  Write-Host 'Autostart simulate PASS' -ForegroundColor Green
  exit 0
}
Write-Host "Autostart simulate FAIL ($fail checks)" -ForegroundColor Red
exit 1
