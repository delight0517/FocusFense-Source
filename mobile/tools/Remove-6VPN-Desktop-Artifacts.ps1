# Removes 6 VPN Blocker desktop .lnk / .bat artifacts (never creates new ones).
$ErrorActionPreference = "Continue"
$desktop = [Environment]::GetFolderPath("Desktop")

$exactNames = @(
  '6 VPN Blocker (Windows).lnk',
  '6 VPN Blocker (Windows) - Rebuild.lnk',
  '6 VPN Blocker - Rebuild.bat',
  '6 VPN Blocker (Chrome).lnk',
  '6 VPN Blocker (Edge).lnk',
  '6 VPN Blocker (Firefox).lnk',
  'Six VPN Blocker (Windows).lnk',
  'Six VPN Blocker - Rebuild.lnk',
  'Six VPN block - Rebuild.lnk',
  'Six VPN Blocker-Rebuild.lnk',
  'Six VPN Blocker.lnk',
  'six_clean_room.lnk',
  '6VPN Blocker.lnk'
)

$removed = 0
foreach ($name in $exactNames) {
  $p = Join-Path $desktop $name
  if (Test-Path -LiteralPath $p) {
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    Write-Host "Removed: $p" -ForegroundColor Yellow
    $removed++
  }
}

$patterns = @('*6 VPN*Rebuild*', '*Six VPN*Rebuild*', '*SixVPN*Rebuild*', '*Rebuild*.lnk')
foreach ($pat in $patterns) {
  Get-ChildItem -LiteralPath $desktop -Filter $pat -ErrorAction SilentlyContinue |
    ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      Write-Host "Removed (pattern $pat): $($_.FullName)" -ForegroundColor Yellow
      $removed++
    }
}

if ($removed -eq 0) {
  Write-Host "No 6 VPN Blocker desktop artifacts found." -ForegroundColor Gray
} else {
  Write-Host "Removed $removed desktop artifact(s). Auto-create is disabled." -ForegroundColor Cyan
}
