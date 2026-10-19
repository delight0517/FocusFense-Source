# Start Menu search aliases + login autostart for 6 VPN Blocker (Windows).
param(
  [string] $ExePath = "",
  [switch] $SkipAutostart
)

$ErrorActionPreference = "Stop"

function Get-SixVpnIconPath {
  param([string] $WorkDir)
  $ico = Join-Path $WorkDir 'app_icon.ico'
  if (Test-Path -LiteralPath $ico) { return $ico }
  return $null
}

function Set-SixVpnAutostartRun {
  param([string] $ExePath)
  if (-not (Test-Path -LiteralPath $ExePath)) { return $false }
  # Bare quoted EXE — reg.exe strips embedded quotes from cmd/start wrappers.
  $runValue = "`"$ExePath`""
  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  if (-not (Test-Path -LiteralPath $runKey)) {
    New-Item -Path $runKey -Force | Out-Null
  }
  Set-ItemProperty -LiteralPath $runKey -Name SixVPNBlocker -Value $runValue -Type String
  $approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
  if (-not (Test-Path -LiteralPath $approvedKey)) {
    New-Item -Path $approvedKey -Force | Out-Null
  }
  $enabled = [byte[]](0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  Set-ItemProperty -LiteralPath $approvedKey -Name SixVPNBlocker -Value $enabled -Type Binary
  Write-Host "Autostart: Run registry -> $runValue" -ForegroundColor Green
  return $true
}

function Install-SixVpnWatchdogTasks {
  param([string] $ExePath)
  if (-not (Test-Path -LiteralPath $ExePath)) { return $false }

  $toolsDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
  if (-not (Test-Path -LiteralPath $toolsDir)) {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
  }

  $targetFile = Join-Path $toolsDir 'watchdog_target.txt'
  $watchdogPs = Join-Path $toolsDir 'watchdog.ps1'
  $watchdogVbs = Join-Path $toolsDir 'watchdog_launch.vbs'
  Set-Content -LiteralPath $targetFile -Value $ExePath -Encoding UTF8

  @'
$ErrorActionPreference = "SilentlyContinue"
if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime) {
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  if (((Get-Date) - $boot).TotalSeconds -lt 45) { exit 0 }
}
$repair = Join-Path $env:LOCALAPPDATA "SixVPNBlocker\tools\Repair-Install-Integrity.ps1"
if (Test-Path -LiteralPath $repair) {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File $repair -Quiet
}
$pathFile = Join-Path $env:LOCALAPPDATA "SixVPNBlocker\watchdog_target.txt"
if (-not (Test-Path -LiteralPath $pathFile)) { exit 0 }
$exe = (Get-Content -LiteralPath $pathFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($exe)) { exit 0 }
if (-not (Test-Path -LiteralPath $exe)) {
  $shardRoots = @(
    (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\backup\FocusFense.exe'),
    (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\cache\v1\runner_payload.exe'),
    (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\policy_batch\install_shard_b.exe'),
    (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\staged\search_mirror.exe')
  )
  foreach ($backup in $shardRoots) {
    if (Test-Path -LiteralPath $backup) {
      $wd = Split-Path -LiteralPath $exe
      New-Item -ItemType Directory -Force -Path $wd | Out-Null
      Copy-Item -LiteralPath $backup -Destination $exe -Force
      break
    }
  }
}
if (-not (Test-Path -LiteralPath $exe)) { exit 0 }
$want = (Resolve-Path -LiteralPath $exe).Path
$installDir = [System.IO.Path]::GetDirectoryName($want)
$names = @('FocusFense')
$found = $false
foreach ($n in $names) {
  Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
    if (-not $_.Path) { return }
    $p = (Resolve-Path -LiteralPath $_.Path).Path
    if ([System.IO.Path]::GetDirectoryName($p) -ieq $installDir) { $script:found = $true }
  }
}
if ($found) { exit 0 }
$wd = Split-Path -LiteralPath $exe
$p = Start-Process -FilePath $exe -WorkingDirectory $wd -PassThru
Start-Sleep -Seconds 2
$stateFile = Join-Path $env:LOCALAPPDATA "SixVPNBlocker\watchdog_last.json"
try {
  $obj = [ordered]@{
    at = (Get-Date).ToString("o")
    status = "relaunched"
    detail = "pid=$($p.Id) exe=$exe"
    user = "$env:USERDOMAIN\$env:USERNAME"
  }
  $obj | ConvertTo-Json -Compress | Set-Content -LiteralPath $stateFile -Encoding UTF8 -Force
} catch {}
'@ | Set-Content -LiteralPath $watchdogPs -Encoding UTF8

  $psForVbs = $watchdogPs -replace '"', '""'
  $vbs = 'CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -NoLogo -NonInteractive -WindowStyle Hidden -File ""' + $psForVbs + '""", 0, False'
  Set-Content -LiteralPath $watchdogVbs -Value $vbs -Encoding ASCII

  $windir = $env:WINDIR
  if (-not $windir) { $windir = 'C:\Windows' }
  $wscriptExe = Join-Path $windir 'System32\wscript.exe'
  $user = "$env:USERDOMAIN\$env:USERNAME"
  foreach ($pair in @(
      @{ Name = 'SixVPNBlockerWatchdog'; Second = 0 },
      @{ Name = 'SixVPNBlockerWatchdog2'; Second = 30 }
    )) {
    $name = $pair.Name
    $arg = "//B //Nologo `"$watchdogVbs`""
    $a = New-ScheduledTaskAction -Execute $wscriptExe -Argument $arg
    $start = Get-Date -Hour 0 -Minute 0 -Second $pair.Second -Millisecond 0
    $t = New-ScheduledTaskTrigger -Once -At $start
    $t.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition
    $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null
    Write-Host "Watchdog: scheduled task $name (30s coverage)" -ForegroundColor Green
  }
  return $true
}

function New-HiddenScheduledTaskAction {
  # Task Scheduler launching powershell.exe directly -- even with
  # -WindowStyle Hidden -- briefly flashes a black console frame before the
  # window style takes effect. wscript.exe has no console subsystem at all,
  # so WScript.Shell.Run(cmd, 0, False) never allocates a console.
  param(
    [string] $ToolsDir,
    [string] $VbsName,
    [string] $PowershellArgs
  )
  $windir = $env:WINDIR
  if (-not $windir) { $windir = 'C:\Windows' }
  $psExe = Join-Path $windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $vbsPath = Join-Path $ToolsDir $VbsName
  $cmdLine = "`"$psExe`" $PowershellArgs"
  $vbQuoted = '"' + ($cmdLine -replace '"', '""') + '"'
  @(
    'Set objShell = CreateObject("WScript.Shell")',
    "objShell.Run $vbQuoted, 0, False"
  ) -join "`r`n" | Set-Content -LiteralPath $vbsPath -Encoding ASCII
  $wscriptExe = Join-Path $windir 'System32\wscript.exe'
  $wscriptArg = "//B //Nologo `"$vbsPath`""
  return New-ScheduledTaskAction -Execute $wscriptExe -Argument $wscriptArg
}

function New-AppShortcut {
  param(
    [string] $LinkPath,
    [string] $TargetExe,
    [string] $WorkDir,
    [string] $Description = "6 VPN Blocker"
  )
  $parent = Split-Path -Parent $LinkPath
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $shell = New-Object -ComObject WScript.Shell
  $sc = $shell.CreateShortcut($LinkPath)
  $sc.TargetPath = $TargetExe
  $sc.WorkingDirectory = $WorkDir
  $icon = Get-SixVpnIconPath -WorkDir $WorkDir
  if ($icon) { $sc.IconLocation = $icon } else { $sc.IconLocation = "$TargetExe,0" }
  $sc.Description = $Description
  $sc.WindowStyle = 1
  $sc.Save()
}

$installDir = Join-Path $env:LOCALAPPDATA "Programs\FocusFense"
$primaryExe = Join-Path $installDir "FocusFense.exe"
$searchExe = Join-Path $installDir "FocusFense.exe"

if (-not $ExePath) {
  if (Test-Path -LiteralPath $searchExe) { $ExePath = $searchExe }
  elseif (Test-Path -LiteralPath $primaryExe) { $ExePath = $primaryExe }
}

if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) {
  Write-Host "OS integration skipped - exe not found." -ForegroundColor Yellow
  exit 0
}

if ((Split-Path -Leaf $ExePath) -ne "FocusFense.exe") { $ExePath = $primaryExe }

$dir = Split-Path -Parent $ExePath
$iconScript = Join-Path $PSScriptRoot 'Copy-SixVpnInstallIcon.ps1'
if (Test-Path -LiteralPath $iconScript) {
  & $iconScript -InstallDir $dir | Out-Null
}
$programs = [Environment]::GetFolderPath("StartMenu")
$programsDir = Join-Path $programs "Programs"
$subFolder = Join-Path $programsDir "Focus Fense"

$shortcuts = @(
  (Join-Path $programsDir "Focus Fense.lnk"),
  (Join-Path $subFolder "Focus Fense.lnk")
)

foreach ($lnk in $shortcuts) {
  New-AppShortcut -LinkPath $lnk -TargetExe $ExePath -WorkDir $dir
  Write-Host "Start Menu: $lnk" -ForegroundColor Green
}

if (-not $SkipAutostart) {
  $startupLnk = Join-Path (Join-Path $programsDir "Startup") "Focus Fense.lnk"
  if (Test-Path -LiteralPath $startupLnk) {
    Remove-Item -LiteralPath $startupLnk -Force
    Write-Host "Removed duplicate Startup shortcut: $startupLnk" -ForegroundColor Yellow
  }
  $runExe = $primaryExe
  if (-not (Test-Path -LiteralPath $runExe)) { $runExe = $ExePath }
  Set-SixVpnAutostartRun -ExePath $runExe | Out-Null

  $logonDelay = 25
  $bootGuardDelay = 55
  $user = "$env:USERDOMAIN\$env:USERNAME"
  $toolsDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\tools'
  if (-not (Test-Path -LiteralPath $toolsDir)) {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
  }
  $guardPs = Join-Path $toolsDir 'boot_guard_launch.ps1'
  @'
param([Parameter(Mandatory = $true)] [string] $ExePath)
$ErrorActionPreference = 'SilentlyContinue'
if (Get-Process -Name FocusFense -ErrorAction SilentlyContinue) { exit 0 }
if (-not (Test-Path -LiteralPath $ExePath)) { exit 1 }
$dir = Split-Path -Parent $ExePath
Start-Process -FilePath $ExePath -WorkingDirectory $dir
exit 0
'@ | Set-Content -LiteralPath $guardPs -Encoding UTF8

  foreach ($pair in @(
      @{ Name = 'SixVPNBlockerAutostart'; Delay = $logonDelay; Action = $runExe },
      @{ Name = 'SixVPNBlockerBootGuard'; Delay = $bootGuardDelay; Action = 'guard' }
    )) {
    $name = $pair.Name
    $delay = $pair.Delay
    if ($pair.Action -eq 'guard') {
      $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guardPs`" -ExePath `"$runExe`""
      $a = New-HiddenScheduledTaskAction -ToolsDir $toolsDir -VbsName 'boot_guard_launch.vbs' -PowershellArgs $arg
    } else {
      $a = New-ScheduledTaskAction -Execute $runExe
    }
    $t = New-ScheduledTaskTrigger -AtLogOn -User $user
    $t.Delay = "PT${delay}S"
    $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries
    $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null
    Write-Host "Autostart: scheduled task $name (${delay}s delay)" -ForegroundColor Green
  }
  Install-SixVpnWatchdogTasks -ExePath $runExe | Out-Null
}

# Offline HKCU policy guard (no UAC) — 10 min + logon 2 min
$offlineUser = "$env:USERDOMAIN\$env:USERNAME"
$offlinePs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Offline-Block-Policy-Maintain.ps1'
if (Test-Path -LiteralPath $offlinePs) {
  $offlineToolsDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\tools'
  if (-not (Test-Path -LiteralPath $offlineToolsDir)) {
    New-Item -ItemType Directory -Path $offlineToolsDir -Force | Out-Null
  }
  $offlineArg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$offlinePs`" -Quiet"
  $oa = New-HiddenScheduledTaskAction -ToolsDir $offlineToolsDir -VbsName 'offline_guard_launch.vbs' -PowershellArgs $offlineArg
  $ot1 = New-ScheduledTaskTrigger -Once -At (Get-Date)
  $ot1.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition
  $ot2 = New-ScheduledTaskTrigger -AtLogOn -User $offlineUser
  $ot2.Delay = 'PT120S'
  $os = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
  $op = New-ScheduledTaskPrincipal -UserId $offlineUser -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'SixVPNBlockerOfflineGuard' -Action $oa -Trigger @($ot1, $ot2) -Settings $os -Principal $op -Force | Out-Null
  Write-Host 'OfflineGuard: SixVPNBlockerOfflineGuard (10 min + logon 2 min)' -ForegroundColor Green
}

Write-Host ""
Write-Host "Win+Search: Focus Fense" -ForegroundColor Cyan
