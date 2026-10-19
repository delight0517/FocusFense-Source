# Cursor / Claude — full freeze + block + plugin diagnostic pack (Windows).
# Live refresh (app running): GET http://127.0.0.1:17361/agent/full-pack
# Files: %USERPROFILE%\Documents\SixVPN_Blocker_Debug\

$debug = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug'
$pack = Join-Path $debug 'cursor_full_diagnostic_pack.json'
$prompt = Join-Path $debug 'cursor_agent_handoff_prompt.txt'
$severe = Join-Path $debug 'severe_freeze_last.json'

Write-Host '=== Live API (app must be running) ===' -ForegroundColor Cyan
try {
  $live = Invoke-RestMethod -Uri 'http://127.0.0.1:17361/agent/full-pack' -TimeoutSec 120
  $live | ConvertTo-Json -Depth 16
  exit 0
} catch {
  Write-Host "Live API unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== cursor_agent_handoff_prompt.txt (paste into Cursor) ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $prompt) {
  Get-Content -LiteralPath $prompt -Raw
} else {
  Write-Host 'NOT FOUND — open app > Settings > Diagnostics > Cursor 원탭 진단' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== cursor_full_diagnostic_pack.json ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $pack) {
  Get-Content -LiteralPath $pack -Raw
} else {
  Write-Host 'NOT FOUND' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== severe_freeze_last.json (30s+ UI freeze) ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $severe) {
  Get-Content -LiteralPath $severe -Raw
} else {
  Write-Host 'No severe freeze recorded yet.' -ForegroundColor DarkGray
}
