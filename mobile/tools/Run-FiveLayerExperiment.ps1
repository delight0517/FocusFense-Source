# 6 VPN Blocker - headless 5-layer experiment (no Flutter UI).
param([switch]$SyncFirewall)

$ErrorActionPreference = 'SilentlyContinue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($SyncFirewall) {
  & (Join-Path $scriptDir 'Sync-FiveLayerFirewall.ps1') -Quiet
}

$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$report = @{
  at        = (Get-Date).ToString('o')
  probes    = @()
  passCount = 0
}

function Add-Probe($layer, $name, $ok, $detail) {
  $script:report.probes += @{
    layer  = $layer
    name   = $name
    ok     = [bool]$ok
    detail = $detail
  }
  if ($ok) { $script:report.passCount++ }
}

# Layer 1: hosts marker + first managed domain sinkhole
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$hostsContent = ''
$testHost = $null
$inBlock = $false
if (Test-Path -LiteralPath $hostsPath) {
  $hostsContent = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction SilentlyContinue
  Get-Content -LiteralPath $hostsPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -match '6 VPN Blocker BEGIN') { $inBlock = $true; return }
    if ($line -match '6 VPN Blocker END') { $inBlock = $false; return }
    if ($inBlock -and $line -match '^0\.0\.0\.0\s+(\S+)' -and -not $testHost) {
      $testHost = $Matches[1]
    }
  }
}
$hostsOk = $hostsContent -match '6 VPN Blocker BEGIN'
$dnsDetail = 'marker only'
$dnsBlocked = $false
if ($testHost) {
  try {
    $ip = [System.Net.Dns]::GetHostAddresses($testHost)[0].IPAddressToString
    $dnsBlocked = ($ip -eq '0.0.0.0')
    $dnsDetail = "DNS $testHost -> $ip"
  } catch {
    $dnsBlocked = $true
    $dnsDetail = "DNS $testHost -> lookup failed (sinkhole)"
  }
}
Add-Probe 1 'hosts' ($hostsOk -and ($dnsBlocked -or -not $testHost)) "$dnsDetail"

# Layer 2: rules API + extension payload
$apiOk = $false
$apiDetail = 'app not running'
$rulesJson = $null
foreach ($port in 17361, 17362, 17363) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rules" -UseBasicParsing -TimeoutSec 3
    if ($r.StatusCode -eq 200) {
      $apiOk = $true
      $rulesJson = $r.Content | ConvertFrom-Json
      $h = @($rulesJson.blockedYoutubeHandles).Count
      $v = @($rulesJson.blockedYoutubeVideoIds).Count
      $apiDetail = "API :$port handles=$h videos=$v domains=$(@($rulesJson.blockedDomains).Count)"
      break
    }
  } catch {}
}
Add-Probe 2 'extension_api' $apiOk $apiDetail

# Layer 3: PAC registry + youtube video in PAC file
$pacOk = $false
$pacDetail = 'PAC not registered'
$pacFile = Join-Path $outDir 'sixvpn_block.pac'
try {
  $acu = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name AutoConfigURL -ErrorAction Stop).AutoConfigURL
  if ($acu -match 'sixvpn_block\.pac') {
    $pacOk = $true
    $pacDetail = 'registry OK'
  }
} catch {}
if (Test-Path -LiteralPath $pacFile) {
  $pacText = Get-Content -LiteralPath $pacFile -Raw
  if ($pacText -match 'so-rv8rlcuc') {
    $pacOk = $true
    $pacDetail = 'PAC has so-Rv8RlCUc block line'
  } elseif ($pacOk) {
    $pacDetail = 'registry OK; yt vid line not found'
  }
}
Add-Probe 3 'pac_proxy' $pacOk $pacDetail

# Layer 4: window title patterns (from rules)
$wtOk = $false
$wtDetail = 'no patterns'
if ($rulesJson) {
  $pat = 0
  foreach ($h in @($rulesJson.blockedYoutubeHandles)) { if ($h) { $pat += 3 } }
  foreach ($v in @($rulesJson.blockedYoutubeVideoIds)) { if ($v) { $pat++ } }
  $wtOk = $pat -gt 0
  $wtDetail = "would watch $pat title patterns (5s tick in app)"
}
Add-Probe 4 'window_title' $wtOk $wtDetail

# Layer 5: firewall
$fwPath = Join-Path $outDir 'firewall_rules.json'
$fwBat = Join-Path $env:ProgramData 'SixVPNBlocker\apply_firewall_admin.cmd'
$fwOk = $false
$fwDetail = 'no rules — run with -SyncFirewall'
if (Test-Path -LiteralPath $fwPath) {
  $ips = Get-Content -LiteralPath $fwPath -Raw | ConvertFrom-Json
  if ($ips.Count -gt 0) {
    $fwOk = $true
    $fwDetail = "state IPs=$($ips.Count)"
  }
}
if (Test-Path -LiteralPath $fwBat) {
  $fwOk = $true
  $fwDetail = "admin BAT ready; $fwDetail"
}
$netshOut = & netsh advfirewall firewall show rule name=all 2>$null | Out-String
$netshCount = ([regex]::Matches($netshOut, 'SixVPN_Block_')).Count
if ($netshCount -gt 0) {
  $fwOk = $true
  $fwDetail = "LIVE netsh=$netshCount; $fwDetail"
} else {
  $fwDetail = "pending UAC/BAT (netsh=0); $fwDetail"
}
Add-Probe 5 'firewall' $fwOk $fwDetail

# Optional deep live probe
$liveScript = Join-Path $scriptDir 'Test-FiveLayerLive.ps1'
if (Test-Path -LiteralPath $liveScript) {
  & $liveScript -TestVideoId 'so-Rv8RlCUc' | Out-Null
  $livePath = Join-Path $outDir 'five_layer_live_probe.json'
  if (Test-Path -LiteralPath $livePath) {
    $report.liveProbe = Get-Content -LiteralPath $livePath -Raw | ConvertFrom-Json
  }
}

# YouTube API samples
if ($apiOk) {
  foreach ($port in 17361, 17362, 17363) {
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/youtube/check?v=so-Rv8RlCUc" -UseBasicParsing -TimeoutSec 5
      $report.youtubeSample = ($r.Content | ConvertFrom-Json)
      break
    } catch {}
  }
}

$report.total = $report.probes.Count
$jsonPath = Join-Path $outDir 'five_layer_experiment_shell.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

Write-Host "5-layer experiment: $($report.passCount)/$($report.total) pass"
Write-Host "Report: $jsonPath"
foreach ($p in $report.probes) {
  $mark = if ($p.ok) { 'OK' } else { 'FAIL' }
  Write-Host "  [$mark] layer$($p.layer) $($p.name) - $($p.detail)"
}
if ($report.youtubeSample) {
  Write-Host "  YouTube API: blocked=$($report.youtubeSample.blocked) matched=$($report.youtubeSample.matched)"
}
exit $(if ($report.passCount -ge 4) { 0 } else { 1 })
