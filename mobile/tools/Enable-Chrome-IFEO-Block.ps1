param()

$ErrorActionPreference = 'Stop'

$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\chrome.exe'
$toast = 'C:\ProgramData\SixVPNBlocker\ShowBlockedBrowserToast.ps1'
$debugger = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $toast + '"'

New-Item -Path $key -Force | Out-Null
Set-ItemProperty -LiteralPath $key -Name Debugger -Value $debugger -Type String -Force

Get-ItemProperty -LiteralPath $key | Select-Object Debugger | Format-List
