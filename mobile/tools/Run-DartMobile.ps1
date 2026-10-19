# Run `dart` from the same Flutter SDK bin (PATH optional).
#   powershell -NoProfile -ExecutionPolicy Bypass -File "mobile\tools\Run-DartMobile.ps1" analyze

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $DartArgs
)

$ErrorActionPreference = 'Stop'
$toolsDir = $PSScriptRoot
$mobileRoot = Split-Path -Parent $toolsDir
Set-Location -LiteralPath $mobileRoot

. (Join-Path $toolsDir 'FlutterSdk.ps1')
$flutterBat = Get-FlutterBatPath
if (-not $flutterBat) {
  Write-Host 'Flutter SDK not found (dart lives next to flutter). See docs/CURSOR_AGENT_WINDOWS_FLUTTER_SHELL_BLUEPRINT.md' -ForegroundColor Red
  exit 1
}

$binDir = Split-Path -Parent $flutterBat
$dartBat = Join-Path $binDir 'dart.bat'
if (-not (Test-Path -LiteralPath $dartBat)) {
  Write-Host "Missing: $dartBat" -ForegroundColor Red
  exit 1
}

& $dartBat @DartArgs
exit $LASTEXITCODE
