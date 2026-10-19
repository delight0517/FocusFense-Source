# Rebuild "auto shower" — pre-launch filesystem cleanup (app is not running).
# Writes rebuild_auto_shower_pending.txt so Dart finishes HKCU/PAC strip on first boot.
param(
  [string] $BuildLabel = 'unknown'
)

$ErrorActionPreference = 'SilentlyContinue'
$dir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Host '=== Rebuild Auto-Shower (pre-launch) ===' -ForegroundColor Cyan

# Duplicate / stale extension mirror folders
Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^chrome_blocker_(retired|staging)' } |
  ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force
    Write-Host "Removed $($_.Name)" -ForegroundColor Yellow
  }

# Stale post-rebuild UI text (Dart will regenerate)
$stale = @(
  'last_post_rebuild_status.txt',
  'rebuild_auto_shower_last_ps.txt'
)
foreach ($name in $stale) {
  $p = Join-Path $dir $name
  if (Test-Path -LiteralPath $p) {
    Remove-Item -LiteralPath $p -Force
    Write-Host "Removed stale $name" -ForegroundColor DarkGray
  }
}

$pending = Join-Path $dir 'rebuild_auto_shower_pending.txt'
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($pending, "$BuildLabel`n", $utf8)

$psLog = Join-Path $dir 'rebuild_auto_shower_last_ps.txt'
$ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
[System.IO.File]::WriteAllText(
  $psLog,
  "at=$ts`nbuild=$BuildLabel`nphase=pre_launch_fs_clean`n",
  $utf8
)

Write-Host "Auto-shower pending for app launch ($BuildLabel)" -ForegroundColor Green
