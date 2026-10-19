# Verifies apex site block across layers + 3 browsers (registry/PAC/hosts, no UI).
param(
  [string]$ApexHost = 'pornhub.com',
  [string]$SixVpnDir = "$env:LOCALAPPDATA\SixVPNBlocker"
)

$ErrorActionPreference = 'Continue'
$pass = 0
$fail = 0
$report = [ordered]@{
  at = (Get-Date).ToString('o')
  apexHost = $ApexHost
  checks = @()
}

function Add-Check([string]$name, [bool]$ok, [string]$detail) {
  $script:report.checks += [ordered]@{ name = $name; pass = $ok; detail = $detail }
  if ($ok) { $script:pass++ ; Write-Host "[OK] $name — $detail" -ForegroundColor Green }
  else { $script:fail++ ; Write-Host "[FAIL] $name — $detail" -ForegroundColor Red }
}

Write-Host "=== Test-SiteApexBlock ($ApexHost) ===" -ForegroundColor Cyan

# L1 hosts DNS
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$hostsHit = $false
if (Test-Path -LiteralPath $hostsPath) {
  $hostsHit = [bool](Select-String -LiteralPath $hostsPath -Pattern "0\.0\.0\.0\s+$([regex]::Escape($ApexHost))(\s|$)" -Quiet)
}
$dnsIp = $null
try {
  $dnsIp = [System.Net.Dns]::GetHostAddresses($ApexHost)[0].IPAddressToString
} catch { $dnsIp = 'lookup_failed' }
$dnsBlocked = ($dnsIp -eq '0.0.0.0') -or ($dnsIp -eq 'lookup_failed')
Add-Check 'L1_hosts_line' $hostsHit "managed_hosts_has_apex=$hostsHit"
Add-Check 'L1_dns_sinkhole' $dnsBlocked "DNS $ApexHost -> $dnsIp"

# L2 rules API
$apiOk = $false
$apiDetail = 'app API down'
foreach ($port in 17361, 17362, 17363) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rules" -UseBasicParsing -TimeoutSec 4
    if ($r.StatusCode -eq 200) {
      $j = $r.Content | ConvertFrom-Json
      $doms = @($j.blockedDomains)
      $apiOk = $doms -contains $ApexHost
      $apiDetail = "port $port blockedDomains has $ApexHost=$apiOk"
      break
    }
  } catch {}
}
Add-Check 'L2_rules_api' $apiOk $apiDetail

# L3 PAC
$pacFile = Join-Path $SixVpnDir 'sixvpn_block.pac'
$pacOk = $false
if (Test-Path -LiteralPath $pacFile) {
  $pacOk = [bool](Select-String -LiteralPath $pacFile -Pattern "dnsDomainIs\(host, '$([regex]::Escape($ApexHost))'" -Quiet)
}
$chromePac = (reg query 'HKCU\SOFTWARE\Policies\Google\Chrome' /v ProxyPacUrl 2>&1 | Out-String)
$edgePac = (reg query 'HKCU\SOFTWARE\Policies\Microsoft\Edge' /v ProxyPacUrl 2>&1 | Out-String)
$pacPolicy = ($chromePac -match 'sixvpn_block') -and ($edgePac -match 'sixvpn_block')
Add-Check 'L3_pac_file' $pacOk "pac_has_apex=$pacOk"
Add-Check 'L3_pac_policy' $pacPolicy "chrome+edge PAC policy"

# L4 URLBlocklist — Chrome / Edge / Firefox
$pat = "*://$ApexHost/*"
function Test-UrlBlocklist([string]$regPath, [string]$label) {
  $hit = $false
  $out = reg query $regPath 2>&1 | Out-String
  if ($out -match [regex]::Escape($pat)) { $hit = $true }
    elseif ($out -match [regex]::Escape("*://*.$ApexHost/*")) { $hit = $true }
  Add-Check "L4_${label}_urlblocklist" $hit "pattern_in_$label"
}

Test-UrlBlocklist 'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist' 'chrome'
Test-UrlBlocklist 'HKCU\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist' 'edge'
Test-UrlBlocklist 'HKCU\SOFTWARE\Policies\Mozilla\Firefox\URLBlocklist' 'firefox'

$report['pass'] = $script:pass
$report['fail'] = $script:fail
$report['ok'] = ($script:fail -eq 0)
$outJson = Join-Path $SixVpnDir 'test_site_apex_block_last.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outJson -Encoding UTF8
Write-Host "Saved: $outJson" -ForegroundColor DarkGray
Write-Host "PASS $script:pass / FAIL $script:fail" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Yellow' })
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
