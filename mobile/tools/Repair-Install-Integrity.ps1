# Restores install exe, alias, backup shards, Run registry, shortcuts when removal is NOT authorized.
# Partial delete (one file only) is healed from any surviving shard within ~30s (watchdog).
param([switch]$Quiet)

$ErrorActionPreference = 'SilentlyContinue'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$manualOff = Join-Path $outDir 'autostart_disabled_v1.json'

function Log([string]$msg) {
  if (-not $Quiet) { Write-Host "[install_integrity] $msg" }
}

if (Test-Path -LiteralPath $manualOff) {
  Log 'manual autostart-off preference - recovery skipped'
  exit 0
}

function Test-RemovalAuthorized {
  $authFile = Join-Path $outDir 'removal_authorized_v1.json'
  if (-not (Test-Path -LiteralPath $authFile)) { return $false }
  try {
    $auth = Get-Content -LiteralPath $authFile -Raw | ConvertFrom-Json
    if (-not $auth.authorized) { return $false }
    if ($auth.bootTickMs) {
      $bootMs = [uint64]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMilliseconds
      return ($bootMs -ge [uint64]$auth.bootTickMs)
    }
    return $true
  } catch { return $false }
}

if (Test-RemovalAuthorized) { exit 0 }

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\FocusFense'
$canonical = Join-Path $installDir 'FocusFense.exe'
$alias = $canonical
$shards = @(
  (Join-Path $outDir 'backup\FocusFense.exe'),
  (Join-Path $outDir 'cache\v1\runner_payload.exe'),
  (Join-Path $outDir 'policy_batch\install_shard_b.exe'),
  (Join-Path $outDir 'staged\search_mirror.exe')
)

$allTargets = @($canonical, $alias) + $shards
$source = $null
foreach ($c in $allTargets) {
  if (Test-Path -LiteralPath $c) {
    $source = $c
    break
  }
}
if (-not $source) {
  Log 'no source exe for repair'
  exit 1
}

$shardPresent = @($shards | Where-Object { Test-Path -LiteralPath $_ }).Count

# Exe-file checks alone miss the failure mode this script exists for: every
# shard can be perfectly intact while the relaunch/autostart tasks themselves
# get deleted (an AI session "cleaning up" scheduled tasks, a broken
# uninstaller, etc.), leaving crash-relaunch and login-autostart silently
# dead with nothing left to notice. Must match
# WindowsInstallIntegrityService.kCoreResilienceTaskNames (Dart side).
$coreResilienceTasks = @(
  'SixVPNBlockerWatchdog',
  'SixVPNBlockerWatchdog2',
  'SixVPNBlockerAutostart',
  'SixVPNBlockerBootGuard',
  'SixVPNBlockerOfflineGuard'
)
$missingTask = $false
foreach ($t in $coreResilienceTasks) {
  if (-not (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)) {
    Log "missing resilience task: $t"
    $missingTask = $true
  }
}

$partial = (-not (Test-Path -LiteralPath $canonical)) `
  -or (-not (Test-Path -LiteralPath $alias)) `
  -or ($shardPresent -lt $shards.Count) `
  -or $missingTask

if (-not $partial) { exit 0 }

Log "partial tamper detected - restoring all copies from $source"

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
foreach ($t in $allTargets) {
  if ($t -ieq $source) { continue }
  $parent = Split-Path -Parent $t
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  try {
    Copy-Item -LiteralPath $source -Destination $t -Force
  } catch {
    Log "copy failed: $t"
  }
}

if (Test-Path -LiteralPath $canonical) {
  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  $quote = [char]34
  $runVal = $quote + $canonical + $quote
  try {
    if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $runKey -Name 'SixVPNBlocker' -Value $runVal -Type String -Force
    $approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    if (-not (Test-Path -LiteralPath $approvedKey)) { New-Item -Path $approvedKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $approvedKey -Name 'SixVPNBlocker' -Value ([byte[]](0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -Type Binary -Force
  } catch {}

  $osPs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Install-Windows-OsIntegration.ps1'
  if (Test-Path -LiteralPath $osPs) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $osPs -ExePath $canonical 2>&1 | Out-Null
  }
}

Log 'repair complete'
exit 0
