# Mirrors the HKCU\...\Run autostart value into HKLM so:
#   - the entry survives "Disable in Task Manager > Startup" (which only
#     flips the per-user StartupApproved key);
#   - any user logging into this PC autostarts the blocker, not just the
#     user that installed it.
#
# Requires admin (HKLM\SOFTWARE is read-only for non-admins). Invoked from
# the app via `Start-Process -Verb RunAs` → UAC prompt → this script.
#
# Args: -ExePath <absolute path to six_clean_room.exe>
#       -Remove  (delete the HKLM entry instead of installing it)
param(
  [Parameter(Mandatory = $true)] [string] $ExePath,
  [switch] $Remove
)

$ErrorActionPreference = 'Stop'

$runKeyPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$valueName  = 'SixVPNBlocker'

try {
  $runKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($runKeyPath, $true)
  if (-not $runKey) {
    $runKey = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($runKeyPath)
  }
  if ($Remove) {
    try { $runKey.DeleteValue($valueName, $false) } catch {}
    Write-Host "HKLM autostart: removed $valueName"
    exit 0
  }

  if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Error "EXE not found: $ExePath"
    exit 2
  }

  # Bare quoted EXE — same shape as the HKCU value the Dart side writes.
  # We do NOT wrap with cmd /c start /D — Flutter Desktop resolves
  # data\flutter_assets relative to the module path, so working directory
  # is irrelevant. (And reg.exe-style /d "..." would corrupt embedded
  # quotes, which is exactly the bug we just shipped a fix for in
  # HKCU\...\Run.)
  $value = '"' + $ExePath + '"'
  $runKey.SetValue($valueName, $value, [Microsoft.Win32.RegistryValueKind]::String)

  Write-Host "HKLM autostart: $valueName = $value"
  exit 0
} catch {
  Write-Error "HKLM autostart write failed: $_"
  exit 1
} finally {
  if ($runKey) { $runKey.Close() }
}
