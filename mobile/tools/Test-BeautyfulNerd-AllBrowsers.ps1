# Live browser block test — @뷰티풀너드 channel + watch?v=9zz_j97kDIY
param(
  [switch]$SkipAppKillTest,
  [int]$NavTimeoutSec = 25
)

$ErrorActionPreference = 'Continue'
$SixVpnDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$extDir = Join-Path $SixVpnDir 'chrome_blocker'
$testDir = Join-Path $SixVpnDir '_live_browser_probe'
New-Item -ItemType Directory -Force -Path $testDir | Out-Null

$blockVideo = 'https://www.youtube.com/watch?v=9zz_j97kDIY'
$blockChannel = 'https://www.youtube.com/@%EB%B7%B0%ED%8B%B0%ED%92%80%EB%84%88%EB%93%9C'
$allowVideo = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'

$report = [ordered]@{
  at = (Get-Date).ToString('o')
  api = @()
  dns = @()
  browsers = @()
  scenarios = @()
  overallPass = $true
}

function Note-Pass([string]$msg) { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Note-Fail([string]$msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:report.overallPass = $false }

function Test-ApiBlock {
  param([string]$Label, [string]$Uri)
  try {
    $r = Invoke-RestMethod -Uri $Uri -TimeoutSec 10
    $ok = [bool]$r.blocked
  } catch {
    $ok = $false
    $r = @{ error = $_.Exception.Message }
  }
  $report.api += [ordered]@{ label = $Label; uri = $Uri; blocked = $ok; detail = $r }
  if ($ok) { Note-Pass "API $Label blocked" } else { Note-Fail "API $Label NOT blocked" }
}

function Test-Dns {
  param([string]$Host, [bool]$ShouldBlock)
  $row = [ordered]@{ host = $Host; shouldBlock = $ShouldBlock }
  try {
    $ip = [System.Net.Dns]::GetHostAddresses($Host)[0].IPAddressToString
    $row.resolved = $ip
    $blocked = ($ip -eq '0.0.0.0' -or $ip -eq '127.0.0.1')
    $row.blocked = $blocked
    $ok = ($blocked -eq $ShouldBlock)
  } catch {
    $row.error = $_.Exception.Message
    $ok = $ShouldBlock
    $row.blocked = $true
  }
  $report.dns += $row
  if ($ok) { Note-Pass "DNS $Host expectBlock=$ShouldBlock" } else { Note-Fail "DNS $Host expectBlock=$ShouldBlock got=$($row.resolved)" }
}

function Get-ChromiumBlockMarkers {
  param([string]$Dom, [string]$Stderr)
  $text = "$Dom`n$Stderr"
  $markers = @(
    'ERR_BLOCKED_BY_CLIENT',
    'ERR_BLOCKED_BY_ADMINISTRATOR',
    'ERR_PROXY_CONNECTION_FAILED',
    'data-sixvpn-blocked',
    'sixvpn-block-overlay',
    '차단',
    'blocked by',
    'This site can'
  )
  $hits = @($markers | Where-Object { $text -match [regex]::Escape($_) -or $text -match $_ })
  return $hits
}

function Invoke-ChromiumProbe {
  param(
    [string]$BrowserName,
    [string]$Exe,
    [string]$Url,
    [bool]$ExpectBlocked,
    [string]$ProfileDir = $null
  )
  $slug = ($Url -replace '[^\w]', '_').Substring(0, [Math]::Min(40, ($Url -replace '[^\w]', '_').Length))
  $outFile = Join-Path $testDir "${BrowserName}_${slug}.html"
  $errFile = Join-Path $testDir "${BrowserName}_${slug}.err.txt"
  $userDir = if ($ProfileDir) { $ProfileDir } else { Join-Path $testDir "${BrowserName}_profile" }
  New-Item -ItemType Directory -Force -Path $userDir | Out-Null

  $args = @(
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    "--user-data-dir=$userDir",
    '--dump-dom',
    $Url
  )
  if (Test-Path -LiteralPath $extDir) {
    $args = @(
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      "--user-data-dir=$userDir",
      "--disable-extensions-except=$extDir",
      "--load-extension=$extDir",
      '--dump-dom',
      $Url
    )
  }

  $p = Start-Process -FilePath $Exe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
  $dom = ''
  $err = ''
  if (Test-Path $outFile) { $dom = Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
  if (Test-Path $errFile) { $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue }
  $markers = Get-ChromiumBlockMarkers -Dom $dom -Stderr $err
  $blocked = ($markers.Count -gt 0)
  # Allow-list: real YouTube watch page has ytd-player / ytInitialPlayerResponse
  if (-not $blocked -and $dom -match 'ytInitialPlayerResponse|ytd-watch-flexy|watch-title') {
    $blocked = $false
  }
  $ok = ($blocked -eq $ExpectBlocked)
  $row = [ordered]@{
    browser = $BrowserName
    url = $Url
    expectBlocked = $ExpectBlocked
    blocked = $blocked
    exitCode = $p.ExitCode
    markers = $markers
    domLen = $dom.Length
    pass = $ok
  }
  if ($ok) { Note-Pass "$BrowserName $(if ($ExpectBlocked) { 'BLOCK' } else { 'ALLOW' }) $Url" }
  else { Note-Fail "$BrowserName expected blocked=$ExpectBlocked got=$blocked markers=$($markers -join ',') domLen=$($dom.Length)" }
  return $row
}

function Invoke-FirefoxProbe {
  param([string]$Url, [bool]$ExpectBlocked)
  $ff = "${env:ProgramFiles}\Mozilla Firefox\firefox.exe"
  if (-not (Test-Path -LiteralPath $ff)) {
    Note-Fail 'Firefox not installed'
    return [ordered]@{ browser = 'Firefox'; pass = $false; detail = 'missing exe' }
  }
  $slug = ($Url -replace '[^\w]', '_').Substring(0, [Math]::Min(40, ($Url -replace '[^\w]', '_').Length))
  $outFile = Join-Path $testDir "firefox_${slug}.html"
  $profile = Join-Path $testDir 'firefox_profile'
  New-Item -ItemType Directory -Force -Path $profile | Out-Null
  $args = @('-headless', '-profile', $profile, '-url', $Url)
  $p = Start-Process -FilePath $ff -ArgumentList $args -Wait -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $outFile -RedirectStandardError (Join-Path $testDir "firefox_${slug}.err.txt")
  Start-Sleep -Seconds 3
  $dom = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
  $blocked = ($dom -match 'Website blocked|차단|blocked') -or ($dom.Length -lt 200)
  if ($dom -match 'ytInitialPlayerResponse|ytd-watch-flexy') { $blocked = $false }
  $ok = ($blocked -eq $ExpectBlocked)
  if ($ok) { Note-Pass "Firefox $(if ($ExpectBlocked) { 'BLOCK' } else { 'ALLOW' }) $Url" }
  else { Note-Fail "Firefox expected blocked=$ExpectBlocked domLen=$($dom.Length)" }
  return [ordered]@{ browser = 'Firefox'; url = $Url; expectBlocked = $ExpectBlocked; blocked = $blocked; pass = $ok; domLen = $dom.Length }
}

Write-Host '=== API + DNS ===' -ForegroundColor Cyan
Test-ApiBlock -Label 'video_9zz' -Uri 'http://127.0.0.1:17361/youtube/check?v=9zz_j97kDIY'
Test-ApiBlock -Label 'video_control' -Uri 'http://127.0.0.1:17361/youtube/check?v=dQw4w9WgXcQ'
Test-ApiBlock -Label 'channel' -Uri 'http://127.0.0.1:17361/youtube/channel-check?path=/@%EB%B7%B0%ED%8B%B0%ED%92%80%EB%84%88%EB%93%9C'
Test-Dns -Host 'www.youtube.com' -ShouldBlock $false
Test-Dns -Host 'pornhub.com' -ShouldBlock $true

Write-Host '=== Sync policies (Test-ChromeBlock) ===' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Test-ChromeBlock.ps1') -TestVideoId '9zz_j97kDIY' -SecondaryVideoId 'so-Rv8RlCUc' 2>&1 | Out-Host

Write-Host '=== Live browser probes ===' -ForegroundColor Cyan
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
foreach ($pair in @(
  @{ u = $blockVideo; b = $true },
  @{ u = $blockChannel; b = $true },
  @{ u = $allowVideo; b = $false }
)) {
  if (Test-Path $chrome) {
    $report.browsers += Invoke-ChromiumProbe -BrowserName 'Chrome' -Exe $chrome -Url $pair.u -ExpectBlocked $pair.b
  }
  if (Test-Path $edge) {
    $report.browsers += Invoke-ChromiumProbe -BrowserName 'Edge' -Exe $edge -Url $pair.u -ExpectBlocked $pair.b
  }
  $report.browsers += Invoke-FirefoxProbe -Url $pair.u -ExpectBlocked $pair.b
}

Write-Host '=== Extension forcelist + delete recovery ===' -ForegroundColor Cyan
$fl = reg query 'HKCU\Software\Policies\Google\Chrome\ExtensionInstallForcelist' 2>&1
$flOk = ($LASTEXITCODE -eq 0) -and ($fl -match 'popjkofklmidngceakpcokopghehjngo')
$report.scenarios += [ordered]@{ name = 'chrome_forcelist'; pass = $flOk }
if ($flOk) { Note-Pass 'Chrome forcelist present' } else { Note-Fail 'Chrome forcelist missing' }

& (Join-Path $PSScriptRoot 'Test-ExtensionAutoRecovery.ps1') 2>&1 | Out-Host
$recOk = ($LASTEXITCODE -eq 0)
$report.scenarios += [ordered]@{ name = 'ext_delete_recovery'; pass = $recOk }

if (-not $SkipAppKillTest) {
  Write-Host '=== App kill persistence (hosts/PAC/URLBlocklist/API down) ===' -ForegroundColor Cyan
  $appProc = Get-Process -Name 'six_clean_room' -ErrorAction SilentlyContinue
  if ($appProc) {
    Stop-Process -Id $appProc.Id -Force
    Start-Sleep -Seconds 3
    $apiDown = $false
    try {
      Invoke-RestMethod 'http://127.0.0.1:17361/rules' -TimeoutSec 2 | Out-Null
    } catch { $apiDown = $true }
    $bl = reg query 'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist' /s 2>&1 | Out-String
    $pac = (Get-ItemProperty 'HKCU:\Software\Policies\Google\Chrome' -Name ProxyPacUrl -ErrorAction SilentlyContinue).ProxyPacUrl
    $hasChannel = ($bl -match '%EB%B7%B0' -or $bl -match '뷰티')
    $chromeAfterKill = $false
    if (Test-Path $chrome) {
      $probe = Invoke-ChromiumProbe -BrowserName 'Chrome_after_kill' -Exe $chrome -Url $blockVideo -ExpectBlocked $true
      $chromeAfterKill = $probe.pass
      $report.scenarios += [ordered]@{ name = 'chrome_block_after_app_kill'; pass = $chromeAfterKill; detail = $probe }
    }
    $report.scenarios += [ordered]@{
      name = 'persistence_after_kill'
      apiDown = $apiDown
      urlBlocklistChannel = $hasChannel
      pacRegistered = ($pac -match 'sixvpn')
      pass = ($hasChannel -and ($pac -match 'sixvpn') -and $chromeAfterKill)
    }
    if ($hasChannel -and ($pac -match 'sixvpn') -and $chromeAfterKill) {
      Note-Pass 'Blocking persists after app kill (policy layers)'
    } else {
      Note-Fail "After kill: apiDown=$apiDown channelBl=$hasChannel pac=$pac chrome=$chromeAfterKill"
    }
    # Relaunch app for user
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\SixVPNBlocker\six_clean_room.exe'
    if (Test-Path $exe) { Start-Process -FilePath $exe -WindowStyle Normal }
  } else {
    Note-Fail 'App not running — skip kill test'
  }
}

$out = Join-Path $SixVpnDir 'beautyful_nerd_browser_test.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host ""
Write-Host "Report: $out" -ForegroundColor Cyan
Write-Host ("Overall: " + $(if ($report.overallPass) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($report.overallPass) { 'Green' } else { 'Red' })
exit $(if ($report.overallPass) { 0 } else { 1 })
