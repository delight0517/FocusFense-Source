# Stops six_clean_room and archives build\windows\x64\runner\Release so
# `flutter build windows --release` can link a fresh six_clean_room.exe (LNK1104 fix).

function Stop-SixVpnRunnerProcesses {
  foreach ($n in @('six_clean_room', '6VPNBlocker')) {
    $null = & cmd.exe /c "taskkill /F /IM $n.exe /T 2>nul"
    Get-Process -Name $n -ErrorAction SilentlyContinue |
      Stop-Process -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 800
}

function Prune-ArchivedWindowsReleases {
  param(
    [Parameter(Mandatory = $true)][string] $MobileRoot,
    [int]$Keep = 1
  )
  $runnerDir = Join-Path $MobileRoot 'build\windows\x64\runner'
  if (-not (Test-Path -LiteralPath $runnerDir)) { return }
  $archived = Get-ChildItem -LiteralPath $runnerDir -Directory -Filter 'Release_archived_*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending
  foreach ($dir in $archived | Select-Object -Skip $Keep) {
    try {
      Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
      Write-Host "[sixvpn] Pruned old archive: $($dir.Name)" -ForegroundColor DarkGray
    } catch {
      Write-Host "[sixvpn] Could not prune $($dir.Name): $_" -ForegroundColor Yellow
    }
  }
}

function Unlock-WindowsRunnerRelease {
  param(
    [Parameter(Mandatory = $true)][string] $MobileRoot,
    [int]$MaxAttempts = 32,
    [switch]$KillRunningApp
  )
  if ($KillRunningApp) {
    Stop-SixVpnRunnerProcesses
  }
  $releaseDir = Join-Path $MobileRoot "build\windows\x64\runner\Release"
  $runnerDir = Split-Path -Parent $releaseDir
  if (-not (Test-Path -LiteralPath $runnerDir)) {
    New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null
  }
  if (-not (Test-Path -LiteralPath $releaseDir)) {
    New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
    return $true
  }
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $archived = Join-Path $runnerDir ("Release_archived_" + $stamp)
  for ($i = 0; $i -lt $MaxAttempts; $i++) {
    try {
      Rename-Item -LiteralPath $releaseDir -NewName (Split-Path -Leaf $archived) -Force -ErrorAction Stop
      Write-Host "[sixvpn] Archived locked Release -> $archived" -ForegroundColor Green
      Prune-ArchivedWindowsReleases -MobileRoot $MobileRoot -Keep 1
      New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
      return $true
    } catch {
      try {
        Remove-Item -LiteralPath $releaseDir -Recurse -Force -ErrorAction Stop
        Write-Host "[sixvpn] Removed Release folder" -ForegroundColor Green
        New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
        return $true
      } catch {
        if ($KillRunningApp) {
          Stop-SixVpnRunnerProcesses
        }
        Start-Sleep -Milliseconds 450
      }
    }
  }
  return $false
}

function Test-ConsoleLogHasLnk1104 {
  param([string]$LogPath)
  if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $false }
  try {
    $tail = Get-Content -LiteralPath $LogPath -Tail 40 -ErrorAction SilentlyContinue
    return ($tail -join "`n") -match 'LNK1104'
  } catch {
    return $false
  }
}
