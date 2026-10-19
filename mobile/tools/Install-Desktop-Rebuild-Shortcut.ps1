# Rebuild desktop launcher creation is DISABLED — cleanup only.
$ErrorActionPreference = "Stop"
$remove = Join-Path $PSScriptRoot "Remove-6VPN-Desktop-Artifacts.ps1"
if (Test-Path -LiteralPath $remove) {
  & $remove
} else {
  Write-Host "Remove script missing; skipped desktop cleanup." -ForegroundColor Yellow
}
