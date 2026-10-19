param()

$ErrorActionPreference = 'Stop'

$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\chrome.exe'
$oldDebugger = $null
if (Test-Path -LiteralPath $ifeo) {
  $oldDebugger = (Get-ItemProperty -LiteralPath $ifeo -Name Debugger -ErrorAction SilentlyContinue).Debugger
  Remove-ItemProperty -LiteralPath $ifeo -Name Debugger -ErrorAction SilentlyContinue
}

try {
  $cb = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\chrome_blocker'
  $chromeExe = Join-Path $env:PROGRAMFILES 'Google\Chrome\Application\chrome.exe'
  if (-not (Test-Path -LiteralPath $chromeExe)) {
    $chromeExe = Join-Path ${env:PROGRAMFILES(X86)} 'Google\Chrome\Application\chrome.exe'
  }
  if (-not (Test-Path -LiteralPath $chromeExe)) {
    $chromeExe = Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'
  }
  if (-not (Test-Path -LiteralPath $chromeExe)) {
    throw 'chrome.exe not found'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $cb 'manifest.json'))) {
    throw 'chrome_blocker manifest missing'
  }

  $packUd = Join-Path $env:TEMP ('sixvpn_pack_' + [guid]::NewGuid().ToString('N'))
  $crx = "$cb.crx"
  $pem = "$cb.pem"
  $args = @("--user-data-dir=$packUd", "--pack-extension=$cb")
  if (Test-Path -LiteralPath $pem) {
    $args += "--pack-extension-key=$pem"
  }
  $p = Start-Process -FilePath $chromeExe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
  Remove-Item -Recurse -Force -LiteralPath $packUd -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $crx)) {
    throw "CRX not produced, chrome exit=$($p.ExitCode)"
  }
  $sha = (Get-FileHash -LiteralPath $crx -Algorithm SHA256).Hash.ToLower()
  $ver = ((Get-Content -LiteralPath (Join-Path $cb 'manifest.json') -Raw) | ConvertFrom-Json).version
  $extId = 'popjkofklmidngceakpcokopghehjngo'
  $crxUrl = 'file:///' + ($crx -replace '\\', '/')
  $xml = "<?xml version='1.0' encoding='UTF-8'?><gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'><app appid='$extId'><updatecheck codebase='$crxUrl' version='$ver' hash_sha256='$sha' /></app></gupdate>"
  Set-Content -LiteralPath (Join-Path $cb 'updates.xml') -Value $xml -Encoding UTF8
  Write-Output "CRX_OK $([int]((Get-Item $crx).Length / 1024))KB sha256=$($sha.Substring(0, 12))"
} finally {
  if ($oldDebugger) {
    if (-not (Test-Path -LiteralPath $ifeo)) {
      New-Item -Path $ifeo -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $ifeo -Name Debugger -Value $oldDebugger -Type String -Force
    Write-Output 'CHROME_IFEO_RESTORED'
  }
}
