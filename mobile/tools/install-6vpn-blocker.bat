@echo off
chcp 65001 >nul
title 6 VPN Blocker — 무결점 설치
set "PS1=%ProgramData%\SixVPNBlocker\Install-6VPN-Bulletproof.ps1"
if not exist "%PS1%" (
  echo 먼저 앱에서 「쉬운 설치」를 한 번 실행하세요.
  echo PS1이 없습니다: %PS1%
  pause
  exit /b 1
)
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo 관리자 권한을 요청합니다...
    goto UACPrompt
) else ( goto gotAdmin )
:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\sixvpn_getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\sixvpn_getadmin.vbs"
    "%temp%\sixvpn_getadmin.vbs"
    exit /B
:gotAdmin
    if exist "%temp%\sixvpn_getadmin.vbs" del "%temp%\sixvpn_getadmin.vbs"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
echo 5초 후 창이 닫힙니다...
timeout /t 5 /nobreak >nul
