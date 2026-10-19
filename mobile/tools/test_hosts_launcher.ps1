# Mimics six_clean_room UAC hosts elevation: UTF-8 BOM script + sentinel result.txt
# Run: powershell -ExecutionPolicy Bypass -File tools\test_hosts_launcher.ps1
# From repo: mobile\ directory (or pass -MobileRoot)

param(
  [string]$MobileRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sixvpn_harness_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  $resultFile = Join-Path $tmp 'result.txt'
  $scriptFile = Join-Path $tmp 'elevate.ps1'
  $payloadFile = Join-Path $tmp 'payload.txt'
  Set-Content -LiteralPath $payloadFile -Value '' -Encoding UTF8

  $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  $markerStart = '# === 6 VPN Blocker BEGIN (managed) ==='
  $markerEnd = '# === 6 VPN Blocker END (managed) ==='

  $inner = @'
param(
  [Parameter(Mandatory = $true)][string]$PayloadPath,
  [Parameter(Mandatory = $true)][string]$HostsPath,
  [Parameter(Mandatory = $true)][string]$MarkerStart,
  [Parameter(Mandatory = $true)][string]$MarkerEnd,
  [Parameter(Mandatory = $false)][string]$PolicySource = '',
  [Parameter(Mandatory = $true)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
try {
  if (-not (Test-Path -LiteralPath $HostsPath)) { throw "hosts not found" }
  $orig = [System.IO.File]::ReadAllText($HostsPath, $utf8)
  $i = $orig.IndexOf($MarkerStart)
  $j = $orig.IndexOf($MarkerEnd)
  $nl = [Environment]::NewLine
  if ($i -ge 0 -and $j -gt $i) {
    $before = $orig.Substring(0, $i).TrimEnd()
    $after = $orig.Substring($j + $MarkerEnd.Length).TrimStart()
    $merged = $before + $nl + $nl + $after
  } else { $merged = $orig.TrimEnd() }
  $payload = [System.IO.File]::ReadAllText($PayloadPath, $utf8)
  if ($payload.Trim().Length -gt 0) {
    $merged = $merged.TrimEnd() + $nl + $nl + $payload.Trim() + $nl
  }
  [System.IO.File]::WriteAllText($HostsPath, $merged, $utf8)
  Set-Content -LiteralPath $ResultPath -Value '0' -Encoding ascii -NoNewline
} catch {
  try {
    $_.Exception.Message | Set-Content -LiteralPath $ResultPath -Encoding UTF8 -Force
    Add-Content -LiteralPath $ResultPath -Value '1' -Encoding ascii
  } catch { Set-Content -LiteralPath $ResultPath -Value '1' -Encoding ascii -NoNewline }
}
'@

  $bom = [byte[]](0xEF, 0xBB, 0xBF)
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $bytes = $bom + $utf8NoBom.GetBytes($inner)
  [System.IO.File]::WriteAllBytes($scriptFile, $bytes)

  function Q([string]$s) { return "'" + ($s -replace "'", "''") + "'" }
  $argList = @(
    Q('-NoProfile'), Q('-ExecutionPolicy'), Q('Bypass'), Q('-WindowStyle'), Q('Hidden'), Q('-File'), Q($scriptFile.FullName),
    Q('-PayloadPath'), Q($payloadFile.FullName),
    Q('-HostsPath'), Q($hostsPath),
    Q('-MarkerStart'), Q($markerStart),
    Q('-MarkerEnd'), Q($markerEnd),
    Q('-PolicySource'), Q(''),
    Q('-ResultPath'), Q($resultFile.FullName)
  ) -join ','

  $cmd = "`$ErrorActionPreference = 'Stop'; " +
    "`$p = Start-Process -FilePath powershell.exe -ArgumentList @($argList) -Verb RunAs -Wait -PassThru; " +
    "if (`$null -eq `$p) { exit 1 } elseif (`$null -ne `$p.ExitCode) { exit [int]`$p.ExitCode } else { exit 0 }"

  $pr = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -Wait -PassThru -NoNewWindow
  Write-Host "OuterExitCode: $($pr.ExitCode)"

  Write-Host '--- Sentinel ---'
  if (Test-Path -LiteralPath $resultFile) {
    Get-Content -LiteralPath $resultFile -Raw | Write-Host
    $raw = (Get-Content -LiteralPath $resultFile -Raw).Trim()
    $lines = $raw -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    $last = $lines[-1]
    if ($last -eq '0') {
      Write-Host 'SUCCESS: elevated child reported 0 (read/write hosts path succeeded).'
    }
  } else {
    Write-Host '<missing> (UAC denied or child did not run)'
  }
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
