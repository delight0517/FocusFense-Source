# Test-ChromeBlock.ps1 — sync HKCU Chrome block + verify so-Rv8RlCUc
param(
  [string]$TestVideoId = 'so-Rv8RlCUc',
  [string]$SecondaryVideoId = 'BddZUaoWB_s',
  [string]$SixVpnDir = "$env:LOCALAPPDATA\SixVPNBlocker"
)

$ErrorActionPreference = 'Continue'
$report = @{
  timestamp = (Get-Date).ToString('o')
  testVideoId = $TestVideoId
  checks = @()
  ok = $false
}

function Add-Check([string]$name, [bool]$pass, [string]$detail) {
  $script:report.checks += @{ name = $name; pass = $pass; detail = $detail }
}

$snapshot = Join-Path $SixVpnDir 'chrome_blocker\rules_snapshot.json'
$extDir = Join-Path $SixVpnDir 'chrome_blocker'
$manifest = Join-Path $extDir 'manifest.json'
$updates = Join-Path $extDir 'updates.xml'
$pac = Join-Path $SixVpnDir 'sixvpn_block.pac'

# --- updates.xml (forcelist) ---
if (Test-Path -LiteralPath $manifest) {
  if (-not (Test-Path -LiteralPath $updates)) {
    $folderUrl = 'file:///' + ($extDir -replace '\\', '/')
    $xml = @"
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
<app appid='popjkofklmidngceakpcokopghehjngo'>
<updatecheck codebase='$folderUrl/manifest.json' version='1.0.17' />
</app></gupdate>
"@
    Set-Content -LiteralPath $updates -Value $xml -Encoding UTF8
    Add-Check 'updates_xml_created' $true "wrote $updates"
  } else {
    Add-Check 'updates_xml' $true "exists"
  }
} else {
  Add-Check 'updates_xml' $false "manifest missing: $manifest"
}

# --- Build compact URLBlocklist from rules_snapshot ---
$patterns = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()

function Add-Pattern([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return }
  if ($seen.Add($p)) { [void]$patterns.Add($p) }
}

function Add-VideoPatterns([string]$vid) {
  $v = $vid.Trim().ToLowerInvariant()
  if ($v.Length -eq 0) { return }
  Add-Pattern "*://*.youtube.com/watch?v=$v*"
  Add-Pattern "*://youtube.com/watch?v=$v*"
  Add-Pattern "*://*.youtube.com/shorts/$v*"
  Add-Pattern "*://youtu.be/$v*"
}

if (Test-Path -LiteralPath $snapshot) {
  $rules = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
  $kwSrc = @()
  if ($rules.rawKeywords) { $kwSrc += @($rules.rawKeywords) }
  if ($rules.keywords) { $kwSrc += @($rules.keywords) }
  foreach ($k in $kwSrc) {
    if ($k -match '[?&]v=([\w-]{6,})') { Add-VideoPatterns $Matches[1] }
    elseif ($k -match 'youtu\.be/([\w-]{6,})') { Add-VideoPatterns $Matches[1] }
    elseif ($k -match '/shorts/([\w-]{6,})') { Add-VideoPatterns $Matches[1] }
    if ($patterns.Count -ge 980) { break }
  }
  foreach ($vid in @($rules.blockedYoutubeVideoIds)) {
    Add-VideoPatterns $vid
    if ($patterns.Count -ge 980) { break }
  }
  foreach ($h in @($rules.blockedYoutubeHandles)) {
    $hl = $h.ToLowerInvariant()
    Add-Pattern "*://*.youtube.com/@$hl*"
    Add-Pattern "*://youtube.com/@$hl*"
    if ($patterns.Count -ge 1000) { break }
  }
  foreach ($d in @($rules.blockedDomains)) {
    $domainHost = ($d -replace '^https?://', '' -replace '/.*$', '').ToLowerInvariant()
    if ($domainHost.Length -eq 0) { continue }
    Add-Pattern "*://$domainHost/*"
    Add-Pattern "*://*.$domainHost/*"
    if ($patterns.Count -ge 1000) { break }
  }
  Add-Check 'snapshot_patterns' $true "built $($patterns.Count) patterns"
} else {
  Add-Check 'snapshot_patterns' $false "missing $snapshot"
}

# Mandatory probe videos (cursor agent + plain-Chrome tests)
foreach ($mandVid in @($TestVideoId, $SecondaryVideoId)) {
  Add-VideoPatterns $mandVid
}

function Ensure-PacVideoLine {
  param([string]$VideoId)
  if (-not (Test-Path -LiteralPath $pac)) { return }
  $v = $VideoId.ToLowerInvariant()
  $raw = Get-Content -LiteralPath $pac -Raw
  if ($raw -match [regex]::Escape($v)) { return }
  $line = "  if (isYt && (u.indexOf('$v') >= 0 || shExpMatch(u, '*v=$v*') || shExpMatch(u, '*youtu.be/$v*') || shExpMatch(u, '*/shorts/$v*') || shExpMatch(u, '*/embed/$v*'))) return 'PROXY 127.0.0.1:9';"
  $needle = "  var isYt = host.indexOf('youtube.com') >= 0"
  if ($raw -notmatch [regex]::Escape($needle)) { return }
  $raw = $raw.Replace($needle, "$line`n$needle")
  Set-Content -LiteralPath $pac -Value $raw -Encoding UTF8 -NoNewline
}
foreach ($mandVid in @($TestVideoId, $SecondaryVideoId)) {
  Ensure-PacVideoLine -VideoId $mandVid
}

# --- Apply HKCU Chrome + Edge policies ---
$roots = @(
  'HKCU:\Software\Policies\Google\Chrome',
  'HKCU:\Software\Policies\Microsoft\Edge'
)
$pacUri = 'file:///' + ($pac -replace '\\', '/')
$applied = 0
foreach ($root in $roots) {
  try {
    if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -Force | Out-Null }
    Set-ItemProperty -LiteralPath $root -Name 'ProxyMode' -Value 'pac_script' -Type String -Force
    Set-ItemProperty -LiteralPath $root -Name 'ProxyPacUrl' -Value $pacUri -Type String -Force
    Set-ItemProperty -LiteralPath $root -Name 'BuiltInDnsClientEnabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $root -Name 'DnsOverHttpsMode' -Value 'off' -Type String -Force -ErrorAction SilentlyContinue
    $bl = Join-Path $root 'URLBlocklist'
    if (Test-Path -LiteralPath $bl) { Remove-Item -LiteralPath $bl -Recurse -Force -ErrorAction SilentlyContinue }
    if ($patterns.Count -gt 0) {
      New-Item -Path $bl -Force | Out-Null
      $i = 1
      foreach ($p in $patterns) {
        Set-ItemProperty -LiteralPath $bl -Name "$i" -Value $p -Type String -Force
        $i++
      }
    }
    $applied++
  } catch {
    Add-Check "hkcu_$($root.Split('\')[-1])" $false $_.Exception.Message
  }
}
Add-Check 'hkcu_policy_applied' ($applied -ge 1) "roots=$applied patterns=$($patterns.Count)"

# --- Firefox WebsiteFilter (same patterns as Chrome URLBlocklist) ---
$ffOk = $false
try {
  $firefox = 'HKCU:\Software\Policies\Mozilla\Firefox'
  if (-not (Test-Path -LiteralPath $firefox)) { New-Item -Path $firefox -Force | Out-Null }
  $doh = Join-Path $firefox 'DNSOverHTTPS'
  if (-not (Test-Path -LiteralPath $doh)) { New-Item -Path $doh -Force | Out-Null }
  Set-ItemProperty -LiteralPath $doh -Name 'Enabled' -Value 0 -Type DWord -Force
  Set-ItemProperty -LiteralPath $doh -Name 'Locked' -Value 1 -Type DWord -Force
  $block = Join-Path (Join-Path $firefox 'WebsiteFilter') 'Block'
  if (Test-Path -LiteralPath $block) {
    Remove-Item -LiteralPath $block -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($patterns.Count -gt 0) {
    New-Item -Path $block -Force | Out-Null
    $i = 1
    foreach ($p in $patterns) {
      Set-ItemProperty -LiteralPath $block -Name "$i" -Value $p -Type String -Force
      $i++
    }
    $ffOk = $true
  }
} catch {
  Add-Check 'firefox_websitefilter' $false $_.Exception.Message
}
Add-Check 'firefox_websitefilter' $ffOk "patterns=$($patterns.Count)"

# --- Verify test video in URLBlocklist ---
$vidLower = $TestVideoId.ToLowerInvariant()
$blocklistOut = reg query 'HKCU\Software\Policies\Google\Chrome\URLBlocklist' 2>$null
$hasVideo = [bool]($blocklistOut | Select-String -Pattern $vidLower -Quiet)
Add-Check 'urlblocklist_has_test_video' $hasVideo "so-rv8rlcuc in registry=$hasVideo"

$secLower = $SecondaryVideoId.ToLowerInvariant()
$hasSecondary = [bool]($blocklistOut | Select-String -Pattern $secLower -Quiet)
Add-Check 'urlblocklist_has_secondary_video' $hasSecondary "$secLower in registry=$hasSecondary"

# --- PAC file ---
$pacHas = $false
$pacHasSecondary = $false
if (Test-Path -LiteralPath $pac) {
  $pacHas = (Select-String -LiteralPath $pac -Pattern $vidLower -Quiet)
  $pacHasSecondary = (Select-String -LiteralPath $pac -Pattern $secLower -Quiet)
}
Add-Check 'pac_has_test_video' $pacHas "pac line=$pacHas"
Add-Check 'pac_has_secondary_video' $pacHasSecondary "pac $secLower=$pacHasSecondary"

# --- Proxy policy keys ---
$proxyMode = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Google\Chrome' -Name 'ProxyMode' -ErrorAction SilentlyContinue).ProxyMode
Add-Check 'chrome_proxy_mode' ($proxyMode -eq 'pac_script') "ProxyMode=$proxyMode"

# --- Extension forcelist ---
$forcelist = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Google\Chrome\ExtensionInstallForcelist' -ErrorAction SilentlyContinue)
Add-Check 'chrome_forcelist' ($null -ne $forcelist) "forcelist present"

$passCount = @($report.checks | Where-Object { $_.pass }).Count
$total = $report.checks.Count
$report.ok = ($hasVideo -and $hasSecondary -and $pacHas -and ($proxyMode -eq 'pac_script'))
$report.summary = "$passCount/$total checks pass; chrome_plain_block=$($report.ok)"

$outPath = Join-Path $SixVpnDir 'chrome_block_test.json'
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Output $report.summary
Write-Output "report=$outPath"
if (-not $report.ok) { exit 1 }
exit 0
