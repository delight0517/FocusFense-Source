# Resolves the Flutter `mobile` folder for in-app / terminal rebuild.
# Validates pubspec.yaml + non-empty Rebuild-6VPN-Windows.ps1.
# Persists last-good path to %LOCALAPPDATA%\SixVPNBlocker\rebuild_mobile_root.txt

$script:SixVpnMarkerDir = Join-Path $env:LOCALAPPDATA "SixVPNBlocker"
$script:SixVpnMarkerFile = Join-Path $SixVpnMarkerDir "rebuild_mobile_root.txt"
$script:SixVpnMinRebuildScriptBytes = 1500

function Test-SixVpnMobileRoot {
  param([Parameter(Mandatory)][string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
  $r = $Root.Trim().TrimEnd('\')
  $pub = Join-Path $r "pubspec.yaml"
  $rebuild = Join-Path $r "tools\Rebuild-6VPN-Windows.ps1"
  if (-not (Test-Path -LiteralPath $pub)) { return $false }
  if (-not (Test-Path -LiteralPath $rebuild)) { return $false }
  try {
    $len = (Get-Item -LiteralPath $rebuild).Length
    if ($len -lt $script:SixVpnMinRebuildScriptBytes) {
      Write-Host "[SixVPN] Rebuild script too small ($len bytes): $rebuild" -ForegroundColor Yellow
      return $false
    }
  } catch {
    return $false
  }
  return $true
}

function Write-SixVpnMobileRootMarker {
  param([Parameter(Mandatory)][string]$Root)
  $r = $Root.Trim().TrimEnd('\')
  if (-not (Test-SixVpnMobileRoot -Root $r)) { return $false }
  try {
    New-Item -ItemType Directory -Force -Path $script:SixVpnMarkerDir | Out-Null
    Set-Content -LiteralPath $script:SixVpnMarkerFile -Value $r -Encoding UTF8 -NoNewline
    return $true
  } catch {
    Write-Host "[SixVPN] Could not write marker: $_" -ForegroundColor Yellow
    return $false
  }
}

function Read-SixVpnMobileRootMarker {
  if (-not (Test-Path -LiteralPath $script:SixVpnMarkerFile)) { return $null }
  try {
    $t = (Get-Content -LiteralPath $script:SixVpnMarkerFile -Raw -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    if (Test-SixVpnMobileRoot -Root $t) { return $t.Trim().TrimEnd('\') }
    Write-Host "[SixVPN] Stale marker (path invalid): $t" -ForegroundColor Yellow
    Remove-Item -LiteralPath $script:SixVpnMarkerFile -Force -ErrorAction SilentlyContinue
  } catch { }
  return $null
}

function Find-SixVpnMobileRoot {
  # 1) Env override
  $envRoot = $env:SIXVPN_MOBILE_ROOT
  if ($envRoot -and (Test-SixVpnMobileRoot -Root $envRoot)) {
    return $envRoot.Trim().TrimEnd('\')
  }

  # 2) Marker from last successful rebuild / app save
  $marked = Read-SixVpnMobileRootMarker
  if ($marked) { return $marked }

  # 3) If this script lives under mobile\tools, use parent of tools
  $hereTools = $PSScriptRoot
  if ($hereTools -match '\\tools$') {
    $fromHere = Split-Path -Parent $hereTools
    if (Test-SixVpnMobileRoot -Root $fromHere) { return $fromHere }
  }

  # 4) Walk up from running six_clean_room.exe (if any)
  try {
    $exe = Get-Process -Name "six_clean_room" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe -and $exe.Path) {
      $d = Split-Path -Parent $exe.Path
      for ($i = 0; $i -lt 16; $i++) {
        if (Test-SixVpnMobileRoot -Root $d) { return $d.Trim().TrimEnd('\') }
        $parent = Split-Path -Parent $d
        if ($parent -eq $d) { break }
        $d = $parent
      }
    }
  } catch { }

  # 5) Common folder layouts (Desktop, app dev, repos)
  $candidates = @()
  if ($env:USERPROFILE) {
    $candidates += @(
      (Join-Path $env:USERPROFILE "Desktop\app dev\6VPN_Image_Blocker\mobile"),
      (Join-Path $env:USERPROFILE "Desktop\6VPN_Image_Blocker\mobile"),
      (Join-Path $env:USERPROFILE "Documents\6VPN_Image_Blocker\mobile"),
      (Join-Path $env:USERPROFILE "source\repos\6VPN_Image_Blocker\mobile")
    )
    $appDev = Join-Path $env:USERPROFILE "Desktop\app dev"
    if (Test-Path -LiteralPath $appDev) {
      Get-ChildItem -LiteralPath $appDev -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidates += (Join-Path $_.FullName "mobile")
      }
    }
    $desk = Join-Path $env:USERPROFILE "Desktop"
    if (Test-Path -LiteralPath $desk) {
      Get-ChildItem -LiteralPath $desk -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*VPN*' -or $_.Name -like '*Blocker*' } |
        ForEach-Object { $candidates += (Join-Path $_.FullName "mobile") }
    }
  }

  foreach ($c in $candidates) {
    if (Test-SixVpnMobileRoot -Root $c) { return $c.Trim().TrimEnd('\') }
  }

  # 6) Shallow search for Rebuild-6VPN-Windows.ps1 under Desktop (depth 5)
  if ($env:USERPROFILE) {
    $searchRoots = @(
      (Join-Path $env:USERPROFILE "Desktop"),
      (Join-Path $env:USERPROFILE "Documents")
    )
    foreach ($sr in $searchRoots) {
      if (-not (Test-Path -LiteralPath $sr)) { continue }
      try {
        $hits = Get-ChildItem -LiteralPath $sr -Filter "Rebuild-6VPN-Windows.ps1" -Recurse -Depth 5 -ErrorAction SilentlyContinue
        foreach ($hit in $hits) {
          if ($hit.DirectoryName -notmatch '\\tools$') { continue }
          $mobile = Split-Path -Parent $hit.DirectoryName
          if (Test-SixVpnMobileRoot -Root $mobile) { return $mobile.Trim().TrimEnd('\') }
        }
      } catch { }
    }
  }

  return $null
}

function Resolve-SixVpnMobileRoot {
  param([switch]$PersistMarker)
  $root = Find-SixVpnMobileRoot
  if ($root -and $PersistMarker) {
    Write-SixVpnMobileRootMarker -Root $root | Out-Null
  }
  return $root
}
