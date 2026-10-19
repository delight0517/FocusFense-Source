# Strips YouTube DNS sinkhole from managed hosts (admin). PAC+URLBlocklist handle per-video blocks.
$ErrorActionPreference = 'Stop'
$hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$start = '# === 6 VPN Blocker BEGIN (managed) ==='
$end = '# === 6 VPN Blocker END (managed) ==='

attrib -R $hostsPath 2>$null | Out-Null
icacls $hostsPath /reset 2>$null | Out-Null

$raw = Get-Content -LiteralPath $hostsPath -Raw -Encoding UTF8
$i = $raw.IndexOf($start)
$j = $raw.IndexOf($end)
if ($i -lt 0 -or $j -le $i) {
  Write-Host 'No managed region — nothing to fix'
  exit 0
}

$before = $raw.Substring(0, $i)
$region = $raw.Substring($i, $j - $i)
$after = $raw.Substring($j)

$lines = $region -split "`r?`n"
$kept = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
  $t = $line.Trim().ToLowerInvariant()
  if ($t -match 'youtube section') { continue }
  if ($t -match '0\.0\.0\.0\s+.*youtube' -or $t -match '^::\s+.*youtube') { continue }
  if ($t -match '0\.0\.0\.0\s+youtu\.be' -or $t -match '^::\s+youtu\.be') { continue }
  if ($t -match '0\.0\.0\.0\s+.*youtu\.be' -or $t -match '^::\s+.*youtu\.be') { continue }
  if ($t -match 'googlevideo\.com' -or $t -match 'ytimg\.com' -or $t -match 'ggpht\.com') { continue }
  [void]$kept.Add($line)
}

$newRegion = ($kept -join "`r`n").TrimEnd()
$newRaw = ($before + $newRegion + "`r`n" + $after).TrimEnd() + "`r`n"
Set-Content -LiteralPath $hostsPath -Value $newRaw -Encoding UTF8
ipconfig /flushdns | Out-Null
Write-Host 'YouTube hosts sinkhole removed — DNS cache flushed'
