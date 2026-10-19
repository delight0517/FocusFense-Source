# Quick automated checks for TODO.md NEXT ACTIONS (Windows).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File mobile\tools\Run-TodoDiagnostics.ps1

$ErrorActionPreference = 'Continue'
function Ok($label, $pass) { Write-Host ("[{0}] {1}" -f ($(if ($pass) { 'OK' } else { '!!' })), $label) }

Write-Host '=== 6 VPN Blocker TODO diagnostics ===' -ForegroundColor Cyan

$flag = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\no_auto_rebuild.flag'
Ok 'NO_AUTO_REBUILD flag' (Test-Path $flag)

$exe = Join-Path $env:LOCALAPPDATA 'Programs\SixVPNBlocker\six_clean_room.exe'
$runVal = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).SixVPNBlocker
$runOk = ($null -ne $runVal) -and ($runVal -match 'six_clean_room\.exe') -and ($runVal -notmatch 'cmd\.exe') -and (Test-Path -LiteralPath $exe)
Ok 'Autostart Run registry (bare exe, no cmd)' $runOk
$approved = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name SixVPNBlocker -ErrorAction SilentlyContinue).SixVPNBlocker
$approvedOk = ($null -ne $approved) -and ($approved.Length -ge 1) -and ($approved[0] -eq 0x02)
Ok 'StartupApproved enabled' $approvedOk

$pac = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\sixvpn_block.pac'
Ok 'PAC file' (Test-Path $pac)

foreach ($browser in @('Google\Chrome', 'Microsoft\Edge')) {
  $pm = reg query "HKCU\Software\Policies\$browser" /v ProxyMode 2>$null
  Ok "$browser ProxyMode=pac_script" ($LASTEXITCODE -eq 0 -and ($pm -match 'pac_script'))
}

$proc = Get-Process six_clean_room -ErrorAction SilentlyContinue
Ok 'App running (six_clean_room)' ($null -ne $proc)

if ($proc) {
  foreach ($v in @('oYVEqFdjNDs', 'so-Rv8RlCUc')) {
    try {
      $r = Invoke-RestMethod -Uri "http://127.0.0.1:17361/youtube/check?v=$v" -TimeoutSec 6
      Ok "API blocked $v" ($r.blocked -eq $true)
    } catch {
      Ok "API /youtube/check?v=$v" $false
    }
  }
}

$debug = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug'
foreach ($f in @('youtube_proactive_guard_last.json', 'tri_browser_heal_last.json')) {
  $p = Join-Path $debug $f
  Ok $f (Test-Path $p)
  if (Test-Path $p) {
    try {
      $j = Get-Content $p -Raw | ConvertFrom-Json
      Write-Host "  -> ok=$($j.ok) reason=$($j.reason) at=$($j.at)" -ForegroundColor DarkGray
    } catch {}
  }
}

Ok 'Firefox policies.json (Program Files)' (Test-Path 'C:\Program Files\Mozilla Firefox\distribution\policies.json')

$cb = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\chrome_blocker'
Ok 'chrome_blocker updates.xml' (Test-Path (Join-Path $cb 'updates.xml'))
$fl = reg query 'HKCU\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' 2>$null
Ok 'Chrome ExtensionInstallForcelist' ($LASTEXITCODE -eq 0 -and ($fl -match 'popjkofklmidngceakpcokopghehjngo'))

Write-Host ''
Write-Host 'Manual only: Chrome snackbar, extension delete recovery, PC reboot autostart, incognito.' -ForegroundColor Yellow
