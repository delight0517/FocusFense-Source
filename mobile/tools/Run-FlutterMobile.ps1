# Run `flutter` from the SDK without machine PATH. All args pass through.
#   powershell -NoProfile -ExecutionPolicy Bypass -File "mobile\tools\Run-FlutterMobile.ps1" analyze
#   powershell ... Run-FlutterMobile.ps1 build windows --release

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $FlutterArgs
)

$ErrorActionPreference = 'Stop'
$toolsDir = $PSScriptRoot
$mobileRoot = Split-Path -Parent $toolsDir
Set-Location -LiteralPath $mobileRoot

. (Join-Path $toolsDir 'FlutterSdk.ps1')
$flutterBat = Get-FlutterBatPath
if (-not $flutterBat) {
  Write-Host 'Flutter SDK not found. See docs/CURSOR_AGENT_WINDOWS_FLUTTER_SHELL_BLUEPRINT.md' -ForegroundColor Red
  exit 1
}

& $flutterBat @FlutterArgs
exit $LASTEXITCODE
