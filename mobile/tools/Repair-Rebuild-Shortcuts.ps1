# Removes broken desktop rebuild shortcuts only (no recreation).
$ErrorActionPreference = "Continue"
$remove = Join-Path $PSScriptRoot "Remove-6VPN-Desktop-Artifacts.ps1"
if (Test-Path -LiteralPath $remove) {
  & $remove
} else {
  Write-Host "Missing: $remove" -ForegroundColor Red
  exit 1
}
