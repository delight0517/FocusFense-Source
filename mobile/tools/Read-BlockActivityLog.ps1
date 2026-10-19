# Prints block activity summary + tail for Cursor agents (Windows).
$summary = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug\block_activity_summary.json'
$jsonl = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug\block_activity.jsonl'

Write-Host '=== block_activity_summary.json ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $summary) {
  Get-Content -LiteralPath $summary -Raw
} else {
  Write-Host 'NOT FOUND — run 6 VPN Blocker and open Settings > Diagnostics > Live block activity' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== block_activity.jsonl (last 30 lines) ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $jsonl) {
  Get-Content -LiteralPath $jsonl -Tail 30
} else {
  Write-Host 'NOT FOUND' -ForegroundColor Yellow
}
