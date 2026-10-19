$ErrorActionPreference = 'Continue'
$logDir = 'C:\tmp'
if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
$log = Join-Path $logDir 'sixvpn_firefox_signed_apply.log'
Start-Transcript -LiteralPath $log -Force | Out-Null
try {
  & (Join-Path $PSScriptRoot 'Apply-Firefox-SignedXpi-Now.ps1')
} finally {
  Stop-Transcript | Out-Null
}
