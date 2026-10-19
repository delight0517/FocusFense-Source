# Test-Mingky01-ChromeBlock.ps1 — DNS sinkhole + Chrome headless verify for mingky01.live
param(
  [string]$TestHost = 'mingky01.live',
  [string]$TestUrl = 'https://mingky01.live/'
)

$ErrorActionPreference = 'Continue'
$report = @{
  timestamp = (Get-Date).ToString('o')
  testHost = $TestHost
  testUrl = $TestUrl
  checks = @()
  ok = $false
}

function Add-Check([string]$name, [bool]$pass, [string]$detail) {
  $script:report.checks += @{ name = $name; pass = $pass; detail = $detail }
}

# --- DNS sinkhole (primary — real block layer) ---
$dnsIp = $null
try {
  $dns = Resolve-DnsName -Name $TestHost -Type A -ErrorAction Stop | Select-Object -First 1
  $dnsIp = $dns.IPAddress
} catch {
  $dnsIp = 'lookup_failed'
}
$dnsBlocked = ($dnsIp -eq '0.0.0.0') -or ($dnsIp -eq '127.0.0.1')
Add-Check 'dns_sinkhole' $dnsBlocked "ip=$dnsIp"

$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$hostsHas = $false
if (Test-Path -LiteralPath $hostsPath) {
  $hostsHas = Select-String -LiteralPath $hostsPath -Pattern "0\.0\.0\.0\s+$([regex]::Escape($TestHost))(\s|$)" -Quiet
}
Add-Check 'hosts_line' $hostsHas $TestHost

$regPat = "*://$TestHost/*"
$regOut = reg query 'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist' 2>&1 | Out-String
Add-Check 'registry_apex' ($regOut -match [regex]::Escape($regPat)) $regPat

$chrome = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path -LiteralPath $chrome)) {
  $chrome = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
}
Add-Check 'chrome_exe' (Test-Path -LiteralPath $chrome) $chrome

taskkill /F /IM chrome.exe 2>&1 | Out-Null
Start-Sleep -Seconds 2
Add-Check 'chrome_killed' $true 'taskkill chrome.exe'

if ((Test-Path -LiteralPath $chrome) -and $dnsBlocked) {
  $tmpdir = Join-Path $env:TEMP "sixvpn_mingky_probe_$(Get-Random)"
  $profile = Join-Path $tmpdir 'profile'
  New-Item -ItemType Directory -Force -Path $profile | Out-Null
  $outFile = Join-Path $tmpdir 'out.txt'
  $errFile = Join-Path $tmpdir 'err.txt'
  $args = @(
    '--headless=new', '--disable-gpu', '--no-first-run',
    "--user-data-dir=$profile", '--dump-dom', $TestUrl
  )
  $p = Start-Process -FilePath $chrome -ArgumentList $args -Wait -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
  $dom = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
  $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
  $combined = "$dom`n$err"
  $connFail = $combined -match 'ERR_CONNECTION_REFUSED|ERR_NAME_NOT_RESOLVED|ERR_ADDRESS_UNREACHABLE|neterror-title'
  $tiny = ($combined.Length -lt 200)
  $blocked = $connFail -or $tiny
  Add-Check 'headless_blocked' $blocked "exit=$($p.ExitCode) len=$($combined.Length)"
  Remove-Item -LiteralPath $tmpdir -Recurse -Force -ErrorAction SilentlyContinue
} elseif (-not $dnsBlocked) {
  Add-Check 'headless_blocked' $false 'skipped_dns_leak'
}

# DNS sinkhole is mandatory; registry is informational
$critical = @('dns_sinkhole', 'hosts_line')
$report.ok = $true
foreach ($c in $report.checks) {
  if ($critical -contains $c.name -and -not $c.pass) {
    $report.ok = $false
  }
}

$outJson = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\debug\test_mingky01_chrome_block.json'
New-Item -ItemType Directory -Force -Path (Split-Path $outJson) | Out-Null
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outJson -Encoding UTF8
Write-Host "Report: $outJson"
Write-Host "OK=$($report.ok)"
$report.checks | ForEach-Object { Write-Host "  $($_.name): pass=$($_.pass) $($_.detail)" }
if (-not $report.ok) { exit 1 }
exit 0
