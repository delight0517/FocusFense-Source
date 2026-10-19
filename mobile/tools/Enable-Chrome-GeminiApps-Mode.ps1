param()

$ErrorActionPreference = 'Stop'

$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\chrome.exe'
if (Test-Path -LiteralPath $ifeo) {
  Remove-ItemProperty -LiteralPath $ifeo -Name Debugger -ErrorAction SilentlyContinue
}

$allow = @(
  '*://mail.google.com/*',
  'https://mail.google.com/*',
  '*://gmail.com/*',
  '*://gemini.google.com/*',
  '*://bard.google.com/*',
  '*://accounts.google.com/*',
  'https://accounts.google.com/*',
  '*://accounts.google.com/signin/*',
  '*://accounts.google.com/v3/signin/*',
  '*://signin.google.com/*',
  '*://myaccount.google.com/*',
  '*://ogs.google.com/*',
  '*://www.gstatic.com/*',
  '*://ssl.gstatic.com/*',
  '*://fonts.gstatic.com/*',
  '*://apis.google.com/*',
  '*://content.googleapis.com/*',
  '*://workspace.google.com/*',
  '*://music.youtube.com/*'
)

function Set-ChromePolicy([string]$root) {
  if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -Force | Out-Null }
  Set-ItemProperty -LiteralPath $root -Name 'BuiltInDnsClientEnabled' -Value 0 -Type DWord -Force
  Set-ItemProperty -LiteralPath $root -Name 'DnsOverHttpsMode' -Value 'off' -Type String -Force

  $blockKey = Join-Path $root 'URLBlocklist'
  if (Test-Path -LiteralPath $blockKey) { Remove-Item -LiteralPath $blockKey -Recurse -Force }
  New-Item -Path $blockKey -Force | Out-Null
  Set-ItemProperty -LiteralPath $blockKey -Name '1' -Value '<*>' -Type String -Force

  $allowKey = Join-Path $root 'URLAllowlist'
  if (Test-Path -LiteralPath $allowKey) { Remove-Item -LiteralPath $allowKey -Recurse -Force }
  New-Item -Path $allowKey -Force | Out-Null
  for ($i = 0; $i -lt $allow.Count; $i++) {
    Set-ItemProperty -LiteralPath $allowKey -Name ($i + 1) -Value $allow[$i] -Type String -Force
  }
}

Set-ChromePolicy 'HKCU:\SOFTWARE\Policies\Google\Chrome'
Set-ChromePolicy 'HKLM:\SOFTWARE\Policies\Google\Chrome'

Write-Output 'CHROME_GEMINI_APPS_MODE_OK'
