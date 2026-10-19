# Cursor agent — full PC / block state snapshot (Windows).
# Writes/reads: %USERPROFILE%\Documents\SixVPN_Blocker_Debug\cursor_agent_snapshot.json
# Refresh live snapshot from running app: curl http://127.0.0.1:17361/agent/snapshot

$snap = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug\cursor_agent_snapshot.json'

$ytGuard = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug\youtube_proactive_guard_last.json'

Write-Host '=== Try live refresh (app must be running) ===' -ForegroundColor Cyan
try {
  $live = Invoke-RestMethod -Uri 'http://127.0.0.1:17361/agent/snapshot' -TimeoutSec 15
  $live | ConvertTo-Json -Depth 12
  exit 0
} catch {
  Write-Host "Live API unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== cursor_agent_snapshot.json (last saved) ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $snap) {
  Get-Content -LiteralPath $snap -Raw
} else {
  Write-Host 'NOT FOUND — start 6 VPN Blocker, wait ~30s, or open Settings > Diagnostics' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== youtube_proactive_guard_last.json ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $ytGuard) {
  Get-Content -LiteralPath $ytGuard -Raw
} else {
  Write-Host 'NOT FOUND — app runs YouTube guard ~25s after boot' -ForegroundColor Yellow
}
