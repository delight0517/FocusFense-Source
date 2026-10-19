# Test-CorePrinciples.ps1 — verify A/B/C blocker blueprint on this PC
param(
  [string]$TestVideoId = 'so-Rv8RlCUc',
  [string]$SixVpnDir = "$env:LOCALAPPDATA\SixVPNBlocker"
)

$ErrorActionPreference = 'Continue'
$report = @{
  at = (Get-Date).ToString('o')
  principles = @()
  ok = $false
}

function Add-P([string]$id, [string]$name, [bool]$pass, [string]$detail) {
  $script:report.principles += @{ id = $id; name = $name; pass = $pass; detail = $detail }
}

# A — Chrome policy (forcelist + URLBlocklist + ExtensionSettings)
$forcelist = reg query 'HKCU\Software\Policies\Google\Chrome\ExtensionInstallForcelist' /v 1 2>$null
$flOk = $LASTEXITCODE -eq 0
$proxy = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Google\Chrome' -Name ProxyMode -EA SilentlyContinue).ProxyMode
$vid = $TestVideoId.ToLowerInvariant()
$blCount = @(reg query 'HKCU\Software\Policies\Google\Chrome\URLBlocklist' 2>$null | Select-String $vid).Count
$bl = $blCount -gt 0
$extSettings = reg query 'HKCU\Software\Policies\Google\Chrome' /v ExtensionSettings 2>$null
$devMode = reg query 'HKCU\Software\Policies\Google\Chrome' /v ExtensionDeveloperModeAvailability 2>$null
Add-P 'A' 'chrome_policy' ($flOk -and $bl -and ($proxy -eq 'pac_script')) "forcelist=$flOk urlblock_lines=$blCount proxy=$proxy extSettings=$($LASTEXITCODE -eq 0)"

# B — hosts lock
$hosts = "$env:WINDIR\System32\drivers\etc\hosts"
$ro = $false
$writable = $false
try {
  $item = Get-Item -LiteralPath $hosts -Force
  $ro = $item.IsReadOnly
  $fs = [System.IO.File]::Open($hosts, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
  $fs.Close()
  $writable = $true
} catch {}
$managed = Select-String -LiteralPath $hosts -Pattern '6 VPN Blocker BEGIN' -Quiet
Add-P 'B' 'hosts_lock' (($ro -and -not $writable) -or $managed) "readonly=$ro writable=$writable managed=$managed"

# C — account type
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-P 'C' 'standard_user_recommended' (-not $admin) "running_as_admin=$admin (standard=user_recommended)"

$pass = @($report.principles | Where-Object { $_.pass }).Count
$total = $report.principles.Count
$report.ok = ($pass -ge 2) -and ($report.principles | Where-Object { $_.id -eq 'A' }).pass
$report.summary = "$pass/$total principles OK; core=$($report.ok)"

$out = Join-Path $SixVpnDir 'core_principles_test.json'
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Output $report.summary
Write-Output "report=$out"
if (-not $report.ok) { exit 1 }
exit 0
