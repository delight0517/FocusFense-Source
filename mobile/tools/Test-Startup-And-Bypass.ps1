# Live probes: 4 startup-failure scenarios + 5 bypass holes.
# Writes %LOCALAPPDATA%\SixVPNBlocker\startup_bypass_test_last.json
param(
  [switch]$RunOfflineMaintain,
  [switch]$SimulateAppDown
)

$ErrorActionPreference = 'SilentlyContinue'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$report = [ordered]@{
  at               = (Get-Date).ToString('o')
  appRunning       = $false
  startupScenarios = @()
  bypassHoles      = @()
  maintainRan      = $false
  passCount        = 0
  totalCount       = 10
}

function Add-Case {
  param(
    [string]$section,
    [string]$id,
    [string]$title,
    [bool]$mitigated,
    [string]$detail,
    [string]$fix
  )
  $row = [ordered]@{
    id        = $id
    title     = $title
    mitigated = [bool]$mitigated
    detail    = $detail
    fix       = $fix
  }
  if ($section -eq 'startup') { $report.startupScenarios += $row }
  else { $report.bypassHoles += $row }
  if ($mitigated) { $report.passCount++ }
}

$appProc = Get-Process -Name six_clean_room -ErrorAction SilentlyContinue | Select-Object -First 1
$report.appRunning = $null -ne $appProc

if ($SimulateAppDown -and $appProc) {
  Write-Host 'Stopping app for offline probe...' -ForegroundColor Yellow
  Stop-Process -Id $appProc.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  $report.appRunning = $false
}

if ($RunOfflineMaintain) {
  $maintainPs = Join-Path $toolsDir 'Offline-Block-Policy-Maintain.ps1'
  if (Test-Path -LiteralPath $maintainPs) {
    & $maintainPs -Quiet | Out-Null
    $report.maintainRan = $true
  }
}

# --- 4 STARTUP FAILURE SCENARIOS ---

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runVal = (Get-ItemProperty -LiteralPath $runKey -Name 'SixVPNBlocker' -ErrorAction SilentlyContinue).SixVPNBlocker
$runOk = $false
$runDetail = 'Run value missing'
if ($runVal) {
  $exe = $runVal.Trim('"')
  $runOk = (Test-Path -LiteralPath $exe)
  $runDetail = "Run=$runVal exists=$runOk"
}
$watchdogTask = schtasks /Query /TN 'SixVPNBlockerWatchdog' /FO LIST 2>$null
$bootGuard = schtasks /Query /TN 'SixVPNBlockerBootGuard' /FO LIST 2>$null
$taskBackup = ($null -ne $watchdogTask) -or ($null -ne $bootGuard)
Add-Case -section startup -id s1_stale_exe -title 'S1: broken exe path in Run registry' -mitigated ($runOk -or $taskBackup) -detail $runDetail -fix 'Watchdog + BootGuard + repairAutostart'

$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$bytes = (Get-ItemProperty -LiteralPath $approvedKey -Name 'SixVPNBlocker' -ErrorAction SilentlyContinue).SixVPNBlocker
$approvedOk = ($null -eq $bytes) -or ($bytes[0] -eq 0x02)
$logonTask = schtasks /Query /TN 'SixVPNBlockerAutostart' /FO LIST 2>$null
Add-Case -section startup -id s2_startup_disabled -title 'S2: Task Manager disabled startup' -mitigated ($approvedOk -and $null -ne $logonTask) -detail "approved=$approvedOk logonTask=$($null -ne $logonTask)" -fix 'StartupApproved 0x02 + logon task 25s'

$chromeBl = 'HKCU:\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
$blCount = 0
$blWildcard = $false
if (Test-Path -LiteralPath $chromeBl) {
  $blProps = Get-ItemProperty -LiteralPath $chromeBl -ErrorAction SilentlyContinue
  if ($blProps) {
    $numericProps = @($blProps.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' })
    $blCount = $numericProps.Count
    $blWildcard = @($numericProps | Where-Object { "$($_.Value)" -eq '<*>' }).Count -gt 0
  }
}
$blPolicyOk = ($blCount -ge 5) -or $blWildcard
$pacFile = Join-Path $outDir 'sixvpn_block.pac'
$offlineTask = schtasks /Query /TN 'SixVPNBlockerOfflineGuard' /FO LIST 2>$null
$offlineOk = $blPolicyOk -and (Test-Path -LiteralPath $pacFile) -and ($null -ne $offlineTask)
Add-Case -section startup -id s3_crash_before_init -title 'S3: app crash before init' -mitigated $offlineOk -detail "URLBlocklist=$blCount wildcard=$blWildcard PAC=$([bool](Test-Path $pacFile)) offlineTask=$($null -ne $offlineTask)" -fix 'OfflineGuard repairs HKCU every 10 min'

$gapOk = ($null -ne $bootGuard) -and $blPolicyOk
Add-Case -section startup -id s4_logon_gap -title 'S4: boot gap before app starts' -mitigated $gapOk -detail "BootGuard=$($null -ne $bootGuard) URLBlocklist=$blCount wildcard=$blWildcard" -fix 'BootGuard 55s + persistent URLBlocklist/PAC'

# --- 5 BYPASS HOLES ---

Add-Case -section bypass -id b1_reg_tamper -title 'B1: URLBlocklist registry cleared' -mitigated $blPolicyOk -detail "entries=$blCount wildcard=$blWildcard" -fix 'OfflineGuard re-applies from policy snapshots'

$dohChrome = (Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Google\Chrome' -ErrorAction SilentlyContinue).DnsOverHttpsMode
$dohEdge = (Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Edge' -ErrorAction SilentlyContinue).DnsOverHttpsMode
$dohOk = ($dohChrome -eq 'off') -and ($dohEdge -eq 'off')
Add-Case -section bypass -id b2_secure_dns -title 'B2: Chrome Secure DNS DoH bypass' -mitigated $dohOk -detail "chrome=$dohChrome edge=$dohEdge" -fix 'DnsOverHttpsMode=off policy'

$secDns = $false
$secDetail = 'ok'
try {
  Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V' } | ForEach-Object {
    $addrs = @(Get-DnsClientServerAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    if ($addrs.Count -gt 1) {
      $secDns = $true
      $secDetail = "$($_.Name): $($addrs -join ',')"
    }
  }
} catch { $secDetail = $_.Exception.Message }
Add-Case -section bypass -id b3_secondary_dns -title 'B3: secondary DNS bypasses hosts sinkhole' -mitigated (-not $secDns) -detail $secDetail -fix 'UAC apply sets DNS 127.0.0.1 + NRPT + TCP53'

$pacUrl = (Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Google\Chrome' -ErrorAction SilentlyContinue).ProxyPacUrl
$pacOk = (Test-Path -LiteralPath $pacFile) -and ($pacUrl -match 'sixvpn_block')
Add-Case -section bypass -id b4_pac_tamper -title 'B4: PAC file or ProxyPacUrl deleted' -mitigated $pacOk -detail "file=$([bool](Test-Path $pacFile)) reg=$pacUrl" -fix 'OfflineGuard restores PAC URL'

$wdOk = ($null -ne $watchdogTask)
if (-not $report.appRunning) {
  $layerOk = $blPolicyOk -and $pacOk
  Add-Case -section bypass -id b5_kill_app -title 'B5: kill app stops process block' -mitigated ($layerOk -and $wdOk) -detail "URL/PAC=$layerOk watchdog=$wdOk" -fix 'Watchdog restarts app; URLBlocklist offline'
} else {
  Add-Case -section bypass -id b5_kill_app -title 'B5: kill app stops process block' -mitigated $wdOk -detail 'app running' -fix 'Watchdog restarts app; URLBlocklist offline'
}

$installExe = Join-Path $env:LOCALAPPDATA 'Programs\SixVPNBlocker\six_clean_room.exe'
$aliasExe = Join-Path $env:LOCALAPPDATA 'Programs\SixVPNBlocker\6VPNBlocker.exe'
$shards = @(
  (Join-Path $outDir 'backup\six_clean_room.exe'),
  (Join-Path $outDir 'cache\v1\runner_payload.exe'),
  (Join-Path $outDir 'policy_batch\install_shard_b.exe'),
  (Join-Path $outDir 'staged\search_mirror.exe')
)
$authFile = Join-Path $outDir 'removal_authorized_v1.json'
$removalOk = $false
if (Test-Path -LiteralPath $authFile) {
  try {
    $auth = Get-Content -LiteralPath $authFile -Raw | ConvertFrom-Json
    $bootMs = [uint64]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMilliseconds
    if ($auth.bootTickMs -and $bootMs -ge [uint64]$auth.bootTickMs) { $removalOk = $true }
  } catch {}
}
$shardCount = @($shards | Where-Object { Test-Path -LiteralPath $_ }).Count
$allPresent = (Test-Path -LiteralPath $installExe) -and (Test-Path -LiteralPath $aliasExe) -and ($shardCount -eq $shards.Count)
$manualDeleteMitigated = $removalOk -or $allPresent
Add-Case -section bypass -id b6_manual_uninstall -title 'B6: partial manual delete (exe/alias/shards)' -mitigated $manualDeleteMitigated -detail "install=$([bool](Test-Path $installExe)) alias=$([bool](Test-Path $aliasExe)) shards=$shardCount/$($shards.Count) removalAuth=$removalOk" -fix '4 backup shards + alias + Repair-Install-Integrity + 30s watchdog'

try {
  $ip = [System.Net.Dns]::GetHostAddresses('youtube.com')[0].IPAddressToString
  $ytSink = ($ip -eq '0.0.0.0' -or $ip -eq '127.0.0.1' -or $ip -eq '127.0.0.2')
  $report.youtubeDns = [ordered]@{ sinkholed = $ytSink; ip = $ip }
} catch {
  $report.youtubeDns = [ordered]@{ sinkholed = $true; ip = 'lookup_failed' }
}

$outPath = Join-Path $outDir 'startup_bypass_test_last.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outPath -Encoding UTF8

Write-Host ""
Write-Host "Startup+Bypass test: $($report.passCount)/$($report.totalCount) mitigated" -ForegroundColor $(if ($report.passCount -eq $report.totalCount) { 'Green' } else { 'Yellow' })
Write-Host "Report: $outPath"
foreach ($s in $report.startupScenarios) {
  $mark = if ($s.mitigated) { 'PASS' } else { 'FAIL' }
  Write-Host "  [$mark] $($s.id): $($s.title)"
}
foreach ($b in $report.bypassHoles) {
  $mark = if ($b.mitigated) { 'PASS' } else { 'FAIL' }
  Write-Host "  [$mark] $($b.id): $($b.title)"
}
exit $(if ($report.passCount -eq $report.totalCount) { 0 } else { 1 })
