param(
  [string[]]$BrowserExe = @(
    'chrome.exe',
    'brave.exe',
    'opera.exe',
    'opera_gx.exe',
    'firefox.exe',
    'msedge.exe'
  ),
  [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$ifeoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$ownedMarkers = @(
  'SixVPNBlocker',
  'BlockedBrowserToastLauncher',
  'ShowBlockedBrowserToast'
)

$results = foreach ($exe in $BrowserExe) {
  $key = Join-Path $ifeoRoot $exe
  $debugger = (Get-ItemProperty -LiteralPath $key -Name Debugger -ErrorAction SilentlyContinue).Debugger
  $owned = $false
  foreach ($marker in $ownedMarkers) {
    if ($debugger -and $debugger.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
      $owned = $true
      break
    }
  }

  if ($owned) {
    Remove-ItemProperty -LiteralPath $key -Name Debugger -ErrorAction Stop
    [pscustomobject]@{
      BrowserExe = $exe
      Action = 'RemovedSixVpnDebugger'
      PreviousDebugger = $debugger
    }
  } else {
    [pscustomobject]@{
      BrowserExe = $exe
      Action = if ($debugger) { 'SkippedNonSixVpnDebugger' } else { 'NoDebugger' }
      PreviousDebugger = $debugger
    }
  }
}

$json = $results | ConvertTo-Json -Depth 4
if ($OutputPath) {
  $dir = Split-Path -Parent $OutputPath
  if ($dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
}
$json
