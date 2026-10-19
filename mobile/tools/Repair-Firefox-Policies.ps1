# Fixes broken Firefox policies.json (InstallSources nested inside ExtensionSettings).
param(
  [switch] $LaunchFirefox,
  [switch] $Elevate,
  [switch] $RemoveBroken,
  [switch] $NoElevate
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Elevate -and -not (Test-IsAdmin)) {
  $self = $PSCommandPath
  $argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $self + '"'
  if ($LaunchFirefox) { $argList += ' -LaunchFirefox' }
  if ($RemoveBroken) { $argList += ' -RemoveBroken' }
  $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru
  exit $(if ($null -ne $p.ExitCode) { [int]$p.ExitCode } else { 1 })
}

$xpiPath = Join-Path $env:ProgramData 'SixVPNBlocker\firefox\sixvpn-blocker@sixvpnblocker.app.xpi'
$xpiUrl = 'file:///' + ($xpiPath -replace '\\', '/')
$sourcesRoot = Join-Path $env:ProgramData 'SixVPNBlocker'
$installSources = 'file:///' + ($sourcesRoot -replace '\\', '/')

$policyObj = @{
  policies = @{
    DNSOverHTTPS = @{
      Enabled = $false
      Locked  = $true
    }
    NetworkPrediction = $false
    Preferences = @{
      'network.trr.mode' = 5
      'network.dns.disablePrefetch' = $true
      'network.dns.disablePrefetchFromHTTPS' = $true
      'doh-rollout.mode' = 5
    }
    DisablePrivateBrowsing = $true
    PrivateBrowsingModeAvailability = 1
    DisableDeveloperTools = $true
    Extensions = @{
      Install = @($xpiUrl)
      Locked = @('sixvpn-blocker@sixvpnblocker.app')
      InstallSources = @($installSources, 'file:///*')
    }
    ExtensionSettings = @{
      'sixvpn-blocker@sixvpnblocker.app' = @{
        installation_mode = 'force_installed'
        install_url       = $xpiUrl
        blocked_install_message = '6 VPN Blocker protection is locked by policy.'
      }
    }
  }
}

$json = $policyObj | ConvertTo-Json -Depth 8 -Compress:$false

$targets = @(
  (Join-Path $env:ProgramFiles 'Mozilla Firefox\distribution\policies.json'),
  (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\distribution\policies.json')
)

$written = 0
$needElevate = $false

foreach ($target in $targets) {
  $dist = Split-Path -Parent $target
  $firefoxRoot = Split-Path -Parent $dist
  if (-not (Test-Path -LiteralPath $firefoxRoot)) { continue }

  if ($RemoveBroken) {
    if (Test-Path -LiteralPath $target) {
      try {
        Remove-Item -LiteralPath $target -Force
        Write-Host "Removed broken: $target" -ForegroundColor Yellow
        $written++
      } catch {
        $needElevate = $true
        Write-Host "Remove failed (need admin): $target" -ForegroundColor Red
      }
    }
    continue
  }

  try {
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Set-Content -LiteralPath $target -Value $json -Encoding UTF8
    Write-Host "Fixed: $target" -ForegroundColor Green
    $written++
  } catch {
    $needElevate = $true
    Write-Host "Write failed (need admin): $target - $($_.Exception.Message)" -ForegroundColor Red
  }
}

if ($needElevate -and -not (Test-IsAdmin) -and -not $NoElevate) {
  Write-Host 'Requesting administrator (UAC) to repair Firefox policies...' -ForegroundColor Cyan
  $self = $PSCommandPath
  $argList = '-NoProfile -ExecutionPolicy Bypass -Elevate -File "' + $self + '"'
  if ($LaunchFirefox) { $argList += ' -LaunchFirefox' }
  $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru
  exit $(if ($null -ne $p.ExitCode) { [int]$p.ExitCode } else { 1 })
}

if ($written -eq 0) {
  Write-Host 'Firefox not found or no policy files touched.' -ForegroundColor Yellow
  exit 0
}

Write-Host 'Firefox policies repaired. Restart Firefox.' -ForegroundColor Cyan

if ($LaunchFirefox) {
  $ff = Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'
  if (Test-Path -LiteralPath $ff) {
    Start-Process -FilePath $ff
  }
}
