$ErrorActionPreference = 'Stop'
$ext = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\chrome_blocker'
$browser = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (-not (Test-Path -LiteralPath $browser)) {
  $browser = Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'
}
$vbsPath = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\Launch-6VPN-Chrome.vbs'
$vbs = @"
' 6 VPN Blocker - Chrome (silent)
Option Explicit
Dim sh, browser, ext, cmd
ext = "$($ext -replace '"','""')"
browser = "$($browser -replace '"','""')"
Set sh = CreateObject("WScript.Shell")
cmd = """" & browser & """ --disable-extensions-except=""" & ext & """ --load-extension=""" & ext & """"
sh.Run cmd, 1, False
"@
Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII
Write-Host "Updated: $vbsPath"
if (Test-Path (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\tier3_watchdog_once.ps1')) {
  & (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\tier3_watchdog_once.ps1')
}
