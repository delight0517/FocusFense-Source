# Closes the running app (if any), then: flutter pub get && flutter build windows --release
# Use FULL path if your shell is not in the repo (e.g. PS C:\Windows\System32>):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\6VPN_Image_Blocker\mobile\tools\Rebuild-6VPN-Windows.ps1"
# From repo root: powershell -ExecutionPolicy Bypass -File "mobile\tools\Rebuild-6VPN-Windows.ps1"
# Optional: ... -WaitAtEnd   (press Enter before window closes - good for double-click)

param(
  [switch] $WaitAtEnd,
  # After a successful build + per-user install copy, start the installed exe again.
  [switch] $LaunchAfter,
  # Quiet CLI rebuild: no app window activation or interactive boot cleanup.
  [switch] $BackgroundLaunch,
  # Spawned from the running app: extra delay + taskkill + try to delete Release exe (avoids LNK1104).
  [switch] $RelaunchFromApp,
  # 2026-07-07: explicit, off-by-default escape hatch for the Firefox signed-
  # extension integrity gate. Only use when a human has confirmed the gate is
  # blocking on a KNOWN, already-triaged issue unrelated to the change being
  # shipped (e.g. signed_source_snapshot.json's pinned hash itself doesn't
  # match either the current source OR the actual shipped signed XPI, so no
  # amount of local file restoration can satisfy it without real AMO access).
  # Does not touch the Firefox extension or its signing artifacts in any way
  # - the bundled sixvpn_blocker_signed.xpi still ships exactly as-is.
  [switch] $SkipFirefoxGate,
  # Install only the app binary while preserving existing browser/startup/task integrations.
  [switch] $SkipSystemRepairs,
  # Preserve the user's existing shortcuts and Run/autostart registration.
  [switch] $SkipDuplicateCleanup
)

$ErrorActionPreference = "Continue"

# Force UTF-8 for stdout/stderr capture so flutter's ✓, em dashes, and
# Hangul progress text don't get mangled into "ÎÃªÃ" / "ï»¿" mojibake when
# read back by the Dart-side log tailer. Without this, PS 5.1 decodes
# child-process output with the OEM/ANSI codepage (cp949 on KR Windows).
try {
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [Console]::OutputEncoding = $utf8NoBom
  [Console]::InputEncoding = $utf8NoBom
  $OutputEncoding = $utf8NoBom
  # Tell flutter / dart / msbuild to also emit UTF-8 on their side.
  $env:PYTHONIOENCODING = 'utf-8'
  $env:DART_VM_OPTIONS = '--enable-experiment=stdio-utf8'
} catch {}

$statusDir = Join-Path $env:LOCALAPPDATA "SixVPNBlocker"
$statusFile = Join-Path $statusDir "rebuild_status.json"
# Console log: every line the rebuild script + flutter prints lands here.
# The monitor service tails this file so the in-app overlay shows live progress
# instead of a stuck "업데이트 준비 중" screen. Truncated to last ~500KB on each run.
$consoleLog = Join-Path $statusDir "rebuild_console.log"
$consoleLogPointer = Join-Path $statusDir "rebuild_console_active.txt"

# Ensure status dir exists FIRST so transcript + status file have a home.
New-Item -ItemType Directory -Force -Path $statusDir -ErrorAction SilentlyContinue | Out-Null

$script:utf8NoBomEnc = New-Object System.Text.UTF8Encoding $false

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content, [switch]$Append)
  if ($Append) {
    [System.IO.File]::AppendAllText($Path, $Content, $script:utf8NoBomEnc)
  } else {
    [System.IO.File]::WriteAllText($Path, $Content, $script:utf8NoBomEnc)
  }
}

function Initialize-ConsoleLog {
  try { Stop-Transcript | Out-Null } catch {}
  $script:consoleLog = Join-Path $statusDir "rebuild_console.log"
  $cleared = $false
  for ($i = 0; $i -lt 10; $i++) {
    try {
      if (Test-Path -LiteralPath $script:consoleLog) {
        Remove-Item -LiteralPath $script:consoleLog -Force -ErrorAction Stop
      }
      $cleared = $true
      break
    } catch {
      Start-Sleep -Milliseconds 350
    }
  }
  if (-not $cleared) {
    $script:consoleLog = Join-Path $statusDir ("rebuild_console_{0}.log" -f $PID)
    Write-Host "[sixvpn] using alternate log (app may be tailing): $script:consoleLog" -ForegroundColor Yellow
  }
  try {
    Write-Utf8NoBom -Path $consoleLogPointer -Content $script:consoleLog
  } catch {}
  try {
    $ver = 'unknown'
    $pub = Join-Path (Split-Path -Parent $PSScriptRoot) 'pubspec.yaml'
    if (Test-Path -LiteralPath $pub) {
      $m = Select-String -LiteralPath $pub -Pattern '^\s*version:\s*(.+)$' | Select-Object -First 1
      if ($m) { $ver = $m.Matches[0].Groups[1].Value.Trim() }
    }
    $header = "=== 6 VPN Blocker rebuild v$ver $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`r`n"
    Write-Utf8NoBom -Path $script:consoleLog -Content $header
  } catch {
    Write-Host "[sixvpn] console log init failed: $_" -ForegroundColor Yellow
  }
}

function Write-ConsoleLogLine {
  param([string]$Line)
  if ($null -eq $Line) { return }
  $s = "$Line".TrimEnd()
  if ($s.Length -eq 0) { return }
  try {
    Write-Utf8NoBom -Path $consoleLog -Content ($s + "`r`n") -Append
  } catch {
    # App may be tailing the file — skip line rather than fail the build.
  }
}

function Invoke-LoggedFlutter {
  param([Parameter(Mandatory = $true)][string[]]$FlutterArgs)
  Write-ConsoleLogLine ("--- flutter " + ($FlutterArgs -join ' ') + " ---")
  $output = & $flutter @FlutterArgs 2>&1
  $exit = $LASTEXITCODE
  foreach ($line in @($output)) {
    $text = "$line"
    Write-Host $text
    Write-ConsoleLogLine $text
  }
  Write-ConsoleLogLine "--- exit $exit ---"
  return $exit
}

# Mirror Write-Host into the tailed console log so the in-app overlay shows
# post-build steps (copy, shortcuts, OS integration). Without this, the user
# sees "--- exit 0 ---" and assumes the script froze while it's still working.
function Write-Step {
  param([string]$Message, [string]$Color = 'Cyan')
  Write-Host $Message -ForegroundColor $Color
  Write-ConsoleLogLine "[step] $Message"
}

Initialize-ConsoleLog

# Heartbeat: write the very first line of the new console log so the user
# (and the in-app tail) immediately sees that the rebuild process is alive.
# Without this, between Initialize-ConsoleLog and the first real step the
# log can look frozen — and if PS dies in that window (e.g. flutter pub get
# crash), the user has no signal that anything started.
$_bootTs = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-ConsoleLogLine "=== Rebuild-6VPN-Windows.ps1 started ($_bootTs) PID=$PID ==="
Write-ConsoleLogLine "[boot] PSVersion=$($PSVersionTable.PSVersion) WaitAtEnd=$WaitAtEnd LaunchAfter=$LaunchAfter RelaunchFromApp=$RelaunchFromApp SkipSystemRepairs=$SkipSystemRepairs"

# Clear our lock file on script end (success or crash) so the next manual
# trigger can run. Uses a trap so it fires even on unhandled errors.
$_lockPath = Join-Path $statusDir 'rebuild_external.lock'
$_clearLock = {
  if (Test-Path -LiteralPath $_lockPath) {
    try {
      Remove-Item -LiteralPath $_lockPath -Force -ErrorAction SilentlyContinue
      Write-ConsoleLogLine "[boot] lock cleared on exit"
    } catch {}
  }
}
trap {
  Write-ConsoleLogLine "[FATAL] uncaught error: $($_.Exception.Message)"
  Write-ConsoleLogLine "[FATAL] at: $($_.InvocationInfo.PositionMessage)"
  & $_clearLock
  exit 99
}
Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action $_clearLock | Out-Null

function Write-RebuildStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][string]$Message,
    [double]$Progress = -1,
    [bool]$RequestAppExit = $false,
    [int]$ExitCode = -999,
    [string]$ExePath = ""
  )
  try {
    New-Item -ItemType Directory -Force -Path $statusDir -ErrorAction SilentlyContinue | Out-Null
    $obj = [ordered]@{
      phase          = $Phase
      message        = $Message
      progress       = $Progress
      requestAppExit = $RequestAppExit
      exitCode       = $ExitCode
      exePath        = $ExePath
      updatedAt      = (Get-Date).ToString("o")
    }
    # UTF-8 **without** BOM — Dart jsonDecode fails on BOM and the in-app overlay
    # never leaves "starting" even after a successful build.
    $json = $obj | ConvertTo-Json -Compress
    Write-Utf8NoBom -Path $statusFile -Content $json
  } catch {
    Write-Host "[sixvpn] status write failed: $_" -ForegroundColor Yellow
  }
}

# Launch the freshly installed exe ASAP — post-install maintenance can continue after.
function Show-SixVpnCloseNotice {
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Body
  )
  try {
    $dir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
    $script = Join-Path $dir 'ShowSixVpnToast.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return }
    $payload = Join-Path $dir ('toast_rebuild_' + [guid]::NewGuid().ToString('N') + '.json')
    @{ title = $Title; body = $Body } |
      ConvertTo-Json -Compress |
      Set-Content -LiteralPath $payload -Encoding UTF8
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      $script,
      '-Payload',
      $payload
    ) -WindowStyle Hidden
  } catch {}
}

function Stop-SixVpnAppProcesses {
  param([int]$WaitMs = 5000)
  Show-SixVpnCloseNotice `
    -Title '6 VPN Blocker 업데이트 전환' `
    -Body '새 버전을 설치하기 위해 현재 앱 창을 닫고 곧 다시 실행합니다.'
  $names = @('FocusFense', 'six_clean_room', '6VPNBlocker')
  foreach ($n in $names) {
    $null = & cmd.exe /c "taskkill /F /IM $n.exe /T 2>nul"
    Stop-Process -Name $n -Force -ErrorAction SilentlyContinue
  }
  $deadline = [datetime]::UtcNow.AddMilliseconds($WaitMs)
  while ([datetime]::UtcNow -lt $deadline) {
    $left = Get-Process -Name $names -ErrorAction SilentlyContinue
    if (-not $left) { return $true }
    foreach ($n in $names) {
      $null = & cmd.exe /c "taskkill /F /IM $n.exe /T 2>nul"
      Stop-Process -Name $n -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 200
  }
  return -not (Get-Process -Name $names -ErrorAction SilentlyContinue)
}

function Invoke-SixVpnFastRelaunch {
  param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [switch]$RelaunchFromApp,
    [switch]$BackgroundLaunch
  )
  if (-not (Test-Path -LiteralPath $ExePath)) { return $false }
  if ($RelaunchFromApp) {
    Write-RebuildStatus -Phase 'relaunching' -Message '⑥ 새 창 열기 — 방금 설치한 exe 실행 (약 2~5초)' -Progress 0.96 -ExePath $ExePath
  } else {
    Write-RebuildStatus -Phase 'relaunching' -Message '⑥ 새 버전 실행 — 이전 창 강제 종료 후 재실행' -Progress 0.96 -ExePath $ExePath
  }
  Write-Step "Relaunching app (fast): $ExePath"
  $gone = Stop-SixVpnAppProcesses -WaitMs 6000
  if (-not $gone) {
    Write-Step 'Warning: old app process still present after force-kill retries.' 'Yellow'
  }
  Start-Sleep -Milliseconds 250
  $wd = Split-Path -LiteralPath $ExePath
  $launched = $false
  for ($li = 1; $li -le 4; $li++) {
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $ExePath
      $psi.WorkingDirectory = $wd
      $psi.UseShellExecute = $true
      if ($BackgroundLaunch) {
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.Arguments = '--background'
      }
      $null = [System.Diagnostics.Process]::Start($psi)
      Start-Sleep -Milliseconds 450
      $running = Get-Process -Name @('FocusFense', 'six_clean_room', '6VPNBlocker') -ErrorAction SilentlyContinue
      if ($running) {
        Write-Step "Relaunch OK (attempt $li, fast): pid=$($running[0].Id)" 'Green'
        $launched = $true
        break
      }
    } catch {
      Write-Step "Fast relaunch attempt $li failed: $_" 'Yellow'
    }
    Start-Sleep -Milliseconds 300
  }
  if (-not $launched) {
    try {
      if ($BackgroundLaunch) {
        Start-Process -FilePath $ExePath -ArgumentList @('--background') -WorkingDirectory $wd -WindowStyle Hidden | Out-Null
      } else {
        Start-Process -FilePath $ExePath -WorkingDirectory $wd -WindowStyle Normal | Out-Null
      }
      Start-Sleep -Milliseconds 500
      if (Get-Process -Name @('FocusFense', 'six_clean_room', '6VPNBlocker') -ErrorAction SilentlyContinue) {
        Write-Step 'Relaunch OK (Start-Process fallback, fast).' 'Green'
        $launched = $true
      }
    } catch {}
  }
  return $launched
}

$script:relaunchDone = $false

# Earliest possible status write — proves the script launched even before
# resolving the source root or finding Flutter. Without this, a hung
# `Resolve-SixVpnMobileRoot` (e.g. directory enumeration on a slow share)
# leaves the app stuck on the Dart-side initial "업데이트 준비 중" forever.
if ($RelaunchFromApp) {
  Write-RebuildStatus -Phase 'starting' -Message '① 준비 — 소스 폴더·Flutter 확인 (약 10초)' -Progress 0.05
}

$resolvePs1 = Join-Path $PSScriptRoot "Resolve-MobileRoot.ps1"
if (Test-Path -LiteralPath $resolvePs1) {
  . $resolvePs1
  $resolved = Resolve-SixVpnMobileRoot
  if ($resolved) {
    $mobileRoot = $resolved
  } else {
    $mobileRoot = Split-Path -Parent $PSScriptRoot
  }
} else {
  $mobileRoot = Split-Path -Parent $PSScriptRoot
}
Set-Location -LiteralPath $mobileRoot
# Fail before replacing the installed app if bundled packages lag their sources.
$packageVerifier = Join-Path (Split-Path -Parent $mobileRoot) 'tools\Pack-ChromiumExtensions.mjs'
& node $packageVerifier --verify
if ($LASTEXITCODE -ne 0) { throw 'Signed extension packages are stale. Run tools/Pack-ChromiumExtensions.mjs with the retained signing key before rebuilding.' }

# Fail before cleanup/runner unlock can close the installed app. The installed
# package can be newer than this checkout (for example, a recovered older
# source tree). Never let a stale source build silently replace a newer install.
$installedExeForVersionCheck = Join-Path $env:LOCALAPPDATA 'Programs\FocusFense\FocusFense.exe'
$sourcePubspecForVersionCheck = Join-Path $mobileRoot 'pubspec.yaml'
if ((Test-Path -LiteralPath $installedExeForVersionCheck) -and (Test-Path -LiteralPath $sourcePubspecForVersionCheck)) {
  $installedProductVersion = (Get-Item -LiteralPath $installedExeForVersionCheck).VersionInfo.ProductVersion
  $sourceVersionMatch = Select-String -LiteralPath $sourcePubspecForVersionCheck -Pattern '^\s*version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$' | Select-Object -First 1
  $installedVersionMatch = [regex]::Match([string]$installedProductVersion, '(\d+\.\d+\.\d+)\+(\d+)')
  if ($sourceVersionMatch -and $installedVersionMatch -and
      ([version]$sourceVersionMatch.Matches[0].Groups[1].Value -lt [version]$installedVersionMatch.Groups[1].Value -or
       ([version]$sourceVersionMatch.Matches[0].Groups[1].Value -eq [version]$installedVersionMatch.Groups[1].Value -and
        [int64]$sourceVersionMatch.Matches[0].Groups[2].Value -lt [int64]$installedVersionMatch.Groups[2].Value))) {
    $message = "STALE SOURCE BLOCKED: installed $installedProductVersion is newer than source $($sourceVersionMatch.Matches[0].Groups[0].Value). The app was not closed or modified. Restore/merge the newer source before rebuilding."
    Write-Step $message 'Red'
    Write-ConsoleLogLine $message
    if ($RelaunchFromApp) {
      Write-RebuildStatus -Phase 'failed' -Message '오래된 소스라 업데이트를 중단했습니다. 설치된 앱은 유지됩니다.' -Progress 0 -ExitCode 2 -ExePath $installedExeForVersionCheck
    }
    exit 2
  }
}

. (Join-Path $PSScriptRoot "Unlock-Windows-Runner.ps1")

if ($RelaunchFromApp) {
  Write-RebuildStatus -Phase 'starting' -Message '① 준비 — Flutter SDK 확인 (약 10초)' -Progress 0.12
}

. (Join-Path $PSScriptRoot "FlutterSdk.ps1")
$flutter = Get-FlutterBatPath
if (-not $flutter) {
  Write-Host "flutter.bat not found. Run mobile\tools\Ensure-FlutterOnPath.ps1 or set FLUTTER_ROOT." -ForegroundColor Red
  if ($RelaunchFromApp) {
    Write-RebuildStatus -Phase 'failed' -Message 'Flutter SDK를 찾지 못했습니다 (FLUTTER_ROOT 미설정?)' -Progress 0 -ExitCode 1
  }
  exit 1
}

$cleanupDup = Join-Path $PSScriptRoot 'Cleanup-Duplicate-6VPN.ps1'
if (-not $SkipDuplicateCleanup -and (Test-Path -LiteralPath $cleanupDup)) {
  Write-Step 'Closing duplicate app instances + legacy shortcuts…'
  try { & $cleanupDup -KillAll } catch { Write-Step "Duplicate cleanup (non-fatal): $_" 'Yellow' }
}

if (-not $RelaunchFromApp) {
  Write-Host "Unlocking Release runner (LNK1104 prevention)..." -ForegroundColor Cyan
  $unlockOk = Unlock-WindowsRunnerRelease -MobileRoot $mobileRoot -KillRunningApp
  if (-not $unlockOk) {
    Write-Host "WARN: Release folder still locked; build may retry after LNK1104." -ForegroundColor Yellow
  }
} elseif ($RelaunchFromApp) {
  Write-RebuildStatus -Phase 'starting' -Message '① 준비 — 패키지 다운로드 준비 (약 10초)' -Progress 0.14
}
Start-Sleep -Milliseconds 800

if ($RelaunchFromApp) {
  Write-RebuildStatus -Phase 'pub_get' -Message '② 패키지 — flutter pub get (약 30초~1분)' -Progress 0.18
}
Write-Host "flutter pub get..." -ForegroundColor Cyan
$pubExit = Invoke-LoggedFlutter -FlutterArgs @('pub', 'get')
if ($pubExit -ne 0) {
  Write-Host "pub get failed (exit $pubExit)." -ForegroundColor Red
  if ($RelaunchFromApp) {
    Write-RebuildStatus -Phase 'failed' -Message "pub get 실패 (exit $pubExit)" -Progress 0 -ExitCode $pubExit
  }
  if ($WaitAtEnd) { Write-Host "`nPress Enter to close..."; Read-Host | Out-Null }
  exit $pubExit
}

$iconScript = Join-Path $PSScriptRoot 'Sync-Windows-Taskbar-Icon.ps1'
if (Test-Path -LiteralPath $iconScript) {
  Write-Host 'Syncing Windows taskbar / exe icon...' -ForegroundColor Cyan
  & $iconScript
  if ($LASTEXITCODE -ne 0) {
    Write-Host 'WARN: icon sync failed; build continues with previous ICO.' -ForegroundColor Yellow
  }
}

if ($RelaunchFromApp) {
  Write-RebuildStatus -Phase 'pre_exit' -Message '③ 잠깐 닫힘 — exe 잠금 해제용 (3초 뒤 닫힘 → 빌드 2~4분 → 새 창 자동)' -Progress 0.42 -RequestAppExit $true
  Write-ConsoleLogLine 'pre_exit: UI 3초 안내 → 앱 종료 → flutter build'
  Start-Sleep -Seconds 3
}
$null = Unlock-WindowsRunnerRelease -MobileRoot $mobileRoot -KillRunningApp
if ($RelaunchFromApp) {
  Write-RebuildStatus -Phase 'building' -Message '④ 빌드 — flutter build windows (약 2~4분, 창 닫혀 있어도 정상)' -Progress 0.48
}

$firefoxIntegrity = Join-Path $PSScriptRoot 'Verify-Firefox-Integrity.ps1'
if ($SkipFirefoxGate) {
  Write-Host "Firefox integrity gate: SKIPPED via -SkipFirefoxGate (explicit human override)." -ForegroundColor Yellow
  Write-ConsoleLogLine "Firefox integrity gate: skipped via -SkipFirefoxGate"
} elseif (Test-Path -LiteralPath $firefoxIntegrity) {
  Write-Host "Checking Firefox signed extension integrity before build..." -ForegroundColor Cyan
  Write-ConsoleLogLine "Firefox integrity gate: start"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $firefoxIntegrity
  $firefoxIntegrityCode = $LASTEXITCODE
  if ($firefoxIntegrityCode -eq 2) {
    Write-Host "Firefox integrity gate FAILED. Build stopped before packaging a stale/unsigned Firefox plugin." -ForegroundColor Red
    Write-ConsoleLogLine "Firefox integrity gate: failed - blocking build"
    if ($RelaunchFromApp) {
      Write-RebuildStatus -Phase 'failed' -Message 'Firefox 플러그인 무결성 실패 — AMO 재서명 후 다시 빌드 필요' -Progress 0 -ExitCode 2
    }
    exit 2
  }
  if ($firefoxIntegrityCode -ne 0) {
    Write-Host "Firefox integrity gate warning (exit $firefoxIntegrityCode). Continuing, but check the verifier." -ForegroundColor Yellow
    Write-ConsoleLogLine "Firefox integrity gate: warning exit=$firefoxIntegrityCode"
  } else {
    Write-ConsoleLogLine "Firefox integrity gate: healthy"
  }
} else {
  Write-Host "Firefox integrity verifier missing; continuing without build gate." -ForegroundColor Yellow
  Write-ConsoleLogLine "Firefox integrity gate: verifier missing"
}

Write-Host "Building Windows release from: $mobileRoot" -ForegroundColor Cyan
$code = Invoke-LoggedFlutter -FlutterArgs @('build', 'windows', '--release')
$buildAttempt = 1
while ($code -ne 0 -and $buildAttempt -lt 4 -and (Test-ConsoleLogHasLnk1104 -LogPath $consoleLog)) {
  $buildAttempt++
  Write-Host "LNK1104 detected — unlock + rebuild attempt $buildAttempt/3..." -ForegroundColor Yellow
  Write-ConsoleLogLine "LNK1104 retry $buildAttempt — unlocking Release folder"
  if ($RelaunchFromApp) {
    Write-RebuildStatus -Phase 'building' -Message "exe 잠김 — 해제 후 빌드 재시도 ($buildAttempt/3)…" -Progress 0.5
  }
  $null = Unlock-WindowsRunnerRelease -MobileRoot $mobileRoot -KillRunningApp
  Start-Sleep -Milliseconds 1500
  $code = Invoke-LoggedFlutter -FlutterArgs @('build', 'windows', '--release')
}
if ($RelaunchFromApp -and $code -ne 0) {
  $lnk = Test-ConsoleLogHasLnk1104 -LogPath $consoleLog
  $hint = if ($lnk) { ' (FocusFense.exe 잠금 — 앱·탐색기 종료 후 다시 시도)' } else { '' }
  Write-RebuildStatus -Phase 'failed' -Message "빌드 실패 (exit $code)$hint" -Progress 0 -ExitCode $code
}
if ($code -ne 0) {
  Write-Step "Build failed (exit $code)." 'Red'
} else {
  Write-Step "Build OK — starting install/copy phase." 'Green'
  $releaseDir = Join-Path $mobileRoot "build\windows\x64\runner\Release"
  $installDir = Join-Path $env:LOCALAPPDATA "Programs\FocusFense"
  if (Test-Path -LiteralPath $releaseDir) {
    # The legacy process names are included so a previous build cannot hold
    # the old install directory open during migration.
    $appProcNames = @('FocusFense', 'six_clean_room', '6VPNBlocker')
    if ($RelaunchFromApp) {
      Write-RebuildStatus -Phase 'installing' -Message '⑤ 설치 — 새 exe 복사 (약 10~20초)' -Progress 0.82
      Write-Step "Waiting for UI process(es) to exit before install copy: $($appProcNames -join ', ')"
      $waitSec = 0
      while ($waitSec -lt 24) {
        $procs = Get-Process -Name $appProcNames -ErrorAction SilentlyContinue
        if (-not $procs) { break }
        Start-Sleep -Milliseconds 500
        $waitSec++
      }
      if (Get-Process -Name $appProcNames -ErrorAction SilentlyContinue) {
        Write-Step "App still running; force-kill before install copy." 'Yellow'
        Stop-SixVpnAppProcesses -WaitMs 6000 | Out-Null
      }
      Write-RebuildStatus -Phase 'installing' -Message '⑤ 설치 — Programs 폴더에 복사 중 (약 10초)' -Progress 0.88
    } else {
      # Manual/double-click rebuild must also clear the lock, otherwise the
      # install copy hits the same Access-denied loop on the alias.
      if (Get-Process -Name $appProcNames -ErrorAction SilentlyContinue) {
        Write-Step "App running; force-kill before install copy (manual rebuild)." 'Yellow'
        Stop-SixVpnAppProcesses -WaitMs 6000 | Out-Null
      }
    }
    $installOk = $false
    Write-Step "Copying release to per-user install: $installDir"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    for ($ci = 0; $ci -lt 12; $ci++) {
      try {
        Get-ChildItem -LiteralPath $installDir -ErrorAction SilentlyContinue |
          Remove-Item -Recurse -Force -ErrorAction Stop
        Copy-Item -Path (Join-Path $releaseDir '*') -Destination $installDir -Recurse -Force -ErrorAction Stop
        $installOk = $true
        Write-Step "Per-user install updated (same path every build - shortcuts stay valid)." 'Green'
        $uninstallerSource = Join-Path $PSScriptRoot 'Uninstall-FocusFense.ps1'
        if (Test-Path -LiteralPath $uninstallerSource) {
          $uninstallerPath = Join-Path $installDir 'Uninstall-FocusFense.ps1'
          Copy-Item -LiteralPath $uninstallerSource -Destination $uninstallerPath -Force
          $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FocusFense'
          New-Item -Path $uninstallKey -Force | Out-Null
          Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayName -Value 'Focus Fense'
          $installedVersion = (Get-Item -LiteralPath (Join-Path $installDir 'FocusFense.exe')).VersionInfo.ProductVersion
          Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value $installedVersion
          Set-ItemProperty -LiteralPath $uninstallKey -Name Publisher -Value 'Focus Fense'
          Set-ItemProperty -LiteralPath $uninstallKey -Name InstallLocation -Value $installDir
          Set-ItemProperty -LiteralPath $uninstallKey -Name UninstallString -Value ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'), $uninstallerPath)
          Set-ItemProperty -LiteralPath $uninstallKey -Name NoModify -Type DWord -Value 1
          Set-ItemProperty -LiteralPath $uninstallKey -Name NoRepair -Type DWord -Value 1
          $startMenuPrograms = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
          New-Item -ItemType Directory -Path $startMenuPrograms -Force | Out-Null
          $uninstallShortcut = Join-Path $startMenuPrograms 'Uninstall Focus Fense.lnk'
          $wsh = New-Object -ComObject WScript.Shell
          $link = $wsh.CreateShortcut($uninstallShortcut)
          $link.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
          $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $uninstallerPath
          $link.WorkingDirectory = $installDir
          $link.Save()
          Write-Step 'Focus Fense one-step uninstaller registered in Windows Apps.' 'Green'
        } else {
          Write-Step 'Uninstaller helper source missing; install copy skipped.' 'Yellow'
        }
        $iconCopy = Join-Path $PSScriptRoot 'Copy-SixVpnInstallIcon.ps1'
        if (Test-Path -LiteralPath $iconCopy) {
          & $iconCopy -MobileRoot $mobileRoot -InstallDir $installDir
        }
        break
      } catch {
        Write-Host "Install copy attempt $($ci+1) failed: $_" -ForegroundColor Yellow
        Start-Sleep -Milliseconds 800
      }
    }
    if (-not $installOk) {
      Write-Host "Install copy failed after retries - LaunchAfter will use Release\FocusFense.exe if present." -ForegroundColor Yellow
    }
    # Bootstrap flag + fast relaunch BEFORE chrome pack / icon cache so the user
    # sees the new window within seconds of install — not after 20–30s of maintenance.
    if ($installOk -and $LaunchAfter -and ($code -eq 0)) {
      try {
        $pendingBootstrap = Join-Path $statusDir 'post_rebuild_bootstrap_pending.txt'
        $noAutoRepo = Join-Path $mobileRoot 'tools\NO_AUTO_REBUILD'
        $noAutoLocal = Join-Path $statusDir 'no_auto_rebuild.flag'
        if (-not $BackgroundLaunch -and -not ((Test-Path -LiteralPath $noAutoRepo) -or (Test-Path -LiteralPath $noAutoLocal))) {
          $buildLabel = 'unknown'
          $pub = Join-Path $mobileRoot 'pubspec.yaml'
          if (Test-Path -LiteralPath $pub) {
            $m = Select-String -LiteralPath $pub -Pattern '^\s*version:\s*(.+)$' | Select-Object -First 1
            if ($m) { $buildLabel = $m.Matches[0].Groups[1].Value.Trim() }
          }
          Write-Utf8NoBom -Path $pendingBootstrap -Content $buildLabel
        }
      } catch {}
      $installExe = Join-Path $env:LOCALAPPDATA 'Programs\FocusFense\FocusFense.exe'
      if (Test-Path -LiteralPath $installExe) {
        if (Invoke-SixVpnFastRelaunch -ExePath $installExe -RelaunchFromApp:$RelaunchFromApp -BackgroundLaunch:$BackgroundLaunch) {
          $script:relaunchDone = $true
        }
      }
    }
    if ($SkipSystemRepairs) {
      Write-Step 'System integration, desktop cleanup, and browser payload repairs skipped; existing protection state preserved.' 'Yellow'
    } else {
    $desktopCleanup = Join-Path $PSScriptRoot "Remove-6VPN-Desktop-Artifacts.ps1"
    if (Test-Path -LiteralPath $desktopCleanup) {
      try {
        & $desktopCleanup
        Write-Step "Desktop .lnk/.bat cleanup done (auto-create disabled)." 'Green'
      } catch {
        Write-Step "Desktop cleanup failed (non-fatal): $_" 'Yellow'
      }
    }
    $osIntegration = Join-Path $PSScriptRoot "Install-Windows-OsIntegration.ps1"
    if (Test-Path -LiteralPath $osIntegration) {
      try {
        & $osIntegration
        Write-Step "Start Menu search + autostart refreshed." 'Green'
      } catch {
        Write-Step "OS integration failed (non-fatal): $_" 'Yellow'
      }
    }
    $firefoxRepair = Join-Path $PSScriptRoot 'Repair-Firefox-Policies.ps1'
    if (Test-Path -LiteralPath $firefoxRepair) {
      try {
        & $firefoxRepair -NoElevate
        Write-Step "Firefox policies repair attempted (no UAC)." 'Green'
      } catch {
        Write-Step "Firefox repair failed (non-fatal): $_" 'Yellow'
      }
    }
    $chromePayload = Join-Path $PSScriptRoot 'Repair-ChromeExtensionPayload.ps1'
    if (Test-Path -LiteralPath $chromePayload) {
      try {
        & $chromePayload
        Write-Step "Chrome extension payload repaired (LOCALAPPDATA)." 'Green'
      } catch {
        Write-Step "Chrome payload repair failed (non-fatal): $_" 'Yellow'
      }
    }
    # Deploy the verified bundled CRX without launching a browser or generating
    # a new signing key on the user's computer.
    try {
      $cb = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\chrome_blocker'
      $packageAsset = Join-Path $releaseDir 'data\flutter_assets\assets\browser_extensions\chrome\chrome_blocker.crx'
      $metadata = Get-Content -LiteralPath ($packageAsset + '.manifest.json') -Raw | ConvertFrom-Json
      function Get-BundledCrxDigest([string]$Path) {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($algorithm.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-','').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
      }
      if ($metadata.extensionId -ne 'popjkofklmidngceakpcokopghehjngo' -or (Get-BundledCrxDigest $packageAsset) -ne $metadata.sha256) { throw 'Bundled CRX identity/hash mismatch' }
      foreach ($entry in $metadata.files.PSObject.Properties) {
        if ($entry.Name -ne [IO.Path]::GetFileName($entry.Name)) { throw 'Invalid CRX metadata path' }
        if ((Get-BundledCrxDigest (Join-Path $cb $entry.Name)) -ne $entry.Value) { throw ('Payload differs from signed CRX: ' + $entry.Name) }
      }
      Copy-Item -LiteralPath $packageAsset -Destination ($cb + '.crx') -Force
      $crxUrl = 'file:///' + (($cb + '.crx') -replace '\\', '/')
      $xml = "<?xml version='1.0' encoding='UTF-8'?><gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'><app appid='$($metadata.extensionId)'><updatecheck codebase='$crxUrl' version='$($metadata.version)' hash_sha256='$($metadata.sha256)' /></app></gupdate>"
      Set-Content -LiteralPath (Join-Path $cb 'updates.xml') -Value $xml -Encoding UTF8
      Write-Step 'Verified bundled Chrome CRX deployed without a browser launch.' 'Green'
    } catch {
      Write-Step "Signed CRX deployment incomplete: $_" 'Yellow'
    }
    }
    $autoShower = Join-Path $PSScriptRoot 'Invoke-RebuildAutoShower.ps1'
    if (-not $BackgroundLaunch -and (Test-Path -LiteralPath $autoShower)) {
      try {
        $buildLabel = 'unknown'
        $pub = Join-Path $mobileRoot 'pubspec.yaml'
        if (Test-Path -LiteralPath $pub) {
          $m = Select-String -LiteralPath $pub -Pattern '^\s*version:\s*(.+)$' | Select-Object -First 1
          if ($m) { $buildLabel = $m.Matches[0].Groups[1].Value.Trim() }
        }
        & $autoShower -BuildLabel $buildLabel
        Write-Step "Rebuild auto-shower queued ($buildLabel)." 'Green'
      } catch {
        Write-Step "Auto-shower script failed (non-fatal): $_" 'Yellow'
      }
    }
    try {
      $pendingBootstrap = Join-Path $statusDir 'post_rebuild_bootstrap_pending.txt'
      $noAutoRepo = Join-Path $mobileRoot 'tools\NO_AUTO_REBUILD'
      $noAutoLocal = Join-Path $statusDir 'no_auto_rebuild.flag'
      $skipBootstrapPending = $BackgroundLaunch -or $SkipSystemRepairs -or (Test-Path -LiteralPath $noAutoRepo) -or (Test-Path -LiteralPath $noAutoLocal)
      if (-not $skipBootstrapPending) {
        $buildLabel = 'unknown'
        $pub = Join-Path $mobileRoot 'pubspec.yaml'
        if (Test-Path -LiteralPath $pub) {
          $m = Select-String -LiteralPath $pub -Pattern '^\s*version:\s*(.+)$' | Select-Object -First 1
          if ($m) { $buildLabel = $m.Matches[0].Groups[1].Value.Trim() }
        }
        if (-not (Test-Path -LiteralPath $pendingBootstrap)) {
          Write-Utf8NoBom -Path $pendingBootstrap -Content $buildLabel
        }
        Write-Step "Post-rebuild auto-check queued for next app launch ($buildLabel)." 'Green'
      } else {
        Write-Step "Post-rebuild bootstrap skipped (NO_AUTO_REBUILD — light sync only on next manual launch)." 'Yellow'
        if (Test-Path -LiteralPath $pendingBootstrap) {
          Remove-Item -LiteralPath $pendingBootstrap -Force -ErrorAction SilentlyContinue
        }
      }
    } catch {
      Write-Step "Post-rebuild bootstrap flag failed (non-fatal): $_" 'Yellow'
    }
    $iconRefresh = Join-Path $PSScriptRoot 'Refresh-WindowsIconCache.ps1'
    if (-not $BackgroundLaunch -and (Test-Path -LiteralPath $iconRefresh)) {
      try {
        & $iconRefresh
        Write-Step "Windows icon cache refreshed." 'Green'
      } catch {
        Write-Step "Icon cache refresh failed (non-fatal): $_" 'Yellow'
      }
    }
  } else {
    Write-Step "Release folder not found at $releaseDir - skip per-user install copy." 'Yellow'
  }
}
if ($LaunchAfter -and ($code -eq 0) -and -not $script:relaunchDone) {
  $installExe = Join-Path $env:LOCALAPPDATA "Programs\FocusFense\FocusFense.exe"
  $releaseExe = Join-Path $mobileRoot "build\windows\x64\runner\Release\FocusFense.exe"
  $toLaunch = $null
  if (Test-Path -LiteralPath $installExe) {
    $toLaunch = $installExe
  } elseif (Test-Path -LiteralPath $releaseExe) {
    $toLaunch = $releaseExe
  }
  if ($null -ne $toLaunch) {
    $launched = Invoke-SixVpnFastRelaunch -ExePath $toLaunch -RelaunchFromApp:$RelaunchFromApp -BackgroundLaunch:$BackgroundLaunch
    if ($launched) { $script:relaunchDone = $true }

    if (-not $launched) {
      $relaunchHelper = Join-Path $PSScriptRoot "Relaunch-SixVpnApp.ps1"
      if (-not $BackgroundLaunch -and (Test-Path -LiteralPath $relaunchHelper)) {
        Write-Step "Inline launch failed — spawning detached relaunch helper as last resort." 'Yellow'
        $ps64 = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        try {
          Start-Process -FilePath $ps64 -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $relaunchHelper,
            '-ExePath', $toLaunch,
            '-DelayMs', '500'
          ) -WindowStyle Hidden | Out-Null
          Write-Step "Detached helper started — will retry launch in 2s." 'Green'
        } catch {
          Write-Step "Detached helper spawn failed: $_" 'Red'
        }
      } else {
        Write-Step "Relaunch helper script missing: $relaunchHelper" 'Red'
      }
    }

    if (-not $launched) {
      Write-Step "App did not relaunch automatically — open the desktop shortcut to start it manually." 'Red'
      if ($RelaunchFromApp) {
        Write-RebuildStatus -Phase 'failed' -Message '재시작 실패 — 데스크톱 바로가기에서 직접 실행해주세요.' -Progress 0.98 -ExitCode 0
      }
    }
  } else {
    Write-Step "LaunchAfter: no exe at install path or Release folder:" 'Yellow'
    Write-Step "  $installExe" 'Yellow'
    Write-Step "  $releaseExe" 'Yellow'
  }
}
if ($code -eq 0) {
  Write-RebuildStatus -Phase 'done' -Message '업데이트 완료' -Progress 1 -ExitCode 0
  foreach ($stale in @(
      (Join-Path $statusDir 'rebuild_external.pid'),
      (Join-Path $statusDir 'rebuild_session.json')
    )) {
    if (Test-Path -LiteralPath $stale) {
      try { Remove-Item -LiteralPath $stale -Force -ErrorAction Stop } catch {}
    }
  }
  if (Test-Path -LiteralPath $resolvePs1) {
    Write-SixVpnMobileRootMarker -Root $mobileRoot | Out-Null
    Write-Step "Saved rebuild path marker for next in-app rebuild."
  }
  $gateTools = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\tools'
  $gateScript = Join-Path $PSScriptRoot 'Test-AllBrowsers-UrlBlock.ps1'
  if (Test-Path -LiteralPath $gateScript) {
    New-Item -ItemType Directory -Force -Path $gateTools | Out-Null
    Copy-Item -LiteralPath $gateScript -Destination (Join-Path $gateTools 'Test-AllBrowsers-UrlBlock.ps1') -Force
    Write-Step "Deployed Test-AllBrowsers-UrlBlock.ps1 to $gateTools"
  }
  $firefoxBlueprintScript = Join-Path $PSScriptRoot 'Apply-Firefox-Blueprint-Now.ps1'
  if (Test-Path -LiteralPath $firefoxBlueprintScript) {
    New-Item -ItemType Directory -Force -Path $gateTools | Out-Null
    Copy-Item -LiteralPath $firefoxBlueprintScript -Destination (Join-Path $gateTools 'Apply-Firefox-Blueprint-Now.ps1') -Force
    Write-Step "Deployed Apply-Firefox-Blueprint-Now.ps1 to $gateTools"
  }
  Write-ConsoleLogLine "=== Rebuild complete — exit 0 — all post-build steps finished ==="
} elseif ($RelaunchFromApp) {
  Write-RebuildStatus -Phase 'failed' -Message "빌드/설치 실패 (exit $code)" -Progress 0 -ExitCode $code
  Write-ConsoleLogLine "=== Rebuild FAILED — exit $code ==="
} else {
  Write-ConsoleLogLine "=== Rebuild FAILED — exit $code ==="
}
if ($WaitAtEnd) {
  Write-Host "`nPress Enter to close..."
  Read-Host | Out-Null
}
exit $code
