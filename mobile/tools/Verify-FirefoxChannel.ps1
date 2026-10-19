# +225 Firefox @winterstarcraft channel apply probe (disk/registry).
param(
  [string]$Handle = 'winterstarcraft'
)

$ErrorActionPreference = 'Continue'
$extId = 'sixvpn-blocker@sixvpnblocker.app'
$report = [ordered]@{
  timestamp = (Get-Date).ToString('o')
  handle = $Handle
  profiles = @()
  websiteFilter = @()
  snapshot = $false
  hkcuPolicy = $false
  xpiProgramData = $false
  overallOk = $false
}

function Note-Fail { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red }
function Note-Ok { param($m) Write-Host "[OK] $m" -ForegroundColor Green }

Write-Host "=== Verify-FirefoxChannel (+225) @$Handle ===" -ForegroundColor Cyan

$snapPath = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\chrome_blocker\rules_snapshot.json'
if (Test-Path -LiteralPath $snapPath) {
  try {
    $snap = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json
    $hl = $Handle.ToLowerInvariant()
    $report.snapshot = (($snap.blockedYoutubeHandles | ForEach-Object { $_.ToLowerInvariant() }) -contains $hl)
    if ($report.snapshot) { Note-Ok "rules_snapshot has @$Handle" } else { Note-Fail "snapshot missing @$Handle" }
  } catch { Note-Fail 'snapshot parse error' }
} else { Note-Fail 'rules_snapshot.json missing' }

$xpiPd = Join-Path $env:ProgramData 'SixVPNBlocker\firefox\sixvpn-blocker@sixvpnblocker.app.xpi'
$report.xpiProgramData = Test-Path -LiteralPath $xpiPd
if ($report.xpiProgramData) { Note-Ok 'ProgramData XPI exists' } else { Note-Fail 'ProgramData XPI missing' }

$hkcu = reg query 'HKCU\SOFTWARE\Policies\Mozilla\Firefox' 2>&1 | Out-String
$report.hkcuPolicy = $hkcu -match 'sixvpn-blocker@sixvpnblocker.app'
if ($report.hkcuPolicy) { Note-Ok 'HKCU ExtensionSettings force_installed' } else { Note-Fail 'HKCU policy missing' }

$wf = reg query 'HKCU\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block' /s 2>&1 | Out-String
$hl = $Handle.ToLowerInvariant()
if ($wf -match [regex]::Escape($hl)) {
  $report.websiteFilter += $Handle
  Note-Ok "WebsiteFilter has @$Handle pattern"
} else {
  Note-Fail "WebsiteFilter missing @$Handle"
}

$profRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
if (Test-Path -LiteralPath $profRoot) {
  Get-ChildItem -LiteralPath $profRoot -Directory | ForEach-Object {
    $name = $_.Name
    $xpi = Join-Path $_.FullName "extensions\$extId.xpi"
    $extJson = Join-Path $_.FullName 'extensions.json'
    $row = [ordered]@{ profile = $name; xpiOnDisk = (Test-Path -LiteralPath $xpi); extActive = $false }
    if (Test-Path -LiteralPath $extJson) {
      try {
        $j = Get-Content -LiteralPath $extJson -Raw | ConvertFrom-Json
        foreach ($a in $j.addons) {
          if ($a.id -eq $extId -and $a.active -and -not $a.userDisabled) { $row.extActive = $true }
        }
      } catch {}
    }
    $report.profiles += $row
    if ($row.extActive) { Note-Ok "profile $name extension active" }
    elseif ($row.xpiOnDisk) { Note-Fail "profile $name XPI on disk not active - restart Firefox" }
    else { Note-Fail "profile $name no sixvpn-blocker" }
  }
}

$anyActive = @($report.profiles | Where-Object { $_.extActive }).Count -gt 0
$report.overallOk = $report.snapshot -and $report.hkcuPolicy -and (
  $anyActive -or ($report.websiteFilter.Count -gt 0) -or $report.xpiProgramData
)

$out = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\verify_firefox_channel.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host "Report: $out"
if ($report.overallOk) {
  Write-Host 'Overall: PASS' -ForegroundColor Green
  exit 0
} else {
  Write-Host 'Overall: FAIL' -ForegroundColor Red
  exit 1
}
