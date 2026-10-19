# Adds Flutter SDK bin to PATH for the *current* PowerShell session.
# Cursor 에이전트/로컬 셸에서 `flutter`·`dart`가 없을 때 사용.
#
# 사용 (저장소 루트 또는 아무 곳에서):
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& { . '...\mobile\tools\Ensure-FlutterOnPath.ps1' }"
# 또는 mobile 폴더 안에서:
#   . .\tools\Ensure-FlutterOnPath.ps1
#
# 이후:
#   flutter --version
#   flutter analyze
#   dart analyze

$ErrorActionPreference = "Stop"
$dotSourced = ($MyInvocation.InvocationName -eq '.')

. (Join-Path $PSScriptRoot "FlutterSdk.ps1")

$flutterExe = Get-FlutterBatPath
if (-not $flutterExe) {
  $msg = @"
[Ensure-FlutterOnPath] Flutter SDK를 찾지 못했습니다.

다음 중 하나를 하세요:
  1) https://docs.flutter.dev/get-started/install/windows 에서 SDK 설치
  2) 사용자 환경 변수 Path에 `<SDK>\bin` 추가 후 Cursor 터미널 재시작
  3) 사용자 또는 시스템 환경 변수 FLUTTER_ROOT = `<SDK 루트>` 설정 (bin 제외)

일반 설치 경로: $env:LOCALAPPDATA\flutter\bin\flutter.bat
"@
  Write-Host $msg -ForegroundColor Yellow
  if ($dotSourced) {
    throw "Flutter SDK not found (see Ensure-FlutterOnPath.ps1 message)."
  }
  exit 1
}

$binDir = Split-Path -Parent $flutterExe
if ($env:Path -notlike "*$binDir*") {
  $env:Path = "$binDir;$env:Path"
}

Write-Host "[Ensure-FlutterOnPath] OK: $binDir" -ForegroundColor Green
if (-not $dotSourced) {
  & $flutterExe --version
  exit $LASTEXITCODE
}
