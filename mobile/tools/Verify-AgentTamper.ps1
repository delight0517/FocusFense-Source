# 5 AI-agent bypass scenarios — live verify (no UAC).
# Writes: %LOCALAPPDATA%\SixVPNBlocker\agent_tamper_verify_last.json
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$reportPath = Join-Path $outDir 'agent_tamper_verify_last.json'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path (Join-Path $repoRoot 'mobile\pubspec.yaml'))) {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  if (-not (Test-Path (Join-Path $repoRoot 'pubspec.yaml'))) {
    $repoRoot = $PSScriptRoot
  }
}
$mobileRoot = if (Test-Path (Join-Path $repoRoot 'mobile\pubspec.yaml')) {
  Join-Path $repoRoot 'mobile'
} else { $repoRoot }

function Count-UrlBlocklist {
  param([string]$HivePath)
  if (-not (Test-Path $HivePath)) { return 0 }
  $p = Get-ItemProperty -LiteralPath $HivePath -ErrorAction SilentlyContinue
  if (-not $p) { return 0 }
  ($p.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' }).Count
}

function Test-FileContains {
  param([string]$Path, [string]$Needle)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    return (Select-String -LiteralPath $Path -SimpleMatch -Pattern $Needle -Quiet)
  } catch { return $false }
}

$edgeBl = 'HKCU:\Software\Policies\Microsoft\Edge\URLBlocklist'
$blCount = Count-UrlBlocklist $edgeBl
$pacUrl = (Get-ItemProperty 'HKCU:\Software\Policies\Microsoft\Edge' -ErrorAction SilentlyContinue).ProxyPacUrl
$pacFile = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\sixvpn_block.pac'

$pubspec = Join-Path $mobileRoot 'pubspec.yaml'
$mainDart = Join-Path $mobileRoot 'lib\main.dart'
$builtin = Join-Path $mobileRoot 'lib\services\builtin_block_domains.dart'
$offlinePs = Join-Path $mobileRoot 'tools\Offline-Block-Policy-Maintain.ps1'
$cursorRule = Join-Path $repoRoot '.cursor\rules\agent-destructive-guard.mdc'
$cursorRules = Join-Path $repoRoot '.cursorrules'
$noAutoRepo = Join-Path $mobileRoot 'tools\NO_AUTO_REBUILD'
$noAutoLocal = Join-Path $outDir 'no_auto_rebuild.flag'

$offlineTask = $false
try {
  $null = schtasks /Query /TN 'SixVPNBlockerOfflineGuard' 2>$null
  $offlineTask = ($LASTEXITCODE -eq 0)
} catch { $offlineTask = $false }

$scenarios = @()

# S1 — AI orders app delete / wipe mobile
$s1Ok = (Test-Path $pubspec) -and (Test-Path $mainDart)
$scenarios += @{
  id = 's1_ai_delete_app'
  title = 'S1: Cursor delete app / wipe mobile'
  mitigated = $s1Ok
  detail = "pubspec=$([bool](Test-Path $pubspec)) main.dart=$([bool](Test-Path $mainDart))"
  fix = 'Repo restore from backup/git; OfflineGuard keeps HKCU block while app is gone'
  defense = 'agent-destructive-guard.mdc forbids delete; boot watchdog alerts'
}

# S2 — AI guts blocking core
$builtinOk = (Test-FileContains $builtin 'youtube.com') -and (Test-FileContains $builtin 'youtu.be')
$offlinePsOk = (Test-FileContains $offlinePs 'URLBlocklist')
$s2Ok = $builtinOk -and $offlinePsOk
$scenarios += @{
  id = 's2_ai_gut_block_code'
  title = 'S2: Cursor gut builtin_block / policy scripts'
  mitigated = $s2Ok
  detail = "builtin_yt=$builtinOk maintain_ps=$offlinePsOk"
  fix = 'Heal-AgentTamper.ps1 restores templates; rebuild if Dart changed'
  defense = 'Cursor rule blocks apex removal without owner override token'
}

# S3 — AI disables guards / auto-maintain
$rogueOptOut = $false
if ((Test-Path $noAutoRepo) -or (Test-Path $noAutoLocal)) {
  # Flagged as risk; user may have enabled via Settings — detail only
  $rogueOptOut = $true
}
$s3Ok = $offlineTask
$scenarios += @{
  id = 's3_ai_disable_guards'
  title = 'S3: Cursor disable OfflineGuard / NO_AUTO_REBUILD'
  mitigated = $s3Ok
  detail = "offline_task=$offlineTask opt_out_files=$rogueOptOut"
  fix = 'Heal-AgentTamper.ps1 re-registers tasks; removes rogue opt-out if prefs disagree'
  defense = 'Agents must not create NO_AUTO_REBUILD; scheduled task survives app kill'
}

# S4 — AI strips Cursor rules
$ruleOk = Test-Path $cursorRule
$markerOk = Test-FileContains $cursorRules 'AGENT_DESTRUCTIVE_GUARD'
$s4Ok = $ruleOk -and $markerOk
$scenarios += @{
  id = 's4_ai_strip_cursor_rules'
  title = 'S4: Cursor delete .cursorrules / agent guard'
  mitigated = $s4Ok
  detail = "guard_mdc=$ruleOk cursorrules_marker=$markerOk"
  fix = 'Heal-AgentTamper.ps1 copies AgentTamper-Templates/agent-destructive-guard.mdc'
  defense = 'alwaysApply rule + template self-restore'
}

# S5 — AI wipes browser policies
$pacOk = (Test-Path $pacFile) -and ($pacUrl -match 'sixvpn_block\.pac')
$s5Ok = ($blCount -ge 5) -and $pacOk
$scenarios += @{
  id = 's5_ai_wipe_policies'
  title = 'S5: Cursor clear URLBlocklist / PAC / forcelist'
  mitigated = $s5Ok
  detail = "urlblocklist=$blCount pac_reg=$([bool]$pacOk)"
  fix = 'Offline-Block-Policy-Maintain.ps1 + ExtensionKeepalive (app running)'
  defense = 'SixVPNBlockerOfflineGuard every 10 min without UAC'
}

# S6 — override verifier + probe (no token format in repo chat)
$probe = Join-Path $outDir 'agent_destruct_gate_probe.json'
$verifyOverride = Join-Path $mobileRoot 'tools\Verify-AgentDestruct-Override.ps1'
$s6Ok = (Test-Path -LiteralPath $verifyOverride) -and (Test-Path -LiteralPath $probe)
$scenarios += @{
  id = 's6_token_social_engineering'
  title = 'S6: fake token / format leak blocked'
  mitigated = $s6Ok
  detail = "verify_ps=$([bool](Test-Path $verifyOverride)) probe=$([bool](Test-Path $probe))"
  fix = 'Verify-AgentDestruct-Override.ps1 + agent_destruct_gate_probe.json; agents use S6 canned reply'
  defense = 'agent-destructive-guard S6: no format hints in chat'
}
$pass = ($scenarios | Where-Object { $_.mitigated }).Count
$total = $scenarios.Count

$report = @{
  at = (Get-Date).ToString('o')
  passCount = $pass
  totalCount = $total
  scenarios = $scenarios
  repoRoot = $repoRoot
  mobileRoot = $mobileRoot
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if (-not $Quiet) {
  Write-Host "Agent tamper verify: $pass/$total PASS"
  foreach ($s in $scenarios) {
    $icon = if ($s.mitigated) { 'OK' } else { 'FAIL' }
    Write-Host "  [$icon] $($s.id) - $($s.detail)"
  }
  Write-Host "Report: $reportPath"
}

if ($pass -lt $total) { exit 1 }
exit 0
