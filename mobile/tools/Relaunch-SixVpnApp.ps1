# Waits for install copy / AV, then starts six_clean_room (used after in-app rebuild).
param(
  [Parameter(Mandatory = $true)][string]$ExePath,
  [int]$DelayMs = 3500
)

$ErrorActionPreference = 'Continue'
if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }

if (-not (Test-Path -LiteralPath $ExePath)) {
  Write-Host "[Relaunch] exe not found: $ExePath" -ForegroundColor Red
  exit 1
}

$wd = Split-Path -LiteralPath $ExePath
$procName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)

function Test-AppRunning {
  param([string]$FullPath)
  $want = (Resolve-Path -LiteralPath $FullPath).Path
  $procs = Get-CimInstance Win32_Process -Filter "Name = '$procName.exe'" -ErrorAction SilentlyContinue
  foreach ($p in $procs) {
    $ep = $p.ExecutablePath
    if (-not $ep) { continue }
    try {
      if ((Resolve-Path -LiteralPath $ep).Path -ieq $want) { return $true }
    } catch { }
  }
  return $false
}

for ($i = 0; $i -lt 10; $i++) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.WorkingDirectory = $wd
    $psi.UseShellExecute = $true
    $null = [System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 1200
    if (Test-AppRunning -FullPath $ExePath) {
      Write-Host "[Relaunch] OK (UseShellExecute): $ExePath" -ForegroundColor Green
      exit 0
    }
  } catch {
    Write-Host "[Relaunch] attempt $($i+1): $_" -ForegroundColor Yellow
  }
  Start-Sleep -Milliseconds 700
}

try {
  Start-Process -FilePath $ExePath -WorkingDirectory $wd -WindowStyle Normal | Out-Null
  Start-Sleep -Milliseconds 1200
  if (Test-AppRunning -FullPath $ExePath) {
    Write-Host "[Relaunch] OK (Start-Process): $ExePath" -ForegroundColor Green
    exit 0
  }
} catch {
  Write-Host "[Relaunch] Start-Process failed: $_" -ForegroundColor Yellow
}

try {
  Invoke-Item -LiteralPath $ExePath
  Write-Host "[Relaunch] invoked: $ExePath" -ForegroundColor Green
  exit 0
} catch {
  Write-Host "[Relaunch] all methods failed: $_" -ForegroundColor Red
  exit 1
}
