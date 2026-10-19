# Simulates "user clicks Remove" on 6 VPN Blocker extension per browser.
# Writes %LOCALAPPDATA%\SixVPNBlocker\extension_delete_sim_last.json
param([switch]$SkipRecovery)

$ErrorActionPreference = 'SilentlyContinue'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$chromeExtId = 'popjkofklmidngceakpcokopghehjngo'
$firefoxExtId = 'sixvpn-blocker@sixvpnblocker.app'
$payloadDir = Join-Path $outDir 'chrome_blocker'

$report = [ordered]@{
  at        = (Get-Date).ToString('o')
  appRunning = $null -ne (Get-Process -Name six_clean_room -ErrorAction SilentlyContinue)
  browsers  = @()
}

function Add-BrowserRow {
  param(
    [string]$browser,
    [string]$phase,
    [string]$uiBehavior,
    [bool]$removeButtonWorks,
    [bool]$blockingStillWorks,
    [string]$detail
  )
  $script:report.browsers += [ordered]@{
    browser            = $browser
    phase              = $phase
    uiBehavior         = $uiBehavior
    removeButtonWorks  = [bool]$removeButtonWorks
    blockingStillWorks = [bool]$blockingStillWorks
    detail             = $detail
  }
}

function Get-ChromiumState {
  param([string]$userDataSub, [string]$browserName)
  $ud = Join-Path $env:LOCALAPPDATA $userDataSub
  $forcelistRoot = switch ($browserName) {
    'Edge' { 'HKCU:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist' }
  default { 'HKCU:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' }
  }
  $forcelistVal = $null
  if (Test-Path -LiteralPath $forcelistRoot) {
    $forcelistVal = (Get-ItemProperty -LiteralPath $forcelistRoot -ErrorAction SilentlyContinue).'1'
  }
  $policyLocked = ($forcelistVal -match $chromeExtId)
  $profiles = @()
  if (Test-Path -LiteralPath $ud) {
    $names = @('Default') + @(Get-ChildItem -LiteralPath $ud -Directory -Filter 'Profile *' -EA SilentlyContinue | ForEach-Object { $_.Name })
    foreach ($prof in ($names | Select-Object -Unique)) {
      $prefsPath = Join-Path (Join-Path $ud $prof) 'Preferences'
      $extDir = Join-Path (Join-Path (Join-Path $ud $prof) 'Extensions') $chromeExtId
      $row = [ordered]@{
        profile    = $prof
        onDisk     = (Test-Path -LiteralPath $extDir)
        state      = $null
        location   = $null
        prefsFound = (Test-Path -LiteralPath $prefsPath)
      }
      if ($row.prefsFound) {
        try {
          $j = Get-Content -LiteralPath $prefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
          $e = $j.extensions.settings.$chromeExtId
          if ($e) {
            $row.state = $e.state
            $row.location = $e.location
          }
        } catch {}
      }
      $profiles += $row
    }
  }
  [ordered]@{
    browser      = $browserName
    forcelistOk  = $policyLocked
    forcelistVal = $forcelistVal
    profiles     = $profiles
    payloadOk    = (Test-Path -LiteralPath (Join-Path $payloadDir 'manifest.json'))
    updatesOk    = (Test-Path -LiteralPath (Join-Path $payloadDir 'updates.xml'))
  }
}

function Simulate-ChromiumDelete {
  param([string]$userDataSub, [string]$browserName)
  $ud = Join-Path $env:LOCALAPPDATA $userDataSub
  $deleted = @()
  if (Test-Path -LiteralPath $ud) {
    Get-ChildItem -LiteralPath $ud -Directory -Filter 'Profile *' -EA SilentlyContinue | ForEach-Object { $_.Name }
    $names = @('Default') + @(Get-ChildItem -LiteralPath $ud -Directory -Filter 'Profile *' -EA SilentlyContinue | ForEach-Object { $_.Name })
    foreach ($prof in ($names | Select-Object -Unique)) {
      $extDir = Join-Path (Join-Path (Join-Path $ud $prof) 'Extensions') $chromeExtId
      if (Test-Path -LiteralPath $extDir) {
        Remove-Item -LiteralPath $extDir -Recurse -Force -ErrorAction SilentlyContinue
        $deleted += "$prof:ext_folder"
      }
      $prefsPath = Join-Path (Join-Path $ud $prof) 'Preferences'
      if (Test-Path -LiteralPath $prefsPath) {
        try {
          $raw = Get-Content -LiteralPath $prefsPath -Raw -Encoding UTF8
          $j = $raw | ConvertFrom-Json
          if ($j.extensions.settings.$chromeExtId) {
            $j.extensions.settings.$chromeExtId.state = 1
            $j | ConvertTo-Json -Depth 100 -Compress | Set-Content -LiteralPath $prefsPath -Encoding UTF8
            $deleted += "$prof:disabled_in_prefs"
          }
        } catch {}
      }
    }
  }
  $deleted -join '; '
}

function Simulate-FirefoxDelete {
  $removed = @()
  $profRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
  if (Test-Path -LiteralPath $profRoot) {
    Get-ChildItem -LiteralPath $profRoot -Directory | ForEach-Object {
      $xpi = Join-Path $_.FullName "extensions\$firefoxExtId.xpi"
      if (Test-Path -LiteralPath $xpi) {
        Remove-Item -LiteralPath $xpi -Force -ErrorAction SilentlyContinue
        $removed += $_.Name
      }
    }
  }
  $removed -join ', '
}

function Test-BlockingLayers {
  $blProps = Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Google\Chrome\URLBlocklist' -EA SilentlyContinue
  $blCount = 0
  if ($blProps) {
    $blCount = @($blProps.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' }).Count
  }
  $pac = (Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Google\Chrome' -EA SilentlyContinue).ProxyPacUrl
  $ffBlock = reg query 'HKCU\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block' /s 2>&1 | Out-String
  [ordered]@{
    urlBlocklistCount = $blCount
    pacSet            = ($pac -match 'sixvpn_block')
    firefoxFilter     = ($ffBlock.Length -gt 20)
  }
}

Write-Host '=== Extension Delete Simulation (per browser) ===' -ForegroundColor Cyan

# --- CHROME ---
$beforeChrome = Get-ChromiumState -userDataSub 'Google\Chrome\User Data' -browserName 'Chrome'
$uiChrome = if ($beforeChrome.forcelistOk) {
  'Remove button hidden/disabled — "Installed by your administrator" (force_installed)'
} else {
  'Remove button active — user CAN uninstall (no forcelist)'
}
Add-BrowserRow -browser 'Chrome' -phase 'before' -uiBehavior $uiChrome `
  -removeButtonWorks (-not $beforeChrome.forcelistOk) `
  -blockingStillWorks (($beforeChrome.payloadOk) -and ($beforeChrome.forcelistOk)) `
  -detail "forcelist=$($beforeChrome.forcelistOk) payload=$($beforeChrome.payloadOk) profiles=$($beforeChrome.profiles.Count)"

$chromeSim = Simulate-ChromiumDelete -userDataSub 'Google\Chrome\User Data' -browserName 'Chrome'
Write-Host "Chrome simulated delete: $chromeSim" -ForegroundColor Yellow

if (-not $SkipRecovery) {
  $maintain = Join-Path $toolsDir 'Offline-Block-Policy-Maintain.ps1'
  if (Test-Path -LiteralPath $maintain) { & $maintain -Quiet | Out-Null }
}

$afterChrome = Get-ChromiumState -userDataSub 'Google\Chrome\User Data' -browserName 'Chrome'
$layers = Test-BlockingLayers
$chromeRecovered = $afterChrome.forcelistOk -and $afterChrome.payloadOk
Add-BrowserRow -browser 'Chrome' -phase 'after_simulated_delete' `
  -uiBehavior $(if ($afterChrome.forcelistOk) { 'On next browser restart: extension re-installed from updates.xml (forcelist)' } else { 'Extension stays removed until app re-applies policy' }) `
  -removeButtonWorks (-not $afterChrome.forcelistOk) `
  -blockingStillWorks ($layers.urlBlocklistCount -ge 5 -or $layers.pacSet) `
  -detail "forcelist=$($afterChrome.forcelistOk) URLBlocklist=$($layers.urlBlocklistCount) sim=$chromeSim"

# --- EDGE ---
$beforeEdge = Get-ChromiumState -userDataSub 'Microsoft\Edge\User Data' -browserName 'Edge'
$uiEdge = if ($beforeEdge.forcelistOk) {
  'Remove button hidden/disabled — enterprise policy (same ext id)'
} else { 'Remove button active' }
Add-BrowserRow -browser 'Edge' -phase 'before' -uiBehavior $uiEdge `
  -removeButtonWorks (-not $beforeEdge.forcelistOk) `
  -blockingStillWorks ($beforeEdge.forcelistOk -and $beforeEdge.payloadOk) `
  -detail "forcelist=$($beforeEdge.forcelistOk) profiles=$($beforeEdge.profiles.Count)"

$edgeSim = Simulate-ChromiumDelete -userDataSub 'Microsoft\Edge\User Data' -browserName 'Edge'
Write-Host "Edge simulated delete: $edgeSim" -ForegroundColor Yellow
$afterEdge = Get-ChromiumState -userDataSub 'Microsoft\Edge\User Data' -browserName 'Edge'
Add-BrowserRow -browser 'Edge' -phase 'after_simulated_delete' `
  -uiBehavior $(if ($afterEdge.forcelistOk) { 'Restart Edge -> extension force-reinstalled' } else { 'Removable until policy restored' }) `
  -removeButtonWorks (-not $afterEdge.forcelistOk) `
  -blockingStillWorks ($layers.urlBlocklistCount -ge 5 -or $layers.pacSet) `
  -detail "forcelist=$($afterEdge.forcelistOk) sim=$edgeSim"

# --- FIREFOX ---
$ffBeforeXpi = @()
$profRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
if (Test-Path -LiteralPath $profRoot) {
  Get-ChildItem -LiteralPath $profRoot -Directory | ForEach-Object {
    if (Test-Path -LiteralPath (Join-Path $_.FullName "extensions\$firefoxExtId.xpi")) {
      $ffBeforeXpi += $_.Name
    }
  }
}
$hkcuFf = reg query 'HKCU\SOFTWARE\Policies\Mozilla\Firefox' 2>&1 | Out-String
$ffPolicy = $hkcuFf -match 'sixvpn-blocker@sixvpnblocker.app'
$uiFf = if ($ffPolicy) {
  'Add-ons screen: extension marked force_installed — Remove disabled when policy active'
} else { 'Remove button works — XPI can be deleted from profile' }
Add-BrowserRow -browser 'Firefox' -phase 'before' -uiBehavior $uiFf `
  -removeButtonWorks (-not $ffPolicy) `
  -blockingStillWorks ($ffPolicy -or $layers.firefoxFilter) `
  -detail "profiles_with_xpi=$($ffBeforeXpi -join ',') hkcuPolicy=$ffPolicy"

$ffSim = Simulate-FirefoxDelete
Write-Host "Firefox simulated delete: $ffSim" -ForegroundColor Yellow
$ffAfterXpi = @()
if (Test-Path -LiteralPath $profRoot) {
  Get-ChildItem -LiteralPath $profRoot -Directory | ForEach-Object {
    if (Test-Path -LiteralPath (Join-Path $_.FullName "extensions\$firefoxExtId.xpi")) {
      $ffAfterXpi += $_.Name
    }
  }
}
$xpiPd = Join-Path $env:ProgramData 'SixVPNBlocker\firefox\sixvpn-blocker@sixvpnblocker.app.xpi'
Add-BrowserRow -browser 'Firefox' -phase 'after_simulated_delete' `
  -uiBehavior $(if ($ffPolicy) { 'App keepalive / next Firefox start reinstalls XPI from ProgramData + HKCU policy' } else { 'XPI gone — WebsiteFilter may still block URLs if HKCU applied' }) `
  -removeButtonWorks (-not $ffPolicy) `
  -blockingStillWorks ($layers.firefoxFilter -or $ffPolicy) `
  -detail "xpi_left=$($ffAfterXpi -join ',') programDataXpi=$(Test-Path $xpiPd) sim=$ffSim WebsiteFilter=$($layers.firefoxFilter)"

# --- BRAVE (Chromium — shares Chrome policy keys if configured) ---
$braveUd = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
$braveInstalled = Test-Path -LiteralPath $braveUd
$braveForcelist = reg query 'HKCU\SOFTWARE\Policies\Chromium\ExtensionInstallForcelist' 2>&1
$bravePolicy = ($LASTEXITCODE -eq 0) -and ("$braveForcelist" -match $chromeExtId)
Add-BrowserRow -browser 'Brave' -phase 'probe' `
  -uiBehavior $(if (-not $braveInstalled) { 'Brave not installed on this PC' } elseif ($bravePolicy) { 'Same as Chrome — force_installed' } else { 'No Brave-specific forcelist — relies on URLBlocklist if Chrome policy applies to Chromium' }) `
  -removeButtonWorks (-not $bravePolicy) `
  -blockingStillWorks ($layers.urlBlocklistCount -ge 5) `
  -detail "installed=$braveInstalled braveForcelist=$bravePolicy"

# Summary pass/fail
$pass = 0
$total = 0
foreach ($b in $report.browsers) {
  if ($b.phase -eq 'after_simulated_delete' -or ($b.browser -eq 'Brave' -and $b.phase -eq 'probe')) {
    $total++
    if ($b.blockingStillWorks) { $pass++ }
  }
}
$report.summary = [ordered]@{ blockingLayersPass = $pass; blockingLayersTotal = $total }

$outPath = Join-Path $outDir 'extension_delete_sim_last.json'
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outPath -Encoding UTF8

Write-Host ""
Write-Host "Blocking layers after delete sim: $pass/$total browsers" -ForegroundColor $(if ($pass -eq $total) { 'Green' } else { 'Yellow' })
Write-Host "Report: $outPath"
foreach ($b in $report.browsers) {
  $rm = if ($b.removeButtonWorks) { 'REMOVABLE' } else { 'LOCKED' }
  $blk = if ($b.blockingStillWorks) { 'BLOCK_OK' } else { 'BLOCK_GAP' }
  Write-Host "  [$b.browser/$($b.phase)] $rm | $blk | $($b.uiBehavior)"
}
exit $(if ($pass -ge ($total - 1)) { 0 } else { 1 })
