# Deep live probes for 5 blocking layers (read-only + light network).
param([string]$TestVideoId = 'so-Rv8RlCUc')

$ErrorActionPreference = 'SilentlyContinue'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$live = [ordered]@{
  at = (Get-Date).ToString('o')
  layers = @()
}

function Add-Live($layer, $name, $ok, $detail, $liveBlock = $false) {
  $live.layers += [ordered]@{
    layer     = $layer
    name      = $name
    ok        = [bool]$ok
    detail    = $detail
    liveBlock = [bool]$liveBlock
  }
}

# L1: first managed hosts entry must sinkhole
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$testHost = $null
$inBlock = $false
if (Test-Path -LiteralPath $hostsPath) {
  Get-Content -LiteralPath $hostsPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -match '6 VPN Blocker BEGIN') { $inBlock = $true; return }
    if ($line -match '6 VPN Blocker END') { $inBlock = $false; return }
    if ($inBlock -and $line -match '^0\.0\.0\.0\s+(\S+)' -and -not $testHost) {
      $testHost = $Matches[1]
    }
  }
}
$l1Ok = $false
$l1Detail = 'no managed host'
if ($testHost) {
  try {
    $ip = [System.Net.Dns]::GetHostAddresses($testHost)[0].IPAddressToString
    $l1Ok = ($ip -eq '0.0.0.0')
    $l1Detail = "DNS $testHost -> $ip"
  } catch {
    $l1Ok = $true
    $l1Detail = "DNS $testHost -> lookup failed (blocked)"
  }
}
Add-Live 1 'hosts_dns_sinkhole' $l1Ok $l1Detail $l1Ok

# L2: rules API + youtube check
$l2Ok = $false
$ytBlocked = $false
foreach ($port in 17361, 17362, 17363) {
  try {
    $rules = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rules" -UseBasicParsing -TimeoutSec 3
    if ($rules.StatusCode -eq 200) {
      $l2Ok = $true
      $chk = Invoke-WebRequest -Uri "http://127.0.0.1:$port/youtube/check?v=$TestVideoId" -UseBasicParsing -TimeoutSec 5
      $j = $chk.Content | ConvertFrom-Json
      $ytBlocked = [bool]$j.blocked
      Add-Live 2 'extension_api_youtube' $l2Ok "port $port blocked=$($j.blocked) matched=$($j.matched)" $ytBlocked
      break
    }
  } catch {}
}
if (-not $l2Ok) { Add-Live 2 'extension_api_youtube' $false 'app API down' $false }

# L3: Chrome/Edge PAC policy + PAC file yt line
$l3Ok = $false
$pacDetail = ''
try {
  $chromePac = (Get-ItemProperty 'HKCU:\Software\Policies\Google\Chrome' -ErrorAction Stop).ProxyPacUrl
  $l3Ok = $chromePac -match 'sixvpn_block'
  $pacDetail = "chrome PAC=$chromePac"
} catch { $pacDetail = 'chrome policy PAC missing' }
$pacFile = Join-Path $outDir 'sixvpn_block.pac'
if (Test-Path $pacFile) {
  $t = Get-Content $pacFile -Raw
  if ($t -match [regex]::Escape($TestVideoId.ToLower())) {
    $l3Ok = $true
    $pacDetail += "; PAC has $TestVideoId"
  }
}
Add-Live 3 'pac_policy_file' $l3Ok $pacDetail $l3Ok

# L4: app heartbeat or API-derived patterns
$pat = 0
$wtLive = $false
$wtDetail = 'no heartbeat'
$hbPath = Join-Path $outDir 'window_title_guard.json'
if (Test-Path -LiteralPath $hbPath) {
  $hb = Get-Content -LiteralPath $hbPath -Raw | ConvertFrom-Json
  $pat = [int]$hb.patternCount
  $wtLive = [bool]$hb.active
  $wtDetail = "heartbeat active=$($hb.active) patterns=$pat tick=$($hb.tickSeconds)s"
} elseif ($l2Ok) {
  foreach ($port in 17361, 17362, 17363) {
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:$port/rules" -UseBasicParsing -TimeoutSec 2
      $j = $r.Content | ConvertFrom-Json
      $pat = (@($j.blockedYoutubeHandles).Count * 3) + @($j.blockedYoutubeVideoIds).Count
      $wtDetail = "api-derived patterns=$pat"
      break
    } catch {}
  }
}
Add-Live 4 'window_title_guard' ($pat -gt 0) $wtDetail ($wtLive -or ($pat -gt 0))

# L5: netsh active vs BAT pending
$netshOut = & netsh advfirewall firewall show rule name=all 2>$null | Out-String
$netshN = ([regex]::Matches($netshOut, 'SixVPN_Block_')).Count
$stateN = 0
$statePath = Join-Path $outDir 'firewall_rules.json'
if (Test-Path $statePath) {
  $stateN = (@(Get-Content $statePath -Raw | ConvertFrom-Json)).Count
}
$batReady = Test-Path (Join-Path $env:ProgramData 'SixVPNBlocker\apply_firewall_admin.cmd')
$l5Live = $netshN -gt 0
$l5Ok = $l5Live -or $batReady -or ($stateN -gt 0)
Add-Live 5 'firewall_netsh' $l5Ok "netsh=$netshN state=$stateN bat=$batReady" $l5Live

$live.passCount = @($live.layers | Where-Object { $_.ok }).Count
$live.liveBlockCount = @($live.layers | Where-Object { $_.liveBlock }).Count
$live.total = $live.layers.Count

$path = Join-Path $outDir 'five_layer_live_probe.json'
$live | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8

Write-Host "LIVE probe: $($live.passCount)/$($live.total) ok, $($live.liveBlockCount) actually blocking"
Write-Host "Report: $path"
foreach ($x in $live.layers) {
  $m = if ($x.liveBlock) { 'BLOCK' } elseif ($x.ok) { 'OK' } else { 'FAIL' }
  Write-Host "  [$m] L$($x.layer) $($x.name) - $($x.detail)"
}
exit $(if ($live.liveBlockCount -ge 2) { 0 } else { 1 })
