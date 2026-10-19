$ErrorActionPreference = 'Stop'

$newId = 'sixvpn-blocker@sixvpnblocker.app'
$oldId = 'sixvpn-blocker@local'
$repoRoot = Split-Path -Parent $PSScriptRoot
$signedCandidates = @(
  (Join-Path $repoRoot 'assets\browser_extensions\firefox\sixvpn_blocker_signed.xpi'),
  (Join-Path $env:LOCALAPPDATA 'Programs\SixVPNBlocker\data\flutter_assets\assets\browser_extensions\firefox\sixvpn_blocker_signed.xpi')
)

$src = $signedCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $src) {
  throw 'signed Firefox XPI not found in repo or installed Flutter assets.'
}

$pdDir = Join-Path $env:ProgramData 'SixVPNBlocker\firefox'
New-Item -ItemType Directory -Force -Path $pdDir | Out-Null
$newPd = Join-Path $pdDir "$newId.xpi"
$oldPd = Join-Path $pdDir "$oldId.xpi"
Copy-Item -LiteralPath $src -Destination $newPd -Force
# Keep a signed compatibility copy at the legacy policy URL. Some machines
# have ACL-locked Firefox policy keys that still point at @local.
Copy-Item -LiteralPath $src -Destination $oldPd -Force

$profilesRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
$profileHits = 0
$oldRemoved = 0
if (Test-Path -LiteralPath $profilesRoot) {
  Get-ChildItem -LiteralPath $profilesRoot -Directory | ForEach-Object {
    $extDir = Join-Path $_.FullName 'extensions'
    New-Item -ItemType Directory -Force -Path $extDir | Out-Null
    Copy-Item -LiteralPath $newPd -Destination (Join-Path $extDir "$newId.xpi") -Force
    $profileHits++
    $oldProfile = Join-Path $extDir "$oldId.xpi"
    if (Test-Path -LiteralPath $oldProfile) {
      Remove-Item -LiteralPath $oldProfile -Force
      $oldRemoved++
    }
  }
}

$xpiUrl = 'file:///' + ($newPd -replace '\\', '/')
$settings = @{
  $newId = @{
    installation_mode = 'force_installed'
    install_url = $xpiUrl
    blocked_install_message = '6 VPN Blocker protection is locked by policy.'
  }
} | ConvertTo-Json -Depth 5 -Compress

$policyResults = New-Object System.Collections.Generic.List[string]
foreach ($root in @('HKCU:\SOFTWARE\Policies\Mozilla\Firefox', 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox')) {
  try {
    if (-not (Test-Path -LiteralPath $root)) {
      New-Item -Path $root -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $root -Name 'ExtensionSettings' -Value $settings -Type String -Force
    Set-ItemProperty -LiteralPath $root -Name 'DisablePrivateBrowsing' -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath $root -Name 'PrivateBrowsingModeAvailability' -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath $root -Name 'DisableDeveloperTools' -Value 1 -Type DWord -Force

    $doh = Join-Path $root 'DNSOverHTTPS'
    if (-not (Test-Path -LiteralPath $doh)) { New-Item -Path $doh -Force | Out-Null }
    Set-ItemProperty -LiteralPath $doh -Name 'Enabled' -Value 0 -Type DWord -Force
    Set-ItemProperty -LiteralPath $doh -Name 'Locked' -Value 1 -Type DWord -Force

    $install = Join-Path $root 'Extensions\Install'
    $locked = Join-Path $root 'Extensions\Locked'
    if (-not (Test-Path -LiteralPath $install)) { New-Item -Path $install -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $locked)) { New-Item -Path $locked -Force | Out-Null }
    Set-ItemProperty -LiteralPath $install -Name '1' -Value $xpiUrl -Type String -Force
    Set-ItemProperty -LiteralPath $locked -Name '1' -Value $newId -Type String -Force
    $policyResults.Add("POLICY_OK $root")
  } catch {
    $policyResults.Add("POLICY_FAIL $root $($_.Exception.Message)")
  }
}

$policyBody = @{
  policies = @{
    DNSOverHTTPS = @{ Enabled = $false; Locked = $true }
    NetworkPrediction = $false
    DisablePrivateBrowsing = $true
    PrivateBrowsingModeAvailability = 1
    DisableDeveloperTools = $true
    Extensions = @{
      Install = @($xpiUrl)
      Locked = @($newId)
      InstallSources = @('file:///*')
    }
    ExtensionSettings = @{
      $newId = @{
        installation_mode = 'force_installed'
        install_url = $xpiUrl
        blocked_install_message = '6 VPN Blocker protection is locked by policy.'
      }
    }
  }
} | ConvertTo-Json -Depth 8

foreach ($ffRoot in @(
  (Join-Path ${env:ProgramFiles} 'Mozilla Firefox'),
  (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox')
)) {
  try {
    if (-not (Test-Path -LiteralPath $ffRoot)) { continue }
    $dist = Join-Path $ffRoot 'distribution'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Set-Content -LiteralPath (Join-Path $dist 'policies.json') -Value $policyBody -Encoding UTF8
    $policyResults.Add("DISTRIBUTION_OK $dist")
  } catch {
    $policyResults.Add("DISTRIBUTION_FAIL $ffRoot $($_.Exception.Message)")
  }
}

Write-Output "PROGRAMDATA_XPI=$newPd"
Write-Output "PROGRAMDATA_XPI_BYTES=$((Get-Item -LiteralPath $newPd).Length)"
Write-Output "PROFILE_XPI_COPIED=$profileHits"
Write-Output "OLD_PROFILE_XPI_REMOVED=$oldRemoved"
$policyResults | ForEach-Object { Write-Output $_ }
