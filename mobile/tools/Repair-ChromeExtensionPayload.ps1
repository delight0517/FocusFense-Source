# Repairs empty %LOCALAPPDATA%\SixVPNBlocker\chrome_blocker (manifest missing).
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\assets\browser_extensions\chrome'
$src = (Resolve-Path -LiteralPath $src).Path
$dest = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\chrome_blocker'
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Path (Join-Path $src '*') -Destination $dest -Force
$pd = Join-Path $env:ProgramData 'SixVPNBlocker\chrome_blocker'
try {
  if (Test-Path -LiteralPath $pd) { Remove-Item -LiteralPath $pd -Recurse -Force -ErrorAction Stop }
  New-Item -ItemType Directory -Force -Path $pd | Out-Null
  Copy-Item -Path (Join-Path $src '*') -Destination $pd -Force -ErrorAction Stop
  Write-Host "ProgramData manifest: $(Test-Path (Join-Path $pd 'manifest.json'))"
} catch {
  Write-Host "ProgramData skip (access denied): $($_.Exception.Message)"
}
$ok = Test-Path -LiteralPath (Join-Path $dest 'manifest.json')
Write-Host "LOCALAPPDATA manifest: $ok"
Write-Host "Files: $((Get-ChildItem -LiteralPath $dest).Count)"
if (-not $ok) { exit 1 }
