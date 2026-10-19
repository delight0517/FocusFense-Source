# Direct disk/registry read — same style as +227 channel apply probes.
param(
  [string[]]$TestHandles = @('winterstarcraft'),
  [string[]]$TestVideoIds = @('0ucghClyrrk', 'so-Rv8RlCUc', 'lDRT5e6JsY4', 'wCrc7vy_Tmk')
)

$ErrorActionPreference = 'Continue'
$extId = 'popjkofklmidngceakpcokopghehjngo'
$report = [ordered]@{
  timestamp = (Get-Date).ToString('o')
  urlBlocklist = @{}
  profiles = @()
  snapshot = $null
  hosts = @{}
  api = @()
  overallOk = $true
}

function Note-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:report.overallOk = $false }
function Note-Ok { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }

Write-Host '=== Verify-BrowserApplyDirect (+227 style) ===' -ForegroundColor Cyan

# URLBlocklist
$blOut = (reg query 'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist' /s 2>&1 | Out-String)
foreach ($t in $TestVideoIds) {
  $low = $t.ToLower()
  $hit = ($blOut -match [regex]::Escape($low)) -or ($blOut -match [regex]::Escape($t))
  $report.urlBlocklist[$t] = $hit
  if ($hit) { Note-Ok "URLBlocklist has video $t" } else { Note-Fail "URLBlocklist missing video $t" }
}
foreach ($h in $TestHandles) {
  $low = $h.ToLower()
  $hit = ($blOut -match [regex]::Escape("/@$low")) -or ($blOut -match [regex]::Escape("/@$h"))
  $report.urlBlocklist[$h] = $hit
  if ($hit) { Note-Ok "URLBlocklist has @$h" } else { Note-Fail "URLBlocklist missing @$h" }
}

# Chrome profiles — Preferences JSON + Extensions folder
$ud = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
$profNames = @('Default')
if (Test-Path $ud) {
  $profNames += @(Get-ChildItem -LiteralPath $ud -Directory -Filter 'Profile *' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}
foreach ($prof in ($profNames | Select-Object -Unique)) {
  $prefsPath = Join-Path (Join-Path $ud $prof) 'Preferences'
  $row = [ordered]@{ profile = $prof; extActive = $false; versions = @(); prefsFound = $false }
  if (Test-Path -LiteralPath $prefsPath) {
    $row.prefsFound = $true
    try {
      $j = Get-Content -LiteralPath $prefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $st = $j.extensions.settings.$extId.state
      $row.extActive = ($null -eq $st) -or ($st -ne 1)
    } catch {
      $row.error = $_.Exception.Message
    }
  }
  $extDir = Join-Path (Join-Path (Join-Path $ud $prof) 'Extensions') $extId
  if (Test-Path -LiteralPath $extDir) {
    $row.versions = @(Get-ChildItem -LiteralPath $extDir -Directory | ForEach-Object { $_.Name })
  }
  $payloadDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\chrome_blocker'
  $row.payloadOk = (Test-Path -LiteralPath (Join-Path $payloadDir 'rules_snapshot.json'))
  $report.profiles += $row
  if ($row.extActive -and ($row.versions.Count -gt 0 -or $row.payloadOk)) {
    $ver = if ($row.versions.Count -gt 0) { $row.versions -join ',' } else { 'policy/payload' }
    Note-Ok "Chrome $prof extension active ($ver)"
  } else {
    Note-Fail "Chrome $prof extActive=$($row.extActive) versions=$($row.versions -join ',')"
  }
}

# rules_snapshot.json
$snapPath = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\chrome_blocker\rules_snapshot.json'
if (Test-Path -LiteralPath $snapPath) {
  try {
    $snap = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json
    $report.snapshot = @{
      handles = @($snap.blockedYoutubeHandles)
      videos = @($snap.blockedYoutubeVideoIds)
    }
    Note-Ok "snapshot handles=$($snap.blockedYoutubeHandles -join ',') videos=$($snap.blockedYoutubeVideoIds -join ',')"
    foreach ($h in $TestHandles) {
      $hl = $h.ToLower()
      if (($snap.blockedYoutubeHandles | ForEach-Object { $_.ToLower() }) -notcontains $hl) {
        Note-Fail "snapshot missing handle $h"
      }
    }
    foreach ($v in $TestVideoIds) {
      $vl = $v.ToLower()
      if (($snap.blockedYoutubeVideoIds | ForEach-Object { $_.ToLower() }) -notcontains $vl) {
        Note-Fail "snapshot missing video $v"
      }
    }
  } catch {
    Note-Fail "snapshot parse error: $_"
  }
} else {
  Note-Fail 'rules_snapshot.json missing'
}

# hosts managed region
$hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
if (Test-Path -LiteralPath $hostsPath) {
  $h = Get-Content -LiteralPath $hostsPath -Raw
  $hasBegin = $h -match '6 VPN Blocker BEGIN'
  $hasEnd = $h -match '6 VPN Blocker END'
  $sink = ([regex]::Matches($h, '(?m)^0\.0\.0\.0 ')).Count
  $report.hosts = @{ begin = $hasBegin; end = $hasEnd; sinkholeLines = $sink; hasYoutube = ($h -match 'youtube\.com') }
  if ($hasBegin -and $hasEnd -and $sink -ge 80) {
    Note-Ok "hosts managed sinkhole_lines=$sink"
  } else {
    Note-Fail "hosts truncated begin=$hasBegin end=$hasEnd lines=$sink"
  }
}

# Live API
foreach ($v in $TestVideoIds) {
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:17361/youtube/check?v=$v" -TimeoutSec 6
    $row = @{ video = $v; blocked = [bool]$r.blocked; matched = $r.matched }
    $report.api += $row
    if ($r.blocked) { Note-Ok "API blocked $v" } else { Note-Fail "API NOT blocked $v" }
  } catch {
    $report.api += @{ video = $v; error = $_.Exception.Message }
    Note-Fail "API unreachable for $v"
  }
}

$outPath = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\verify_browser_apply_direct.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Host ""
Write-Host "Report: $outPath" -ForegroundColor Cyan
Write-Host ("Overall: " + $(if ($report.overallOk) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($report.overallOk) { 'Green' } else { 'Red' })
exit $(if ($report.overallOk) { 0 } else { 1 })
