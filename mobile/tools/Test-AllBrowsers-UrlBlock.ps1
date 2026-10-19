# Test-AllBrowsers-UrlBlock.ps1 — every installed browser: policy + live headless leak probe.
param(
  [string[]]$TestUrls = @('https://mingky01.live/', 'https://linkdamoa01.com/'),
  [switch]$ApplyPolicyFirst,
  [int]$HeadlessTimeoutSec = 25
)

$ErrorActionPreference = 'Continue'
$sixVpn = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$reportPath = Join-Path $sixVpn 'debug\all_browsers_url_block_test.json'
New-Item -ItemType Directory -Force -Path (Split-Path $reportPath) | Out-Null

$hardKillIds = [System.Collections.ArrayList]@()
$report = [ordered]@{
  timestamp     = (Get-Date).ToString('o')
  buildHint     = $env:SIXVPN_BUILD_STAMP
  testUrls      = @($TestUrls)
  applyPolicy   = [bool]$ApplyPolicyFirst
  dnsProbes     = @()
  dnsSinkholeOk = $false
  browsers      = @()
  ok            = $false
  summaryKo     = ''
}

function Test-RegistryHasHosts {
  param([string]$Key, [string[]]$Hosts, [string]$PolicyFile)
  $found = @()
  if ($Key -and (Test-Path -LiteralPath "Registry::$Key" -ErrorAction SilentlyContinue)) {
    $out = reg query $Key 2>&1 | Out-String
    if ($out -match 'REG_SZ\s+<\*>') {
      return ,$Hosts
    }
    foreach ($h in $Hosts) {
      if ($out -match [regex]::Escape($h)) { $found += $h }
    }
  }
  if ($PolicyFile -and (Test-Path -LiteralPath $PolicyFile)) {
    try {
      $json = Get-Content -LiteralPath $PolicyFile -Raw | ConvertFrom-Json
      $list = @($json.URLBlocklist)
      $blob = ($list -join ' ').ToLowerInvariant()
      if ($blob -match '(^|\s)<\*>(\s|$)') {
        return ,$Hosts
      }
      foreach ($h in $Hosts) {
        if ($blob -match [regex]::Escape($h.ToLowerInvariant())) {
          if ($found -notcontains $h) { $found += $h }
        }
      }
    } catch {}
  }
  return ,$found
}

# Returns $true when Windows IFEO has a Debugger hook on $exeName (meaning
# the OS will intercept every launch of that exe and run our toast instead).
# Headless tests against such browsers always fail silently — never launch them.
function Test-IFEOBlocked([string]$exeName) {
  $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exeName"
  $dbg = (Get-ItemProperty -Path $key -Name Debugger -ErrorAction SilentlyContinue).Debugger
  return ($null -ne $dbg -and $dbg.Trim().Length -gt 0)
}

function Test-HeadlessLeak {
  param(
    [string]$Exe,
    [string]$Url,
    [string]$BrowserId
  )
  $hosts = @()
  try {
    $u = [Uri]$Url
    $hosts += $u.Host.ToLowerInvariant()
  } catch { return @{ blocked = $false; leaked = $true; detail = 'bad_url'; domLen = 0 } }

  # @incident: firefox_work_window_closed — never terminate existing browsers.
  # The probe gets its own profile; only its newly returned PID may be cleaned up.

  $tmpdir = Join-Path $env:TEMP "sixvpn_allb_${BrowserId}_$(Get-Random)"
  $profile = Join-Path $tmpdir 'profile'
  New-Item -ItemType Directory -Force -Path $profile | Out-Null
  $outFile = Join-Path $tmpdir 'out.txt'
  $errFile = Join-Path $tmpdir 'err.txt'

  $args = @(
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    "--user-data-dir=$profile", '--dump-dom', $Url
  )
  if ($BrowserId -eq 'firefox') {
    $args = @('-headless', '-new-instance', '-profile', $profile, '-url', $Url)
  }

  $blocked = $false
  $leaked = $false
  $domLen = 0
  $detail = ''

  try {
    $p = Start-Process -FilePath $Exe -ArgumentList $args -PassThru -WindowStyle Hidden `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $waited = $false
    if ($p) {
      $waited = $p.WaitForExit([Math]::Max(5, $HeadlessTimeoutSec) * 1000)
      if (-not $waited) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        $dom = if (Test-Path $outFile) { Get-Content $outFile -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($null -eq $dom) { $dom = '' }
        $domLen = $dom.Length
        foreach ($m in @('mingky01', 'linkdamoa01', 'mingky', 'linkdamoa')) {
          if ($dom -match $m) { $leaked = $true; break }
        }
        if (-not $leaked -and $domLen -gt 8000) { $leaked = $true }
        $detail = "timeout_${HeadlessTimeoutSec}s domLen=$domLen"
        return @{ blocked = (-not $leaked -and $domLen -lt 1500); leaked = $leaked; detail = $detail; domLen = $domLen }
      }
    }
    $dom = if (Test-Path $outFile) { Get-Content $outFile -Raw -ErrorAction SilentlyContinue } else { '' }
    $err = if (Test-Path $errFile) { Get-Content $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
    if ($null -eq $dom) { $dom = '' }
    if ($null -eq $err) { $err = '' }
    $domLen = $dom.Length
    $combined = "$dom`n$err".ToLowerInvariant()

    $blockMarkers = @(
      'err_blocked_by_administrator', 'err_blocked_by_client', 'blocked_by_administrator',
      'err_proxy_connection_failed', 'net::err_blocked', 'this site can''t be reached',
      'access to .* was denied', 'err_connection_refused', 'err_name_not_resolved'
    )
    foreach ($m in $blockMarkers) {
      if ($combined -match $m) { $blocked = $true; break }
    }

    if (-not $blocked) {
      $leakMarkers = @('mingky01', 'linkdamoa01', 'mingky', 'linkdamoa', 'mingky01.live', 'linkdamoa01.com')
      foreach ($m in $leakMarkers) {
        if ($dom -match $m) { $leaked = $true; break }
      }
    }
    if ($blocked) {
      $leaked = $false
    } elseif (-not $leaked -and $domLen -gt 8000) {
      $leaked = $true
    }

    $detail = "exit=$($p.ExitCode) domLen=$domLen errLen=$($err.Length)"
  } catch {
    $detail = "headless_fail:$($_.Exception.Message)"
    $blocked = $false
    $leaked = $true
  } finally {
    Remove-Item -LiteralPath $tmpdir -Recurse -Force -ErrorAction SilentlyContinue
  }

  return @{ blocked = ($blocked -or (-not $leaked -and $domLen -lt 1500)); leaked = $leaked; detail = $detail; domLen = $domLen }
}

$browserDefs = @(
  @{
    id = 'chrome'; name = 'Google Chrome'; process = 'chrome.exe'
    exe = @(
      "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
      "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    regKey = 'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
    policyFile = $null
  },
  @{
    id = 'edge'; name = 'Microsoft Edge'; process = 'msedge.exe'
    exe = @(
      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
      "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    regKey = 'HKCU\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'
    policyFile = $null
  },
  @{
    id = 'firefox'; name = 'Firefox'; process = 'firefox.exe'
    exe = @(
      "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
      "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    )
    regKey = 'HKCU\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block'
    policyFile = $null
  },
  @{
    id = 'whale'; name = 'Naver Whale'; process = 'whale.exe'
    exe = @(
      "$env:ProgramFiles\Naver\Naver Whale\Application\whale.exe",
      "$env:LOCALAPPDATA\Naver\Naver Whale\Application\whale.exe"
    )
    regKey = 'HKCU\SOFTWARE\Policies\NAVER\Whale\URLBlocklist'
    policyFile = $null
  },
  @{
    id = 'brave'; name = 'Brave'; process = 'brave.exe'
    exe = @(
      "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
      "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
    )
    regKey = 'HKCU\SOFTWARE\Policies\BraveSoftware\Brave-Browser\URLBlocklist'
    policyFile = $null
  },
  @{
    id = 'vivaldi'; name = 'Vivaldi'; process = 'vivaldi.exe'
    exe = @(
      "$env:ProgramFiles\Vivaldi\Application\vivaldi.exe",
      "$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe"
    )
    regKey = 'HKCU\SOFTWARE\Policies\Vivaldi\URLBlocklist'
    policyFile = $null
  },
  @{
    id = 'opera'; name = 'Opera'; process = 'opera.exe'
    exe = @(
      "$env:ProgramFiles\Opera\opera.exe",
      "$env:LOCALAPPDATA\Programs\Opera\opera.exe"
    )
    regKey = 'HKCU\SOFTWARE\Policies\Opera Software\Opera Stable\URLBlocklist'
    policyFile = Join-Path $env:APPDATA 'Opera Software\Opera Stable\policies\managed\policies.json'
  }
)

if ($ApplyPolicyFirst) {
  $batch = Join-Path $sixVpn 'policy_batch\apply_url_blocklist.ps1'
  $chromiumFullList = Join-Path $sixVpn 'policy_batch\url_blocklist_chromium_full.txt'
  $chromiumListOnlyList = Join-Path $sixVpn 'policy_batch\url_blocklist_chromium_list.txt'
  $legacyChromiumList = Join-Path $sixVpn 'policy_batch\url_blocklist_chromium.txt'
  $firefoxList = Join-Path $sixVpn 'policy_batch\url_blocklist_firefox.txt'
  if ((Test-Path $batch) -and (Test-Path $chromiumFullList) -and (Test-Path $chromiumListOnlyList)) {
    & $batch -ChromiumFullList $chromiumFullList -ChromiumListOnlyList $chromiumListOnlyList -FirefoxList $firefoxList -SkipChromeBlocklist 0 2>&1 | Out-Null
    $report.applyPolicy = $true
  } elseif ((Test-Path $batch) -and (Test-Path $legacyChromiumList)) {
    & $batch -ChromiumList $legacyChromiumList -FirefoxList $firefoxList -SkipChromeBlocklist 0 2>&1 | Out-Null
    $report.applyPolicy = $true
  }
}

$probeHosts = @()
foreach ($u in $TestUrls) {
  try { $probeHosts += ([Uri]$u).Host.ToLowerInvariant() } catch {}
}
$probeHosts = $probeHosts | Select-Object -Unique

$dnsAllOk = ($probeHosts.Count -gt 0)
foreach ($h in $probeHosts) {
  $ip = 'unknown'
  try {
    $r = Resolve-DnsName -Name $h -Type A -ErrorAction Stop | Select-Object -First 1
    $ip = $r.IPAddress
  } catch {
    $ip = 'lookup_failed'
  }
  $sink = ($ip -eq '0.0.0.0') -or ($ip -eq '127.0.0.1')
  if (-not $sink) { $dnsAllOk = $false }
  $report.dnsProbes += [ordered]@{ host = $h; ip = $ip; sinkholed = $sink }
}
$report.dnsSinkholeOk = $dnsAllOk

foreach ($def in $browserDefs) {
  $exe = $def.exe | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  $row = [ordered]@{
    id           = $def.id
    displayName  = $def.name
    installed    = [bool]$exe
    exe          = "$exe"
    registryOk   = $false
    registryHits = @()
    liveTests    = @()
    liveBlocked  = $false
    hardKill     = $false
    detailKo     = ''
  }

  if (-not $exe) {
    $row.detailKo = 'not_installed'
    $report.browsers += $row
    continue
  }

  # If Windows IFEO has a Debugger hook on this exe, any Start-Process call
  # is intercepted by our toast script — the browser never actually runs.
  # Skip the headless test entirely: IFEO is a hard OS-level block so no URL
  # can leak through it, and the headless Start-Process would just trigger the
  # "차단됨" toast every time the test runs.
  $exeName = Split-Path $exe -Leaf
  if (Test-IFEOBlocked $exeName) {
    $row.liveBlocked = $true
    $row.liveTests += [ordered]@{
      url     = 'all'
      blocked = $true
      leaked  = $false
      detail  = 'ifeo_os_blocked_skip'
      domLen  = 0
    }
    # IFEO-blocked browsers cannot open at all — no hard-kill needed.
    $row.hardKill = $false
    $row.detailKo = 'ifeo_os_blocked_ok'
    $report.browsers += $row
    continue
  }

  $regHits = Test-RegistryHasHosts -Key $def.regKey -Hosts $probeHosts -PolicyFile $def.policyFile
  $row.registryHits = @($regHits)
  $row.registryOk = ($regHits.Count -ge $probeHosts.Count)

  $anyLeak = $false
  $allBlocked = $true
  foreach ($url in $TestUrls) {
    $live = Test-HeadlessLeak -Exe $exe -Url $url -BrowserId $def.id
    $row.liveTests += [ordered]@{
      url     = $url
      blocked = [bool]$live.blocked
      leaked  = [bool]$live.leaked
      detail  = $live.detail
      domLen  = $live.domLen
    }
    if ($live.leaked) { $anyLeak = $true }
    if (-not $live.blocked) { $allBlocked = $false }
  }

  $row.liveBlocked = $allBlocked -and -not $anyLeak

  # Hard-kill only when the browser can actually leak. Some browsers are
  # blocked by IFEO or a live policy even if this script cannot find every
  # sample host in that browser's registry key.
  if ($anyLeak -or (-not $row.registryOk -and -not $row.liveBlocked)) {
    $row.hardKill = $true
    [void]$hardKillIds.Add($def.id)
    if ($anyLeak -and $row.registryOk) {
      $row.detailKo = 'registry_ok_but_live_leak_hard_kill'
    } elseif (-not $row.registryOk) {
      $row.detailKo = 'registry_missing_test_hosts_hard_kill'
    } else {
      $row.detailKo = 'url_block_failed_hard_kill'
    }
  } else {
    $row.detailKo = 'policy_and_live_ok'
  }

  $report.browsers += $row
}

$installed = @($report.browsers | Where-Object { $_.installed })
$okCount = @($installed | Where-Object { -not $_.hardKill }).Count
$report.hardKillIds = @($hardKillIds)
$report.ok = ($installed.Count -gt 0) -and ($hardKillIds.Count -eq 0)
$report.summaryKo = "dns=$dnsAllOk installed=$($installed.Count) ok=$okCount hard_kill=$($hardKillIds.Count) [$($hardKillIds -join ', ')]"

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "=== All-browsers URL block test ===" -ForegroundColor Cyan
Write-Host $report.summaryKo
Write-Host "Report: $reportPath"
foreach ($b in $report.browsers) {
  if (-not $b.installed) { continue }
  $color = if ($b.hardKill) { 'Red' } else { 'Green' }
  Write-Host "  $($b.displayName): registry=$($b.registryOk) live=$($b.liveBlocked) hardKill=$($b.hardKill) - $($b.detailKo)" -ForegroundColor $color
}
if (-not $report.ok) { exit 1 }
exit 0
