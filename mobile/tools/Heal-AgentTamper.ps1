# Auto-heal what AI-agent sabotage can fix without owner override token.
param([switch]$Quiet)

$ErrorActionPreference = 'Continue'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$healLog = Join-Path $outDir 'agent_tamper_heal_last.json'
$steps = New-Object System.Collections.Generic.List[string]

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path (Join-Path $repoRoot 'mobile\pubspec.yaml'))) {
  $repoRoot = Split-Path $PSScriptRoot -Parent
}
$mobileRoot = if (Test-Path (Join-Path $repoRoot 'mobile\pubspec.yaml')) {
  Join-Path $repoRoot 'mobile'
} else { $repoRoot }

function Step($msg) { $script:steps.Add($msg) | Out-Null; if (-not $Quiet) { Write-Host $msg } }

# S4 — restore agent guard rule from template
$tpl = Join-Path $PSScriptRoot 'AgentTamper-Templates\agent-destructive-guard.mdc'
$destRule = Join-Path $repoRoot '.cursor\rules\agent-destructive-guard.mdc'
if ((Test-Path $tpl) -and -not (Test-Path $destRule)) {
  New-Item -ItemType Directory -Force -Path (Split-Path $destRule) | Out-Null
  Copy-Item -LiteralPath $tpl -Destination $destRule -Force
  Step 'S4: restored .cursor/rules/agent-destructive-guard.mdc'
}

# S6 — deploy override verifier script to LOCALAPPDATA tools
$verifyOverride = Join-Path $PSScriptRoot 'Verify-AgentDestruct-Override.ps1'
$destTools = Join-Path $outDir 'tools'
if (Test-Path $verifyOverride) {
  New-Item -ItemType Directory -Force -Path $destTools | Out-Null
  Copy-Item -LiteralPath $verifyOverride -Destination (Join-Path $destTools 'Verify-AgentDestruct-Override.ps1') -Force
  Step 'S6: deployed Verify-AgentDestruct-Override.ps1'
}

# S3 — re-register offline guard via maintain script hook (schtasks created by app; run maintain)
$maintain = Join-Path $mobileRoot 'tools\Offline-Block-Policy-Maintain.ps1'
if (Test-Path $maintain) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $maintain -Quiet 2>&1 | Out-Null
  Step 'S5/S3: Offline-Block-Policy-Maintain.ps1 executed'
}

# S3 — rogue NO_AUTO_REBUILD only if prefs marker says user did NOT opt out via UI
$prefsPath = Join-Path $outDir 'rebuild_prefs_probe.json'
# Dart syncs flag when user toggles Settings; if flag exists but no recent app run, still heal maintain only.
$noAutoRepo = Join-Path $mobileRoot 'tools\NO_AUTO_REBUILD'
$noAutoLocal = Join-Path $outDir 'no_auto_rebuild.flag'
# Do not delete opt-out files automatically — Verify flags for human review.

# S2 — cannot safely auto-restore Dart from PS; report only
$builtin = Join-Path $mobileRoot 'lib\services\builtin_block_domains.dart'
if ((Test-Path $builtin) -and -not (Select-String -LiteralPath $builtin -Pattern 'youtube\.com' -Quiet)) {
  Step 'S2: WARN builtin_block_domains.dart missing youtube.com — git restore required'
}

# Re-verify
$verify = Join-Path $PSScriptRoot 'Verify-AgentTamper.ps1'
$verifyExit = 0
if (Test-Path $verify) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $verify -Quiet
  $verifyExit = $LASTEXITCODE
}

$payload = @{
  at = (Get-Date).ToString('o')
  steps = $steps
  verifyExit = $verifyExit
}
$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $healLog -Encoding UTF8
if (-not $Quiet) { Write-Host "Heal log: $healLog" }
exit $verifyExit
