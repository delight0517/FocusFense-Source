# Batch verification for remaining TODO NEXT ACTIONS (shell-automatable).
$ErrorActionPreference = 'Continue'
$six = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$report = [ordered]@{
  at = (Get-Date).ToString('o')
  checks = @()
  ok = $true
}

function Add-Check {
  param(
    [string]$Id,
    [bool]$Pass,
    [string]$Detail
  )
  $script:report.checks += @{ id = $Id; pass = $Pass; detail = $Detail }
  if (-not $Pass) { $script:report.ok = $false }
  $color = if ($Pass) { 'Green' } else { 'Red' }
  $tag = if ($Pass) { 'OK' } else { 'FAIL' }
  Write-Host "[$tag] $Id - $Detail" -ForegroundColor $color
}

Write-Host '=== Verify-TodoBatch ===' -ForegroundColor Cyan

$vbs = Join-Path $six 'Launch-6VPN-Chrome.vbs'
$vbsOk = Test-Path -LiteralPath $vbs
$roots = @(
  (Join-Path $env:USERPROFILE 'Desktop'),
  (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
  (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
)
$chromeLnks = 0
$protectedLnks = 0
foreach ($root in $roots) {
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -EA SilentlyContinue |
    ForEach-Object {
      try {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($_.FullName)
        $t = ($sc.TargetPath -replace '/', '\').ToLowerInvariant()
        if ($t -notmatch 'chrome') { return }
        $script:chromeLnks++
        if ($t -match 'launch-6vpn-chrome\.vbs$') { $script:protectedLnks++ }
      } catch {}
    }
}
Add-Check -Id 'boot_shortcut_hijack' -Pass ($vbsOk -and ($protectedLnks -gt 0 -or $chromeLnks -eq 0)) -Detail "vbs=$vbsOk chrome_lnks=$chromeLnks protected=$protectedLnks"

$exe = Join-Path $env:LOCALAPPDATA 'Programs\SixVPNBlocker\six_clean_room.exe'
$runVal = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name SixVPNBlocker -ErrorAction SilentlyContinue).SixVPNBlocker
$runOk = ($null -ne $runVal) -and ($runVal -match 'six_clean_room\.exe') -and ($runVal -notmatch 'cmd\.exe') -and (Test-Path -LiteralPath $exe)
Add-Check -Id 'autostart_run' -Pass $runOk -Detail "value=$runVal exe_exists=$(Test-Path $exe)"

$hosts = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
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
Add-Check -Id 'hosts_lock' -Pass ($managed -and ($ro -or -not $writable)) -Detail "managed=$managed readonly=$ro writable=$writable"

$vid = 'so-rv8rlcuc'
$bl = reg query 'HKCU\Software\Policies\Google\Chrome\URLBlocklist' /s 2>&1 | Out-String
$pac = Join-Path $six 'sixvpn_block.pac'
$pacHit = $false
if (Test-Path -LiteralPath $pac) {
  $pacHit = Select-String -LiteralPath $pac -Pattern $vid -Quiet
}
Add-Check -Id 'chrome_plain_block' -Pass (($bl -match $vid) -and $pacHit) -Detail "urlblock=$($bl -match $vid) pac=$pacHit"

$extManifest = Join-Path $six 'chrome_blocker\manifest.json'
$vbsContent = ''
if (Test-Path -LiteralPath $vbs) { $vbsContent = Get-Content -LiteralPath $vbs -Raw }
Add-Check -Id 'load_extension_path' -Pass ((Test-Path -LiteralPath $extManifest) -and ($vbsContent -match 'load-extension')) -Detail "manifest=$(Test-Path $extManifest)"

$koreanEnc = '%EB%B3%B4%EB%94%B0'
$ffBl = reg query 'HKCU\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block' /s 2>&1 | Out-String
$hasKorean = ($bl -match [regex]::Escape($koreanEnc)) -or ($ffBl -match [regex]::Escape($koreanEnc))
$snap = Join-Path $six 'chrome_blocker\rules_snapshot.json'
if (-not $hasKorean -and (Test-Path -LiteralPath $snap)) {
  $hasKorean = (Get-Content -LiteralPath $snap -Raw) -match '보따'
}
Add-Check -Id 'korean_channel_block' -Pass $hasKorean -Detail 'encoded_or_snapshot'

$updates = Join-Path $six 'chrome_blocker\updates.xml'
$forcelist = reg query 'HKCU\Software\Policies\Google\Chrome\ExtensionInstallForcelist' /v 1 2>&1
Add-Check -Id 'extension_auto_recovery' -Pass (((Test-Path -LiteralPath $updates) -or (Test-Path -LiteralPath (Join-Path $six 'chrome_blocker.crx'))) -and ($LASTEXITCODE -eq 0)) -Detail "updates=$(Test-Path -LiteralPath $updates) forcelist=$($LASTEXITCODE -eq 0)"

$ytGuard = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug\youtube_proactive_guard_last.json'
$ytBoot = Join-Path $env:USERPROFILE 'Documents\SixVPN_Blocker_Debug\youtube_hosts_autofix_last.json'
Add-Check -Id 'youtube_proactive_json' -Pass ((Test-Path -LiteralPath $ytGuard) -or (Test-Path -LiteralPath $ytBoot)) -Detail "guard=$(Test-Path -LiteralPath $ytGuard) autofix=$(Test-Path -LiteralPath $ytBoot)"

$out = Join-Path $six 'verify_todo_batch.json'
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host "Report: $out"
$overall = if ($report.ok) { 'PASS' } else { 'FAIL' }
Write-Host "Overall: $overall" -ForegroundColor $(if ($report.ok) { 'Green' } else { 'Red' })
exit $(if ($report.ok) { 0 } else { 1 })
