# Simulates a new browser appearing: removes one id from known_browsers_v1.json
# then runs a scan (read-only) of install candidates.
param(
  [ValidateSet('brave','whale','vivaldi','opera','firefox')]
  [string]$PretendNew = 'brave'
)

$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$statePath = Join-Path $outDir 'known_browsers_v1.json'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$catalog = @{
  chrome = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
  )
  edge = @(
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
  )
  firefox = @(
    (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe')
  )
  brave = @(
    (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
    (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
  )
  whale = @(
    (Join-Path $env:ProgramFiles 'Naver\Naver Whale\Application\whale.exe'),
    (Join-Path $env:LOCALAPPDATA 'Naver\Naver Whale\Application\whale.exe')
  )
  vivaldi = @(
    (Join-Path $env:ProgramFiles 'Vivaldi\Application\vivaldi.exe'),
    (Join-Path $env:LOCALAPPDATA 'Vivaldi\Application\vivaldi.exe')
  )
  opera = @(
    (Join-Path $env:ProgramFiles 'Opera\opera.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Opera\opera.exe')
  )
}

$installed = @()
foreach ($pair in $catalog.GetEnumerator()) {
  foreach ($p in $pair.Value) {
    if (Test-Path -LiteralPath $p) {
      $installed += $pair.Key
      break
    }
  }
}
$installed = $installed | Select-Object -Unique

if (Test-Path -LiteralPath $statePath) {
  $j = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  $known = @($j.knownIds)
} else {
  $known = @($installed)
}

if ($PretendNew -and ($installed -contains $PretendNew)) {
  $known = @($known | Where-Object { $_ -ne $PretendNew })
  @{ seeded = $true; updatedAt = (Get-Date).ToString('o'); knownIds = $known } |
    ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
  Write-Host "Pretend-new: removed '$PretendNew' from known list (app watcher will re-apply on next tick)" -ForegroundColor Yellow
}

Write-Host "Installed on disk: $($installed -join ', ')"
Write-Host "Known in state:    $($known -join ', ')"
$novel = @($installed | Where-Object { $_ -notin $known })
Write-Host "Would trigger apply: $($novel -join ', ')" -ForegroundColor Cyan
Write-Host "State file: $statePath"
exit 0
