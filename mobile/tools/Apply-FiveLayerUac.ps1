# One UAC prompt: hosts (layer 1) + firewall netsh (layer 5).
# Requires desktop BAT from app or ProgramData scripts.

$ErrorActionPreference = 'SilentlyContinue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $scriptDir 'Sync-FiveLayerFirewall.ps1') -Quiet | Out-Null

$prog = Join-Path $env:ProgramData 'SixVPNBlocker'
$hostsCmd = Join-Path $prog 'apply_hosts_admin.cmd'
$hostsVbs = Join-Path $prog 'sixvpn_elevate_hosts.vbs'
$desktopBat = Join-Path $env:USERPROFILE 'Desktop\6 VPN Blocker - hosts 적용 (관리자).bat'

if (Test-Path -LiteralPath $hostsVbs) {
  Write-Host 'Launching hosts+firewall UAC (VBS)...'
  cscript //nologo $hostsVbs
  Start-Sleep -Seconds 4
} elseif (Test-Path -LiteralPath $desktopBat) {
  Write-Host "Launching: $desktopBat"
  Start-Process -FilePath $desktopBat -Wait
} elseif (Test-Path -LiteralPath $hostsCmd) {
  Write-Host 'Launching hosts+firewall UAC (CMD RunAs)...'
  Start-Process -FilePath $hostsCmd -Verb RunAs -Wait
} else {
  Write-Host 'No admin script found. Open app -> Diagnostics -> apply hosts first.'
  exit 1
}

& (Join-Path $scriptDir 'Test-FiveLayerLive.ps1')
exit $LASTEXITCODE
