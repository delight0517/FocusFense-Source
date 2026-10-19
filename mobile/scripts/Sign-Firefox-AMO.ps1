param(
  [string] $JwtIssuer = $env:AMO_JWT_ISSUER,
  [string] $JwtSecret = $env:AMO_JWT_SECRET,
  [string] $MobileRoot = "",
  [switch] $SkipNpmInstall
)

$ErrorActionPreference = "Stop"

if (-not $MobileRoot) {
  $MobileRoot = Split-Path -Parent $PSScriptRoot
}

$sourceDir = Join-Path $MobileRoot "assets\browser_extensions\firefox"
$signedOut = Join-Path $sourceDir "sixvpn_blocker_signed.xpi"
$artifacts = Join-Path $MobileRoot "build\firefox_amo_signed"

if ([string]::IsNullOrWhiteSpace($JwtIssuer)) {
  throw "AMO_JWT_ISSUER is missing. Pass -JwtIssuer or set the environment variable."
}
if ([string]::IsNullOrWhiteSpace($JwtSecret)) {
  throw "AMO_JWT_SECRET is missing. Pass -JwtSecret or set the environment variable."
}
if (-not (Test-Path -LiteralPath (Join-Path $sourceDir "manifest.json"))) {
  throw "Firefox extension source missing: $sourceDir"
}

$npx = Get-Command npx -ErrorAction SilentlyContinue
$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $npx -and -not $pnpm) {
  throw "npx/pnpm was not found. Install Node.js first, then rerun this script."
}

if (Test-Path -LiteralPath $artifacts) {
  Remove-Item -LiteralPath $artifacts -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null

$args = @(
  "web-ext",
  "sign",
  "--channel=unlisted",
  "--source-dir", $sourceDir,
  "--artifacts-dir", $artifacts,
  "--api-key", $JwtIssuer,
  "--api-secret", $JwtSecret
)

if ($npx -and -not $SkipNpmInstall) {
  $args = @("--yes") + $args
}

Write-Host "Signing Firefox extension through AMO (unlisted)..." -ForegroundColor Cyan
if ($npx) {
  & $npx.Source @args
} else {
  & $pnpm.Source dlx @args
}
if ($LASTEXITCODE -ne 0) {
  throw "web-ext sign failed with exit code $LASTEXITCODE"
}

$xpi = Get-ChildItem -LiteralPath $artifacts -Filter "*.xpi" -File |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $xpi) {
  throw "AMO signing finished, but no signed .xpi was produced in $artifacts"
}

Copy-Item -LiteralPath $xpi.FullName -Destination $signedOut -Force
Write-Host "Signed XPI bundled -> $signedOut" -ForegroundColor Green
