# Verifies 5 cross-browser URL leak seals (registry + files, no browser launch).
$ErrorActionPreference = 'Continue'
$six = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$pac = Join-Path $six 'sixvpn_block.pac'
$vbs = Join-Path $six 'Launch-6VPN-Chrome.vbs'
$userChrome = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk'
$pass = 0
$fail = 0

function Test-Scenario {
  param([string]$Name, [bool]$Ok, [string]$Detail)
  if ($Ok) {
    $script:pass++
    Write-Host "[OK] $Name - $Detail" -ForegroundColor Green
  } else {
    $script:fail++
    Write-Host "[FAIL] $Name - $Detail" -ForegroundColor Red
  }
}

Write-Host '=== Test-CrossBrowserLeakGuard (5 scenarios) ===' -ForegroundColor Cyan

# 1 Plain launch path
$vbsOk = (Test-Path -LiteralPath $vbs) -and ((Get-Content -LiteralPath $vbs -Raw) -match 'load-extension')
$userLnkOk = $false
if (Test-Path -LiteralPath $userChrome) {
  $sh = New-Object -ComObject WScript.Shell
  $tp = ($sh.CreateShortcut($userChrome).TargetPath -replace '/','\').ToLowerInvariant()
  $userLnkOk = $tp -match 'launch-6vpn-chrome\.vbs$'
}
Test-Scenario '1_plain_launch' ($vbsOk -and $userLnkOk) "vbs=$vbsOk user_lnk=$userLnkOk"

# 2 Derivative Chromium (Whale sample)
$whaleBl = 'HKCU\SOFTWARE\Policies\NAVER\Whale\URLBlocklist'
$whalePac = (reg query 'HKCU\SOFTWARE\Policies\NAVER\Whale' /v ProxyPacUrl 2>&1 | Out-String)
$derivOk = (Test-Path -LiteralPath "Registry::$whaleBl") -or ($whalePac -match 'sixvpn_block\.pac')
Test-Scenario '2_derivative_chromium' $derivOk "whale_blocklist_or_pac"

# 3 Firefox DoH + PAC user.js
$ffProfiles = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
$ffOk = $false
if (Test-Path -LiteralPath $ffProfiles) {
  $uj = Get-ChildItem -LiteralPath $ffProfiles -Filter user.js -Recurse -EA SilentlyContinue | Select-Object -First 1
  if ($uj) {
    $c = Get-Content -LiteralPath $uj.FullName -Raw
    $ffOk = ($c -match 'network\.trr\.mode') -and (
      ($c -match 'autoconfig_url') -or -not (Test-Path -LiteralPath $pac)
    )
  }
}
if (-not (Test-Path -LiteralPath $ffProfiles)) { $ffOk = $true }
Test-Scenario '3_firefox_doh_pac' $ffOk "profiles_checked"

# 4 Network stack (Chrome primary)
$chromeDoh = (reg query 'HKCU\SOFTWARE\Policies\Google\Chrome' /v DnsOverHttpsMode 2>&1 | Out-String)
$chromeQuic = (reg query 'HKCU\SOFTWARE\Policies\Google\Chrome' /v QuicAllowed 2>&1 | Out-String)
$netOk = ($chromeDoh -match 'off') -and ($chromeQuic -match '0x0')
Test-Scenario '4_network_stack' $netOk "doh_off quic_off"

# 5 Policy precedence (incognito off)
$incog = (reg query 'HKCU\SOFTWARE\Policies\Google\Chrome' /v IncognitoModeAvailability 2>&1 | Out-String)
$polOk = $incog -match '0x1'
Test-Scenario '5_policy_precedence' $polOk "incognito_disabled=$polOk"

Write-Host "`nResult: $pass/5 PASS, $fail FAIL" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
exit $(if ($fail -eq 0) { 0 } else { 1 })
