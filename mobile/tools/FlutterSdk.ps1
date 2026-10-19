# Shared Flutter SDK resolution for Windows (PATH optional).
# Dot-source from other scripts:  . "$PSScriptRoot\FlutterSdk.ps1"

function Get-FlutterBatPath {
  [CmdletBinding()]
  param()

  $candidates = New-Object System.Collections.Generic.List[string]

  if ($env:FLUTTER_ROOT) {
    $candidates.Add((Join-Path $env:FLUTTER_ROOT "bin\flutter.bat"))
    $candidates.Add((Join-Path $env:FLUTTER_ROOT "bin\flutter.cmd"))
  }

  $toolsDir = $PSScriptRoot
  $mobileRoot = Split-Path -Parent $toolsDir
  $fvmBat = Join-Path $mobileRoot ".fvm\flutter_sdk\bin\flutter.bat"
  $candidates.Add($fvmBat)

  $userProfile = $env:USERPROFILE
  $local = $env:LOCALAPPDATA
  if ($local) {
    $candidates.Add((Join-Path $local "flutter\bin\flutter.bat"))
  }
  if ($userProfile) {
    $candidates.Add((Join-Path $userProfile "flutter\bin\flutter.bat"))
    $candidates.Add((Join-Path $userProfile "development\flutter\bin\flutter.bat"))
    $candidates.Add((Join-Path $userProfile "sdk\flutter\bin\flutter.bat"))
    $candidates.Add((Join-Path $userProfile "scoop\apps\flutter\current\bin\flutter.bat"))
    $candidates.Add((Join-Path $userProfile "scoop\shims\flutter.bat"))
  }

  $candidates.Add("C:\src\flutter\bin\flutter.bat")
  $candidates.Add("C:\flutter\bin\flutter.bat")
  $candidates.Add("C:\tools\flutter\bin\flutter.bat")

  foreach ($p in $candidates) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (Test-Path -LiteralPath $p) {
      return $p
    }
  }

  foreach ($segment in ($env:Path -split ';')) {
    $dir = $segment.Trim()
    if ([string]::IsNullOrWhiteSpace($dir)) { continue }
    foreach ($name in @('flutter.bat', 'flutter.cmd')) {
      $p = Join-Path $dir $name
      if (Test-Path -LiteralPath $p) {
        return $p
      }
    }
  }

  try {
    $cmd = Get-Command flutter -ErrorAction Stop
    if ($cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
      return $cmd.Source
    }
  } catch {
    # ignore
  }

  return $null
}
