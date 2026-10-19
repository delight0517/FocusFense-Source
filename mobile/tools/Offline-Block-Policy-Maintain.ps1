# HKCU-only policy repair — runs without UAC while the app is closed.
# Re-applies URLBlocklist, Secure DNS off, PAC URL, extension forcelist, StartupApproved.
param([switch]$Quiet)

$ErrorActionPreference = 'SilentlyContinue'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$report = [ordered]@{
  at      = (Get-Date).ToString('o')
  actions = @()
  ok      = $true
}

function Log-Action([string]$name, [bool]$ok, [string]$detail) {
  $report.actions += [ordered]@{ name = $name; ok = $ok; detail = $detail }
  if (-not $ok) { $report.ok = $false }
  if (-not $Quiet) {
    $c = if ($ok) { 'Green' } else { 'Yellow' }
    Write-Host "[$name] $detail" -ForegroundColor $c
  }
}

# --- URLBlocklist (from last batch snapshot) ---
$patternsJson = Join-Path $outDir 'policy_batch\url_blocklist_patterns.json'
$applyPs = Join-Path $outDir 'policy_batch\apply_url_blocklist.ps1'
$chromeBl = 'HKCU:\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
$needBlocklist = $true
try {
  if (Test-Path -LiteralPath $chromeBl) {
    $blProps = Get-ItemProperty -LiteralPath $chromeBl -ErrorAction Stop
    $cnt = @($blProps.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' }).Count
    if ($cnt -ge 5) { $needBlocklist = $false }
  }
} catch { $needBlocklist = $true }

if ($needBlocklist -and (Test-Path -LiteralPath $patternsJson) -and (Test-Path -LiteralPath $applyPs)) {
  $pr = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', $applyPs, '-PatternsJson', $patternsJson
  ) -Wait -PassThru -WindowStyle Hidden
  Log-Action 'url_blocklist_reapply' ($pr.ExitCode -eq 0) "exit=$($pr.ExitCode)"
} else {
  Log-Action 'url_blocklist_reapply' (-not $needBlocklist) $(if ($needBlocklist) { 'patterns missing' } else { "entries ok" })
}

# --- Secure DNS off (DoH bypass hole) ---
foreach ($pair in @(
    @{ Root = 'HKCU:\SOFTWARE\Policies\Google\Chrome'; Name = 'Chrome' },
    @{ Root = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'Edge' }
  )) {
  try {
    if (-not (Test-Path -LiteralPath $pair.Root)) {
      New-Item -Path $pair.Root -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $pair.Root -Name 'BuiltInDnsClientEnabled' -Value 0 -Type DWord -Force
    Set-ItemProperty -LiteralPath $pair.Root -Name 'DnsOverHttpsMode' -Value 'off' -Type String -Force
    Log-Action "doh_off_$($pair.Name)" $true 'DnsOverHttpsMode=off'
  } catch {
    Log-Action "doh_off_$($pair.Name)" $false $_.Exception.Message
  }
}

# --- PAC URL (registry tamper hole) ---
$pacFile = Join-Path $outDir 'sixvpn_block.pac'
if (Test-Path -LiteralPath $pacFile) {
  $pacUrl = 'file:///' + ($pacFile -replace '\\', '/')
  foreach ($root in @(
      'HKCU:\SOFTWARE\Policies\Google\Chrome',
      'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
    )) {
    try {
      if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -Force | Out-Null }
      $cur = (Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue).ProxyPacUrl
      if ($cur -ne $pacUrl) {
        Set-ItemProperty -LiteralPath $root -Name 'ProxyPacUrl' -Value $pacUrl -Type String -Force
        Log-Action 'pac_url' $true "restored $root"
      } else {
        Log-Action 'pac_url' $true 'already set'
      }
    } catch {
      Log-Action 'pac_url' $false $_.Exception.Message
    }
  }
} else {
  Log-Action 'pac_url' $false 'pac file missing'
}

# --- Extension force_installed (HKCU — Chrome/Edge/Chromium, no UAC) ---
$extId = 'popjkofklmidngceakpcokopghehjngo'
$firefoxExtId = 'sixvpn-blocker@sixvpnblocker.app'
$chromeExt = Join-Path $outDir 'chrome_blocker'
if (Test-Path -LiteralPath (Join-Path $chromeExt 'updates.xml')) {
  $updateUrl = 'file:///' + ($chromeExt -replace '\\', '/') + '/updates.xml'
  $forcelistVal = "$extId;$updateUrl"
  $settingsJson = "{`"$extId`":{`"installation_mode`":`"force_installed`",`"toolbar_pin`":`"force_pinned`",`"update_url`":`"$updateUrl`",`"incognito`":`"allowed`",`"override_update_url`":true}}"
  foreach ($root in @(
      'HKCU:\SOFTWARE\Policies\Google\Chrome',
      'HKCU:\SOFTWARE\Policies\Microsoft\Edge',
      'HKCU:\SOFTWARE\Policies\Microsoft\EdgeBeta',
      'HKCU:\SOFTWARE\Policies\Microsoft\EdgeDev',
      'HKCU:\SOFTWARE\Policies\Chromium'
    )) {
    try {
      if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -Force | Out-Null }
      Set-ItemProperty -LiteralPath $root -Name 'ExtensionSettings' -Value $settingsJson -Type String -Force
      $fl = Join-Path $root 'ExtensionInstallForcelist'
      if (-not (Test-Path -LiteralPath $fl)) { New-Item -Path $fl -Force | Out-Null }
      Set-ItemProperty -LiteralPath $fl -Name '1' -Value $forcelistVal -Type String -Force
      # 2026-06-19: User-installable extensions kept OPEN (user request).
      # Removed: ExtensionDeveloperModeAvailability=0, BlockExternalExtensions=1,
      # and the ExtensionInstallAllowlist single-entry. force_installed in
      # ExtensionSettings + the forcelist above keep the 6VPN ext locked on
      # without blocking the user's other extensions. Active cleanup of the
      # legacy registry values happens once at app startup.
      Remove-ItemProperty -LiteralPath $root -Name 'ExtensionDeveloperModeAvailability' -ErrorAction SilentlyContinue
      Remove-ItemProperty -LiteralPath $root -Name 'BlockExternalExtensions' -ErrorAction SilentlyContinue
      $al = Join-Path $root 'ExtensionInstallAllowlist'
      if (Test-Path -LiteralPath $al) {
        Remove-Item -LiteralPath $al -Recurse -Force -ErrorAction SilentlyContinue
      }
      Log-Action 'chromium_ext_policy' $true "ok $root"
    } catch {
      Log-Action 'chromium_ext_policy' $false $_.Exception.Message
    }
  }
}

# Firefox force_installed (HKCU)
$xpiPd = Join-Path $env:ProgramData 'SixVPNBlocker\firefox\sixvpn-blocker@sixvpnblocker.app.xpi'
if (Test-Path -LiteralPath $xpiPd) {
  $xpiUrl = 'file:///' + ($xpiPd -replace '\\', '/')
  $ffSettings = "{`"$firefoxExtId`":{`"installation_mode`":`"force_installed`",`"install_url`":`"$xpiUrl`",`"blocked_install_message`":`"6 VPN Blocker protection is locked by policy.`"}}"
  try {
    $ffRoot = 'HKCU:\SOFTWARE\Policies\Mozilla\Firefox'
    if (-not (Test-Path -LiteralPath $ffRoot)) { New-Item -Path $ffRoot -Force | Out-Null }
    Set-ItemProperty -LiteralPath $ffRoot -Name 'ExtensionSettings' -Value $ffSettings -Type String -Force
    Set-ItemProperty -LiteralPath $ffRoot -Name 'DisablePrivateBrowsing' -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath $ffRoot -Name 'PrivateBrowsingModeAvailability' -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath $ffRoot -Name 'DisableDeveloperTools' -Value 1 -Type DWord -Force
    $ffInstall = Join-Path $ffRoot 'Extensions\Install'
    $ffLocked = Join-Path $ffRoot 'Extensions\Locked'
    if (-not (Test-Path -LiteralPath $ffInstall)) { New-Item -Path $ffInstall -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $ffLocked)) { New-Item -Path $ffLocked -Force | Out-Null }
    Set-ItemProperty -LiteralPath $ffInstall -Name '1' -Value $xpiUrl -Type String -Force
    Set-ItemProperty -LiteralPath $ffLocked -Name '1' -Value $firefoxExtId -Type String -Force
    Log-Action 'firefox_ext_policy' $true 'ExtensionSettings force_installed + locked'
  } catch {
    Log-Action 'firefox_ext_policy' $false $_.Exception.Message
  }
}

# --- StartupApproved repair (Task Manager disabled autostart hole) ---
$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
try {
  if (-not (Test-Path -LiteralPath $approvedKey)) {
    New-Item -Path $approvedKey -Force | Out-Null
  }
  $bytes = (Get-ItemProperty -LiteralPath $approvedKey -Name 'SixVPNBlocker' -ErrorAction SilentlyContinue).SixVPNBlocker
  $enabled = ($null -eq $bytes) -or ($bytes[0] -eq 0x02)
  if (-not $enabled) {
    Set-ItemProperty -LiteralPath $approvedKey -Name 'SixVPNBlocker' -Value ([byte[]](0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)) -Type Binary -Force
    Log-Action 'startup_approved' $true 're-enabled SixVPNBlocker'
  } else {
    Log-Action 'startup_approved' $true 'already enabled'
  }
} catch {
  Log-Action 'startup_approved' $false $_.Exception.Message
}

# --- Install integrity (multi-shard; partial delete -> full restore) ---
$repairPs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Repair-Install-Integrity.ps1'
if (Test-Path -LiteralPath $repairPs) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $repairPs -Quiet 2>&1 | Out-Null
  Log-Action 'install_integrity_repair' $true 'Repair-Install-Integrity.ps1'
} else {
  Log-Action 'install_integrity_repair' $false 'script missing'
}

$reportPath = Join-Path $outDir 'offline_guard_last.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
if (-not $Quiet) { Write-Host "Report: $reportPath" -ForegroundColor Cyan }
exit $(if ($report.ok) { 0 } else { 1 })
