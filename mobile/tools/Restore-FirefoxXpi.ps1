$xpi = Join-Path $env:ProgramData 'SixVPNBlocker\firefox\sixvpn-blocker@sixvpnblocker.app.xpi'
$root = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
if (-not (Test-Path -LiteralPath $xpi)) { Write-Host 'XPI missing'; exit 1 }
if (-not (Test-Path -LiteralPath $root)) { Write-Host 'No profiles'; exit 1 }
Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
  $d = Join-Path $_.FullName 'extensions'
  New-Item -ItemType Directory -Path $d -Force | Out-Null
  Copy-Item -LiteralPath $xpi -Destination (Join-Path $d 'sixvpn-blocker@sixvpnblocker.app.xpi') -Force
  Write-Host "restored: $($_.Name)"
}
exit 0
