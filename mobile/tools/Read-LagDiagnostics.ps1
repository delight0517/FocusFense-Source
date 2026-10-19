# Read lag / CPU spike diagnostics for Cursor & Claude agents.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File mobile\tools\Read-LagDiagnostics.ps1

$ErrorActionPreference = 'Continue'
$docs = [Environment]::GetFolderPath('MyDocuments')
$debug = Join-Path $docs 'SixVPN_Blocker_Debug'

function Read-JsonFile($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

Write-Host '=== 6 VPN Blocker — Lag Diagnostics ===' -ForegroundColor Cyan
Write-Host "Debug folder: $debug"
Write-Host ''

$summary = Read-JsonFile (Join-Path $debug 'lag_diagnostic_summary.json')
if ($summary) {
  Write-Host '--- Summary ---' -ForegroundColor Green
  Write-Host "  CPU spikes : $($summary.counts.cpuSpike)"
  Write-Host "  UI stalls  : $($summary.counts.uiStall)"
  Write-Host "  UI freezes : $($summary.counts.uiFreeze)"
  Write-Host "  Total      : $($summary.counts.total)"
  if ($summary.lastEvent.kind) {
    Write-Host "  Last event : $($summary.lastEvent.kind) @ $($summary.lastEvent.at)"
  }
  Write-Host ''
}

$last = Read-JsonFile (Join-Path $debug 'lag_diagnostic_last.json')
if ($last) {
  Write-Host '--- Last severe event (lag_diagnostic_last.json) ---' -ForegroundColor Yellow
  Write-Host "  kind=$($last.kind) severity=$($last.severity) at=$($last.at)"
  if ($last.classification) {
    Write-Host "  legitimacy: $($last.classification.legitimacy) ($($last.classification.legitimacyLabelKo))"
    Write-Host "  headline: $($last.classification.headlineKo)"
  }
  if ($last.metrics.elapsedMs) {
    Write-Host "  elapsedMs: $($last.metrics.elapsedMs)"
  }
  if ($last.activeWork -and $last.activeWork.Count -gt 0) {
    Write-Host '  activeWork:'
    $last.activeWork | ForEach-Object { Write-Host "    - $($_.label) (${_.runningMs}ms)" }
  }
  if ($last.recentWork -and $last.recentWork.Count -gt 0) {
    Write-Host '  recentWork (last completed):'
    $last.recentWork | Select-Object -First 8 | ForEach-Object {
      Write-Host "    - $($_.label) $($_.durationMs)ms"
    }
  }
  if ($last.childProcesses) {
    Write-Host "  childProcesses: reg=$($last.childProcesses.reg) ps=$($last.childProcesses.powershell) conhost=$($last.childProcesses.conhost)"
  }
  if ($last.recentLogLines -and $last.recentLogLines.Count -gt 0) {
    Write-Host '  recentLogLines (tail 8):'
    $last.recentLogLines | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" }
  }
  Write-Host ''
}

$jsonl = Join-Path $debug 'lag_events.jsonl'
if (Test-Path -LiteralPath $jsonl) {
  Write-Host '--- lag_events.jsonl (last 5) ---' -ForegroundColor DarkGray
  Get-Content -LiteralPath $jsonl -Tail 5 | ForEach-Object { Write-Host $_ }
  Write-Host ''
}

foreach ($name in @('cpu_spike_last.json', 'app_lag_last.json', 'severe_lag_session_last.json')) {
  $p = Join-Path $debug $name
  if (Test-Path -LiteralPath $p) {
    Write-Host "--- $name exists ---" -ForegroundColor DarkGray
  }
}

$freeze = Join-Path $debug 'freeze_log.jsonl'
if (Test-Path -LiteralPath $freeze) {
  Write-Host '--- freeze_log.jsonl (last 3) ---' -ForegroundColor DarkGray
  Get-Content -LiteralPath $freeze -Tail 3 | ForEach-Object { Write-Host $_ }
}

Write-Host ''
Write-Host 'Tip: paste lag_diagnostic_last.json into Cursor chat for auto-fix.' -ForegroundColor Cyan
