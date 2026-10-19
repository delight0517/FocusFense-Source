# Runs elevated via pre-registered scheduled task (no repeat UAC after first registration).
# Restarts DNS sinkhole scripts if blocking stamp says active.
$ErrorActionPreference = 'SilentlyContinue'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$pd = Join-Path $env:ProgramData 'SixVPNBlocker'
$stamp = Join-Path $outDir 'blocking_active_v1.json'

$report = [ordered]@{
  at      = (Get-Date).ToString('o')
  actions = @()
  ok      = $true
}

function Log-Action([string]$name, [bool]$ok, [string]$detail) {
  $report.actions += [ordered]@{ name = $name; ok = $ok; detail = $detail }
  if (-not $ok) { $report.ok = $false }
}

if (-not (Test-Path -LiteralPath $stamp)) {
  Log-Action 'stamp' $true 'blocking not active — skip'
  $report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir 'elevated_maintain_last.json') -Encoding UTF8
  exit 0
}

# hosts marker
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$hostsOk = $false
if (Test-Path -LiteralPath $hostsPath) {
  $hostsOk = Select-String -LiteralPath $hostsPath -Pattern '6 VPN Blocker BEGIN' -Quiet
}
Log-Action 'hosts_marker' $hostsOk $(if ($hostsOk) { 'present' } else { 'missing — open app and apply once' })

# DNS sinkhole TCP/UDP scripts in ProgramData
$udpScript = Join-Path $pd 'SixVpnLoopbackDns.ps1'
$tcpScript = Join-Path $pd 'SixVpnLoopbackDnsTcp.ps1'
$udpPid = Join-Path $pd 'dns_sink.pid'
$tcpPid = Join-Path $pd 'dns_sink_tcp.pid'

function Test-PidAlive([string]$pidFile) {
  if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
  $pid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $pid) { return $false }
  return $null -ne (Get-Process -Id $pid -ErrorAction SilentlyContinue)
}

if ((Test-Path -LiteralPath $udpScript) -and -not (Test-PidAlive $udpPid)) {
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $udpScript
  ) -WindowStyle Hidden -PassThru
  Log-Action 'dns_udp_restart' ($null -ne $p) "pid=$($p.Id)"
}
if ((Test-Path -LiteralPath $tcpScript) -and -not (Test-PidAlive $tcpPid)) {
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $tcpScript
  ) -WindowStyle Hidden -PassThru
  Log-Action 'dns_tcp_restart' ($null -ne $p) "pid=$($p.Id)"
}

# --- Phase 6 (L5): dynamic "never opens" launch block via IFEO ------------
# WindowsAppBlockService (unprivileged) writes the set of currently-blocked
# exes to this sidecar every time the active schedule changes, and triggers
# this task on-demand (schtasks /Run) so the switch below happens within a
# few seconds instead of waiting for the 30-minute cadence. We only ever
# touch IFEO keys whose Debugger already points at our own launcher — never
# an exe some other tool (a real debugger, antivirus, etc.) has hooked.
$ifeoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$vbsLauncher = 'C:\ProgramData\SixVPNBlocker\BlockedBrowserToastLauncher.vbs'
$sidecarPath = Join-Path $outDir 'process_layer_active_exes.json'
$newDbg = "C:\Windows\System32\wscript.exe //B //Nologo `"$vbsLauncher`""

# The 4 always-blocked browsers (Edge/Whale/Opera/Vivaldi) are a separate,
# static feature (BlockedBrowserLaunchNoticeService) — this dynamic sync must
# never remove their IFEO key just because they're absent from the schedule
# sidecar right now.
$staticAlwaysExes = @('msedge.exe', 'whale.exe', 'opera.exe', 'opera_gx.exe', 'vivaldi.exe')

function Test-OwnedIfeoDebugger([string]$Dbg) {
  return ($Dbg -and $Dbg -match 'BlockedBrowserToastLauncher')
}

function Test-ResolvesUnderWindowsDir([string]$ExeName) {
  try {
    $cmd = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
      return $cmd.Source.ToLowerInvariant().StartsWith("$env:WINDIR".ToLowerInvariant())
    }
  } catch {}
  return $false
}

$activeExes = @{}
if (Test-Path -LiteralPath $sidecarPath) {
  try {
    $parsed = Get-Content -LiteralPath $sidecarPath -Raw | ConvertFrom-Json
    if ($parsed.activeExes) {
      foreach ($prop in $parsed.activeExes.PSObject.Properties) {
        $activeExes[$prop.Name.ToLowerInvariant()] = $true
      }
    }
  } catch {
    Log-Action 'ifeo_sidecar_parse' $false $_.Exception.Message
  }
}

if (-not (Test-Path -LiteralPath $vbsLauncher)) {
  Log-Action 'ifeo_launcher_missing' $false "$vbsLauncher not deployed yet — nothing to sync"
} else {
  foreach ($exe in $activeExes.Keys) {
    if ($staticAlwaysExes -contains $exe) { continue }
    if (Test-ResolvesUnderWindowsDir $exe) {
      Log-Action "ifeo_register_$exe" $false 'refused — resolves under Windows dir'
      continue
    }
    $key = Join-Path $ifeoRoot $exe
    try {
      $existingDbg = (Get-ItemProperty -LiteralPath $key -Name Debugger -ErrorAction SilentlyContinue).Debugger
      if ($existingDbg -and -not (Test-OwnedIfeoDebugger $existingDbg)) {
        Log-Action "ifeo_register_$exe" $false 'skipped — Debugger already set by something else'
        continue
      }
      New-Item -Path $key -Force -ErrorAction Stop | Out-Null
      Set-ItemProperty -LiteralPath $key -Name Debugger -Value $newDbg -Type String -Force
      Log-Action "ifeo_register_$exe" $true 'launch-block active'
    } catch {
      Log-Action "ifeo_register_$exe" $false $_.Exception.Message
    }
  }

  Get-ChildItem $ifeoRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $exeName = $_.PSChildName.ToLowerInvariant()
    if ($staticAlwaysExes -contains $exeName) { return }
    if ($activeExes.ContainsKey($exeName)) { return }
    $dbg = (Get-ItemProperty -LiteralPath $_.PSPath -Name Debugger -ErrorAction SilentlyContinue).Debugger
    if (Test-OwnedIfeoDebugger $dbg) {
      try {
        Remove-ItemProperty -LiteralPath $_.PSPath -Name Debugger -ErrorAction SilentlyContinue
        Log-Action "ifeo_release_$exeName" $true 'no longer scheduled — launch-block removed'
      } catch {
        Log-Action "ifeo_release_$exeName" $false $_.Exception.Message
      }
    }
  }
}

$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir 'elevated_maintain_last.json') -Encoding UTF8
exit $(if ($report.ok) { 0 } else { 1 })
