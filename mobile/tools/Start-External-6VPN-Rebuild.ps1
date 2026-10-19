# Starts Rebuild-6VPN-Windows.ps1 in a **separate hidden PowerShell process**
# (not a child of the Flutter app). The app tails %LOCALAPPDATA%\SixVPNBlocker\
# rebuild_console.log for live UI.
#
# Called from the app via WScript (no visible window) or manually:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "...\Start-External-6VPN-Rebuild.ps1" `
#     -MobileRoot "C:\...\mobile" -FromApp

param(
  [Parameter(Mandatory = $true)][string] $MobileRoot,
  [switch] $FromApp
)

$ErrorActionPreference = 'Stop'

$statusDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $statusDir -ErrorAction SilentlyContinue | Out-Null

$launcherLog = Join-Path $statusDir 'external_launcher.log'
$pidFile     = Join-Path $statusDir 'rebuild_external.pid'
$lockFile    = Join-Path $statusDir 'rebuild_external.lock'

function Log([string]$Msg) {
  $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
  Add-Content -LiteralPath $launcherLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

Log "Start-External-6VPN-Rebuild.ps1 mobileRoot=$MobileRoot fromApp=$FromApp"

# Concurrency guard: if a rebuild is already in progress (lock file exists
# AND the PID it points at is still alive), refuse the second trigger so
# we don't fight over flutter pub get / pubspec.lock and end up with both
# processes silently dying mid-build (which is what bit the user at 23:08:
# two near-simultaneous triggers, neither produced any rebuild_console.log
# output). The lock auto-clears when the holding rebuild ends.
$existingPid = $null
if (Test-Path -LiteralPath $lockFile) {
  try {
    $existingPid = [int](Get-Content -LiteralPath $lockFile -Raw).Trim()
    $existingProc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
    if ($existingProc) {
      Log "REFUSED: another rebuild already running PID=$existingPid (lock=$lockFile). To force, delete the lock file."
      exit 0
    } else {
      Log "stale lock found (PID=$existingPid no longer alive) - clearing"
      Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
  } catch {
    Log "lock file unreadable; clearing: $($_.Exception.Message)"
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
  }
}

$mobileRoot = $MobileRoot.Trim().TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $mobileRoot 'pubspec.yaml'))) {
  Log "ERROR: pubspec.yaml not found under $mobileRoot"
  exit 2
}

$rebuild = Join-Path $mobileRoot 'tools\Rebuild-6VPN-Windows.ps1'
if (-not (Test-Path -LiteralPath $rebuild)) {
  Log "ERROR: missing $rebuild"
  exit 2
}

. (Join-Path $PSScriptRoot 'FlutterSdk.ps1')
$flutter = Get-FlutterBatPath
if (-not $flutter) {
  Log 'WARN: Flutter SDK not found - Rebuild script will try again'
}

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Single quoted argument string — array form splits paths at spaces (e.g.
# Desktop\app dev\…) so PowerShell sees -File 'C:\...\app' and exits instantly
# with no console log (in-app rebuild looked frozen at the session header).
$argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$rebuild`" -LaunchAfter"
if ($FromApp) { $argString += ' -RelaunchFromApp' }

try {
  $p = Start-Process -FilePath $psExe -ArgumentList $argString -WorkingDirectory $mobileRoot `
    -WindowStyle Hidden -PassThru -ErrorAction Stop
  $p.Id | Set-Content -LiteralPath $pidFile -Encoding UTF8 -NoNewline
  # Write lock file with the spawned rebuild PID. Rebuild-6VPN-Windows.ps1
  # removes the lock at the end of its run (success or failure).
  $p.Id | Set-Content -LiteralPath $lockFile -Encoding UTF8 -NoNewline
  Log "OK: detached rebuild PID=$($p.Id) script=$rebuild lock=$lockFile"
  exit 0
} catch {
  Log "ERROR: Start-Process failed: $_"
  exit 1
}
