# Desktop shortcut auto-create is DISABLED (user request 2026-06-05).
# This script only removes legacy 6 VPN Blocker desktop .lnk / .bat files.
$ErrorActionPreference = "Stop"
$remove = Join-Path $PSScriptRoot "Remove-6VPN-Desktop-Artifacts.ps1"
if (-not (Test-Path -LiteralPath $remove)) {
  Write-Host "Missing: $remove" -ForegroundColor Red
  exit 1
}
& $remove
