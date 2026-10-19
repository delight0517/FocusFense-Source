# Focus Fense Windows uninstaller.
# Run from Windows Settings > Apps or the Start Menu removal shortcut.
# App-owned data is archived before removal; protection state is cleaned first.
[CmdletBinding()]
param(
  [switch] $Elevated,
  [int] $ParentPid = 0,
  [switch] $FromTemp
)

$ErrorActionPreference = 'Stop'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\FocusFense'
$appDataRoot = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$programDataRoot = Join-Path $env:ProgramData 'SixVPNBlocker'
$backupRoot = Join-Path $env:USERPROFILE 'Documents\FocusFence Canonical Backups\uninstall-archives'
$taskNames = @(
  'SixVPNBlockerWatchdog', 'SixVPNBlockerWatchdog2', 'SixVPNBlockerAutostart',
  'SixVPNBlockerBootGuard', 'SixVPNBlockerOfflineGuard',
  'SixVPNBlockerElevatedMaintain', 'SixVPNBrowserGuard', 'SixVPNTier3Watchdog'
)

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FileManifest([string] $Root) {
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  $base = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
  return @(Get-ChildItem -LiteralPath $base -File -Recurse -Force | ForEach-Object {
    [pscustomobject]@{
      Path = $_.FullName.Substring($base.Length).TrimStart('\')
      Length = $_.Length
      SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
  } | Sort-Object Path)
}

if (-not $FromTemp) {
  if (-not (Test-Path -LiteralPath $PSCommandPath)) { throw 'Uninstaller source is missing.' }
  $tempCopy = Join-Path $env:TEMP ("FocusFense-Uninstall-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
  Copy-Item -LiteralPath $PSCommandPath -Destination $tempCopy
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $tempCopy, '-FromTemp', '-ParentPid', $PID)
  if (Test-Administrator) { $args += '-Elevated' }
  if (-not (Test-Administrator)) {
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs | Out-Null }
    catch { Remove-Item -LiteralPath $tempCopy -Force -ErrorAction SilentlyContinue; throw 'Administrator approval was cancelled; nothing was removed.' }
  } else {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden | Out-Null
  }
  return
}

if (-not (Test-Administrator)) {
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath, '-FromTemp','-Elevated','-ParentPid', $ParentPid)
  try { Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs | Out-Null }
  catch { throw 'Administrator approval was cancelled; nothing was removed.' }
  return
}

$answer = Read-Host 'This removes Focus Fense protection, recovery tasks, shortcuts and app files. Type REMOVE to continue'
if ($answer -cne 'REMOVE') { Write-Output 'Cancelled. Nothing was removed.'; exit 0 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$archive = Join-Path $backupRoot $stamp
New-Item -ItemType Directory -Path $archive -Force | Out-Null
$log = Join-Path $archive 'uninstall.log'
Start-Transcript -LiteralPath $log -Force | Out-Null
try {
  # Preserve a verifiable copy of app data and the current hosts file first.
  $dataArchive = Join-Path $archive 'SixVPNBlocker'
  if (Test-Path -LiteralPath $appDataRoot) {
    Copy-Item -LiteralPath $appDataRoot -Destination $dataArchive -Recurse -Force
    $sourceManifest = @(Get-FileManifest $appDataRoot)
    $copyManifest = @(Get-FileManifest $dataArchive)
    $sourceJson = ConvertTo-Json -InputObject $sourceManifest -Depth 4 -Compress
    $copyJson = ConvertTo-Json -InputObject $copyManifest -Depth 4 -Compress
    if ($sourceJson -cne $copyJson) { throw 'App data backup verification failed; no removal was performed.' }
    $sourceManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $archive 'appdata-manifest.json') -Encoding UTF8
  }
  if (Test-Path -LiteralPath $programDataRoot) {
    $pdArchive = Join-Path $archive 'ProgramData-SixVPNBlocker'
    Copy-Item -LiteralPath $programDataRoot -Destination $pdArchive -Recurse -Force
    $pdManifest = @(Get-FileManifest $programDataRoot)
    $pdCopyManifest = @(Get-FileManifest $pdArchive)
    if ((ConvertTo-Json -InputObject $pdManifest -Depth 4 -Compress) -cne
        (ConvertTo-Json -InputObject $pdCopyManifest -Depth 4 -Compress)) {
      throw 'ProgramData backup verification failed; no removal was performed.'
    }
    $pdManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $archive 'programdata-manifest.json') -Encoding UTF8
  }
  $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (Test-Path -LiteralPath $hostsPath) { Copy-Item -LiteralPath $hostsPath -Destination (Join-Path $archive 'hosts.before') -Force }
  $desktopRoot = [Environment]::GetFolderPath('Desktop')
  $desktopArchive = Join-Path $archive 'Desktop'
  $desktopArtifacts = @(Get-ChildItem -LiteralPath $desktopRoot -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^(Focus Fense|FocusFence|6 VPN Blocker).*(\.lnk|\.bat)$'
  })
  foreach ($file in $desktopArtifacts) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $desktopArchive $file.Name) -Force }
  foreach ($file in $desktopArtifacts) {
    $copy = Join-Path $desktopArchive $file.Name
    if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
      throw 'Desktop shortcut/script backup verification failed; no removal was performed.'
    }
  }

  # Remove only Focus Fense's managed hosts block and leave other host entries intact.
  if (Test-Path -LiteralPath $hostsPath) {
    $hostsText = [IO.File]::ReadAllText($hostsPath)
    $start = '# === 6 VPN Blocker BEGIN (managed) ==='
    $end = '# === 6 VPN Blocker END (managed) ==='
    $i = $hostsText.IndexOf($start, [StringComparison]::Ordinal)
    $j = $hostsText.IndexOf($end, [StringComparison]::Ordinal)
    if ($i -ge 0 -and $j -gt $i) {
      $j += $end.Length
      $hostsText = $hostsText.Remove($i, $j - $i).TrimEnd() + [Environment]::NewLine
      [IO.File]::WriteAllText($hostsPath, $hostsText, [Text.UTF8Encoding]::new($false))
      & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
    }
  }

  # Stop the app's DNS sink, restore adapters from its own backup and remove its NRPT rules.
  foreach ($pidName in @('dns_sink.pid','dns_sink_tcp.pid')) {
    $pidPath = Join-Path $programDataRoot $pidName
    if (Test-Path -LiteralPath $pidPath) {
      $pidText = (Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue).Trim()
      if ($pidText -match '^\d+$') { Stop-Process -Id ([int]$pidText) -Force -ErrorAction SilentlyContinue }
    }
  }
  $dnsBackup = Join-Path $programDataRoot 'dns_adapter_backup.txt'
  if (Test-Path -LiteralPath $dnsBackup) {
    Get-Content -LiteralPath $dnsBackup -Encoding UTF8 | ForEach-Object {
      $parts = $_ -split '\|', 2
      if ($parts.Count -lt 2) { return }
      if ([string]::IsNullOrWhiteSpace($parts[1])) {
        Set-DnsClientServerAddress -InterfaceAlias $parts[0] -ResetServerAddresses -ErrorAction SilentlyContinue
      } else {
        $addresses = @($parts[1] -split ',' | Where-Object { $_ -match '\S' })
        if ($addresses.Count) { Set-DnsClientServerAddress -InterfaceAlias $parts[0] -ServerAddresses $addresses -ErrorAction SilentlyContinue }
      }
    }
  }
  Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq 'SixVPNBlocker' } |
    ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }
  try { Set-Service -Name Dnscache -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name Dnscache -ErrorAction SilentlyContinue } catch {}
  & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null

  # Remove app-owned firewall rules only.
  Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like 'SixVPN_Block_*' -or $_.DisplayName -like 'SixVPN_Block_*'
  } | Remove-NetFirewallRule -ErrorAction SilentlyContinue

  # Export and remove URL blocklists created by the app in browser policy keys.
  $policyRoots = @(
    'HKCU:\Software\Policies\Google\Chrome', 'HKLM:\Software\Policies\Google\Chrome',
    'HKCU:\Software\Policies\Microsoft\Edge', 'HKLM:\Software\Policies\Microsoft\Edge',
    'HKCU:\Software\Policies\BraveSoftware\Brave', 'HKLM:\Software\Policies\BraveSoftware\Brave',
    'HKCU:\Software\Policies\Opera Software', 'HKLM:\Software\Policies\Opera Software'
  )
  $policyArchive = Join-Path $archive 'browser-policy-registry'
  New-Item -ItemType Directory -Path $policyArchive -Force | Out-Null
  foreach ($root in $policyRoots) {
    $listKey = Join-Path $root 'URLBlocklist'
    if (Test-Path -LiteralPath $listKey) {
      $regPath = $listKey -replace '^HKCU:', 'HKEY_CURRENT_USER' -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' -replace ':', ''
      $safeName = ($regPath -replace '[\\:]', '_') + '.reg'
      & reg.exe export $regPath (Join-Path $policyArchive $safeName) /y | Out-Null
      Remove-Item -LiteralPath $listKey -Recurse -Force
    }
  }

  # Task definitions are exported before removal so they can be restored if needed.
  $taskArchive = Join-Path $archive 'scheduled-tasks'
  New-Item -ItemType Directory -Path $taskArchive -Force | Out-Null
  foreach ($name in $taskNames) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) {
      Export-ScheduledTask -TaskName $name | Set-Content -LiteralPath (Join-Path $taskArchive "$name.xml") -Encoding UTF8
      if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue }
      Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    }
  }
  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  Remove-ItemProperty -LiteralPath $runKey -Name SixVPNBlocker -ErrorAction SilentlyContinue
  Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name SixVPNBlocker -ErrorAction SilentlyContinue

  # Remove Start Menu links and the uninstaller registration.
  $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  $startMenuArtifacts = @(Get-ChildItem -LiteralPath $startMenu -Recurse -File -Filter *.lnk -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match 'Focus Fense|FocusFence|6 VPN Blocker' })
  $startMenuArchive = Join-Path $archive 'StartMenu'
  foreach ($file in $startMenuArtifacts) {
    $relative = $file.FullName.Substring($startMenu.Length).TrimStart('\')
    $copy = Join-Path $startMenuArchive $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $copy -Force
    if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
      throw 'Start Menu backup verification failed; no removal was performed.'
    }
  }
  foreach ($file in $startMenuArtifacts) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
  foreach ($file in $desktopArtifacts) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
  @('Focus Fense','FocusFence','6 VPN Blocker') | ForEach-Object {
    $folder = Join-Path $startMenu $_
    if (Test-Path -LiteralPath $folder) {
      Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue
    }
  }
  Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FocusFense' -Recurse -Force -ErrorAction SilentlyContinue

  # Stop the installed app. The temp cleanup helper waits for its process to exit.
  Get-Process -Name FocusFense,six_clean_room,6VPNBlocker -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Path -and $_.Path.StartsWith((Join-Path $env:LOCALAPPDATA 'Programs\'), [StringComparison]::OrdinalIgnoreCase)) {
      Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
  }

  # Schedule a separate temp helper so the running script never deletes its own directory.
  $cleanup = Join-Path $env:TEMP ("FocusFense-Finalize-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
  @'
param([int]$WaitPid,[string]$TargetsJson,[string]$TempScript,[string]$AppDataRoot,[string]$ProgramDataRoot)
Start-Sleep -Seconds 2
if ($WaitPid -gt 0) { try { Wait-Process -Id $WaitPid -Timeout 30 -ErrorAction SilentlyContinue } catch {} }
$Targets = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($TargetsJson)) | ConvertFrom-Json
foreach ($target in $Targets) {
  if (-not (Test-Path -LiteralPath $target)) { continue }
  $full = [IO.Path]::GetFullPath($target).TrimEnd('\')
  $allowed = @([IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs')).TrimEnd('\'))
  $safeProgramTarget = [bool]($allowed | Where-Object { $full.StartsWith($_ + '\',[StringComparison]::OrdinalIgnoreCase) })
  $safeDataTarget = $full -ieq [IO.Path]::GetFullPath($AppDataRoot).TrimEnd('\')
  $safeProgramDataTarget = $full -ieq [IO.Path]::GetFullPath($ProgramDataRoot).TrimEnd('\')
  if ($safeProgramTarget -or $safeDataTarget -or $safeProgramDataTarget) {
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Remove-Item -LiteralPath $TempScript -Force -ErrorAction SilentlyContinue
'@ | Set-Content -LiteralPath $cleanup -Encoding UTF8
  $programsRoot = Join-Path $env:LOCALAPPDATA 'Programs'
  $targets = @(
    (Join-Path $programsRoot 'FocusFense'),
    (Join-Path $programsRoot 'SixVPNBlocker'),
    (Join-Path $programsRoot 'FocusFence-1.0.0+464'),
    $appDataRoot,
    $programDataRoot
  )
  $encodedTargets = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($targets | ConvertTo-Json -Compress)))
  $waitPid = $PID
  $finalizerArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -WaitPid {1} -TargetsJson {2} -TempScript "{3}" -AppDataRoot "{4}" -ProgramDataRoot "{5}"' -f $cleanup, $waitPid, $encodedTargets, $PSCommandPath, $appDataRoot, $programDataRoot
  Start-Process -FilePath 'powershell.exe' -ArgumentList $finalizerArgs -WindowStyle Hidden | Out-Null
  Write-Output "Uninstall cleanup started. Verified preservation archive: $archive"
} finally {
  Stop-Transcript | Out-Null
}
