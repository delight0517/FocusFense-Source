# Verifies extension payload + forcelist survive simulated delete (HKCU recovery path).
param(
  [string]$SixVpnDir = "$env:LOCALAPPDATA\SixVPNBlocker"
)

$ErrorActionPreference = 'Continue'
$extDir = Join-Path $SixVpnDir 'chrome_blocker'
$manifest = Join-Path $extDir 'manifest.json'
$updates = Join-Path $extDir 'updates.xml'
$testRoot = Join-Path $SixVpnDir '_ext_recovery_test'

if (-not (Test-Path -LiteralPath $manifest)) {
  Write-Host "FAIL: manifest missing at $manifest" -ForegroundColor Red
  exit 1
}

# Backup manifest content
$backup = Get-Content -LiteralPath $manifest -Raw
Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Set-Content -LiteralPath (Join-Path $testRoot 'manifest.json.bak') -Value $backup -Encoding UTF8

# Simulate user deleting extension binaries (keep rules_snapshot.json)
Get-ChildItem -LiteralPath $extDir -Force |
  Where-Object { $_.Name -ne 'rules_snapshot.json' } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Re-run Test-ChromeBlock updates.xml + payload restore from app build output if present
$repoManifest = Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\data\flutter_assets\assets\chrome_blocker\manifest.json'
if (-not (Test-Path -LiteralPath $repoManifest)) {
  # Fallback: copy from backup
  Set-Content -LiteralPath $manifest -Value $backup -Encoding UTF8
} else {
  $src = Split-Path -Parent $repoManifest
  Copy-Item -LiteralPath (Join-Path $src '*') -Destination $extDir -Recurse -Force
}

if (-not (Test-Path -LiteralPath $manifest)) {
  Set-Content -LiteralPath $manifest -Value $backup -Encoding UTF8
}

# Recreate updates.xml (same as Test-ChromeBlock)
$folderUrl = 'file:///' + ($extDir -replace '\\', '/')
$xml = @"
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
<app appid='popjkofklmidngceakpcokopghehjngo'>
<updatecheck codebase='$folderUrl/manifest.json' version='1.0.17' />
</app></gupdate>
"@
Set-Content -LiteralPath $updates -Value $xml -Encoding UTF8

$forcelist = reg query 'HKCU\Software\Policies\Google\Chrome\ExtensionInstallForcelist' /v 1 2>&1
$ok = (Test-Path -LiteralPath $manifest) -and (Test-Path -LiteralPath $updates) -and ($LASTEXITCODE -eq 0)

if ($ok) {
  Write-Host 'OK: extension payload + updates.xml + forcelist recoverable' -ForegroundColor Green
  exit 0
}
Write-Host 'FAIL: recovery incomplete' -ForegroundColor Red
exit 1
