param(
  [switch] $Elevate,
  [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Elevate -and -not (Test-IsAdmin)) {
  $self = $PSCommandPath
  $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $self + '"'
  if ($NoRestart) { $args += ' -NoRestart' }
  $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args -Wait -PassThru
  exit $(if ($null -ne $p.ExitCode) { [int]$p.ExitCode } else { 1 })
}

$extId = 'sixvpn-blocker@sixvpnblocker.app'
$xpiPath = Join-Path $env:ProgramData 'SixVPNBlocker\firefox\sixvpn-blocker@sixvpnblocker.app.xpi'
if (-not (Test-Path -LiteralPath $xpiPath)) {
  throw "Firefox XPI not found: $xpiPath"
}

$xpiUrl = 'file:///' + ($xpiPath -replace '\\', '/')
$sourcesRoot = Join-Path $env:ProgramData 'SixVPNBlocker'
$installSources = 'file:///' + ($sourcesRoot -replace '\\', '/')

$policyObj = @{
  policies = @{
    DNSOverHTTPS = @{
      Enabled = $false
      Locked = $true
    }
    NetworkPrediction = $false
    Preferences = @{
      'network.trr.mode' = 5
      'network.trr.uri' = ''
      'network.trr.custom_uri' = ''
      'network.dns.disablePrefetch' = $true
      'network.dns.disablePrefetchFromHTTPS' = $true
      'doh-rollout.mode' = 5
      'doh-rollout.self-enabled' = $false
    }
    DisablePrivateBrowsing = $true
    PrivateBrowsingModeAvailability = 1
    DisableDeveloperTools = $true
    Extensions = @{
      Install = @($xpiUrl)
      Locked = @($extId)
      InstallSources = @($installSources, 'file:///*')
    }
    ExtensionSettings = @{
      $extId = @{
        installation_mode = 'force_installed'
        install_url = $xpiUrl
        blocked_install_message = '6 VPN Blocker protection is locked by policy.'
      }
    }
  }
}

$json = $policyObj | ConvertTo-Json -Depth 10 -Compress:$false
$policyTargets = @(
  (Join-Path $env:ProgramFiles 'Mozilla Firefox\distribution\policies.json'),
  (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\distribution\policies.json')
)

$written = 0
foreach ($target in $policyTargets) {
  try {
    $dist = Split-Path -Parent $target
    $firefoxRoot = Split-Path -Parent $dist
    if (-not (Test-Path -LiteralPath $firefoxRoot)) { continue }
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Set-Content -LiteralPath $target -Value $json -Encoding UTF8 -Force
    Write-Host "Firefox policies.json OK: $target"
    $written++
  } catch {
    Write-Host "Firefox policies.json SKIP: $target :: $($_.Exception.Message)"
  }
}

$roots = @(
  'HKCU:\SOFTWARE\Policies\Mozilla\Firefox',
  'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
)

$settings = @{
  $extId = @{
    installation_mode = 'force_installed'
    install_url = $xpiUrl
    blocked_install_message = '6 VPN Blocker protection is locked by policy.'
  }
} | ConvertTo-Json -Depth 6 -Compress

foreach ($root in $roots) {
  try {
    New-Item -Path $root -Force | Out-Null
    Set-ItemProperty -LiteralPath $root -Name 'ExtensionSettings' -Value $settings -Type String -Force
    Set-ItemProperty -LiteralPath $root -Name 'DisablePrivateBrowsing' -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath $root -Name 'PrivateBrowsingModeAvailability' -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath $root -Name 'DisableDeveloperTools' -Value 1 -Type DWord -Force

    $doh = Join-Path $root 'DNSOverHTTPS'
    New-Item -Path $doh -Force | Out-Null
    Set-ItemProperty -LiteralPath $doh -Name 'Enabled' -Value 0 -Type DWord -Force
    Set-ItemProperty -LiteralPath $doh -Name 'Locked' -Value 1 -Type DWord -Force

    $install = Join-Path $root 'Extensions\Install'
    $locked = Join-Path $root 'Extensions\Locked'
    New-Item -Path $install -Force | Out-Null
    New-Item -Path $locked -Force | Out-Null
    Set-ItemProperty -LiteralPath $install -Name '1' -Value $xpiUrl -Type String -Force
    Set-ItemProperty -LiteralPath $locked -Name '1' -Value $extId -Type String -Force
    Write-Host "Firefox registry policy OK: $root"
  } catch {
    Write-Host "Firefox registry policy SKIP: $root :: $($_.Exception.Message)"
  }
}

$profilesRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
$profilesCopied = 0
if (Test-Path -LiteralPath $profilesRoot) {
  Get-ChildItem -LiteralPath $profilesRoot -Directory | ForEach-Object {
    $extDir = Join-Path $_.FullName 'extensions'
    New-Item -ItemType Directory -Force -Path $extDir | Out-Null
    Copy-Item -LiteralPath $xpiPath -Destination (Join-Path $extDir "$extId.xpi") -Force
    $profilesCopied++
  }
}
Write-Host "Firefox profile XPI copied: $profilesCopied"

# @incident: firefox_work_window_closed — policy maintenance must preserve tabs
# and authenticated developer sessions. Keep -NoRestart for older callers.
Write-Host 'Firefox left running. Policies requiring restart apply on the next user-controlled launch.'

if ($written -eq 0) {
  Write-Host 'Firefox install folder was not found. Registry/profile policy still applied.'
}

Write-Host 'Firefox blueprint policy apply complete.'
