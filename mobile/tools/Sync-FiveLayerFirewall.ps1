# Resolves blocked domain IPs and writes firewall state + admin BAT (layer 5).
# Usage: -SyncFirewall from Run-FiveLayerExperiment.ps1 or standalone.

param([switch]$Quiet)

$ErrorActionPreference = 'SilentlyContinue'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$progDir = Join-Path $env:ProgramData 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $outDir, $progDir | Out-Null

$maxIps = 28
$ips = New-Object System.Collections.Generic.HashSet[string]
$hosts = @('www.youtube.com', 'youtube.com')

# Pull domains from rules API when app is running
foreach ($port in 17361, 17362, 17363) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rules" -UseBasicParsing -TimeoutSec 3
    if ($r.StatusCode -eq 200) {
      $j = $r.Content | ConvertFrom-Json
      foreach ($d in @($j.blockedDomains)) {
        if ($hosts.Count -ge $maxIps) { break }
        $h = "$d".Trim().ToLower() -replace '^www\.', ''
        if ($h -and $h -notmatch '[\*\s]') { $hosts += $h }
      }
      break
    }
  } catch {}
}

# Parse managed hosts file for 0.0.0.0 lines
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
if (Test-Path -LiteralPath $hostsPath) {
  $inBlock = $false
  Get-Content -LiteralPath $hostsPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -match '6 VPN Blocker BEGIN') { $inBlock = $true; return }
    if ($line -match '6 VPN Blocker END') { $inBlock = $false; return }
    if ($inBlock -and $line -match '^0\.0\.0\.0\s+(\S+)') {
      $hosts += $Matches[1].ToLower() -replace '^www\.', ''
    }
  }
}

$hosts = $hosts | Select-Object -Unique | Select-Object -First $maxIps

foreach ($h in $hosts) {
  if ($ips.Count -ge $maxIps) { break }
  try {
    $resolved = Resolve-DnsName $h -Type A -ErrorAction Stop
    foreach ($a in $resolved) {
      if ($a.IPAddress -and $a.IPAddress -notmatch '^127\.') {
        [void]$ips.Add($a.IPAddress)
      }
    }
  } catch {}
}

$ipList = @($ips) | Select-Object -First $maxIps
$statePath = Join-Path $outDir 'firewall_rules.json'
$batPath = Join-Path $progDir 'apply_firewall_admin.cmd'

if ($ipList.Count -eq 0) {
  if (-not $Quiet) { Write-Host 'firewall sync: no IPs resolved' }
  exit 1
}

$ipList | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

$lines = @(
  '@echo off',
  'setlocal',
  'echo [6 VPN Blocker] firewall outbound block...'
)
foreach ($ip in $ipList) {
  $name = 'SixVPN_Block_' + ($ip -replace '\.', '_')
  $lines += "netsh advfirewall firewall delete rule name=`"$name`" >nul 2>&1"
  $lines += "netsh advfirewall firewall add rule name=`"$name`" dir=out action=block remoteip=$ip enable=yes"
}
$lines += 'exit /b 0'
$lines -join "`r`n" | Set-Content -LiteralPath $batPath -Encoding ASCII

$desktop = Join-Path $env:USERPROFILE 'Desktop'
if (Test-Path -LiteralPath $desktop) {
  $shortcut = Join-Path $desktop '6 VPN Blocker - firewall apply (admin).bat'
  @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '$batPath' -Verb RunAs"
"@ | Set-Content -LiteralPath $shortcut -Encoding ASCII
}

if (-not $Quiet) {
  Write-Host "firewall sync: $($ipList.Count) IPs -> $statePath"
  Write-Host "admin BAT: $batPath"
}
exit 0
