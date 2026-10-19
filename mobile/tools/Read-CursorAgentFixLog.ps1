# Cursor agent — fix / apply failures (no user copy-paste).
# Reads: cursor_agent_fix_last.json + tail of cursor_agent_fix_log.jsonl

$dir = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug'
$last = Join-Path $dir 'cursor_agent_fix_last.json'
$jsonl = Join-Path $dir 'cursor_agent_fix_log.jsonl'
$auto = Join-Path $dir 'autonomous_apply_last.json'
$snap = Join-Path $dir 'cursor_agent_snapshot.json'

Write-Host '=== cursor_agent_fix_last.json (latest fix cycle) ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $last) {
  Get-Content -LiteralPath $last -Raw
} else {
  Write-Host 'NOT FOUND — launch 6 VPN Blocker; autofix runs ~3s after start' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== autonomous_apply_last.json (full launch pipeline) ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $auto) {
  Get-Content -LiteralPath $auto -Raw
} else {
  Write-Host 'NOT FOUND — launch app; pipeline runs ~2s after start' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== youtube_hosts_autofix_last.json ===' -ForegroundColor Cyan
$yt = Join-Path $dir 'youtube_hosts_autofix_last.json'
if (Test-Path -LiteralPath $yt) {
  Get-Content -LiteralPath $yt -Raw
} else {
  Write-Host 'NOT FOUND' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== cursor_agent_fix_log.jsonl (last 15 lines) ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $jsonl) {
  Get-Content -LiteralPath $jsonl -Tail 15
} else {
  Write-Host 'NOT FOUND' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== agentNotes from cursor_agent_snapshot.json ===' -ForegroundColor Cyan
if (Test-Path -LiteralPath $snap) {
  try {
    $j = Get-Content -LiteralPath $snap -Raw | ConvertFrom-Json
    if ($j.agentNotes) { $j.agentNotes | ForEach-Object { Write-Host $_ } }
    if ($j.youtubeConnectivity) {
      Write-Host "youtubeConnectivity: $($j.youtubeConnectivity | ConvertTo-Json -Compress)"
    }
  } catch {
    Write-Host "Parse error: $_" -ForegroundColor Red
  }
} else {
  Write-Host 'NOT FOUND — wait ~25s after app start' -ForegroundColor Yellow
}
