@echo off
setlocal EnableExtensions
REM Double-click rebuild (no broken .lnk). Lives next to Rebuild-6VPN-Windows.ps1
set "TOOLS=%~dp0"
set "PS1=%TOOLS%Rebuild-6VPN-Windows.ps1"
if not exist "%PS1%" (
  echo [ERROR] Missing: %PS1%
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -WaitAtEnd -LaunchAfter
exit /b %ERRORLEVEL%
