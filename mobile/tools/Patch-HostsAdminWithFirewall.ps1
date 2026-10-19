# Patches ProgramData apply_hosts_admin.cmd to include layer-5 netsh block.
$ErrorActionPreference = 'SilentlyContinue'
& (Split-Path -Parent $MyInvocation.MyCommand.Path)\Sync-FiveLayerFirewall.ps1 -Quiet | Out-Null

$cmdPath = Join-Path $env:ProgramData 'SixVPNBlocker\apply_hosts_admin.cmd'
$fwBat = Join-Path $env:ProgramData 'SixVPNBlocker\apply_firewall_admin.cmd'
if (-not (Test-Path -LiteralPath $cmdPath)) {
  Write-Host 'apply_hosts_admin.cmd missing — run app diagnostics apply first'
  exit 1
}

$content = Get-Content -LiteralPath $cmdPath -Raw
if ($content -match 'firewall layer 5') {
  Write-Host 'already patched'
  exit 0
}

$insert = @"

echo [6 VPN Blocker] firewall layer 5...
if exist "$fwBat" call "$fwBat"
"@
$new = $content -replace 'exit /b 0\s*$', ($insert + "`r`nexit /b 0`r`n")
Set-Content -LiteralPath $cmdPath -Value $new -Encoding ASCII
Write-Host "patched: $cmdPath"
exit 0
