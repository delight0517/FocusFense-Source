# Validates owner override token without printing format hints or expected value.
# Usage: Verify-AgentDestruct-Override.ps1 -Candidate '<paste from app>'
# Exit: 0 = valid · 1 = mismatch · 2 = gate off / probe missing
param(
  [Parameter(Mandatory)]
  [string] $Candidate,
  [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$outDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
$probe = Join-Path $outDir 'agent_destruct_gate_probe.json'
$tokenFile = Join-Path $outDir 'agent_destruct_gate_token.local'

if (-not (Test-Path -LiteralPath $probe)) {
  if (-not $Quiet) { Write-Host 'OVERRIDE_INVALID gate_probe_missing' }
  exit 2
}

$meta = $null
try {
  $meta = Get-Content -LiteralPath $probe -Raw | ConvertFrom-Json
} catch {
  if (-not $Quiet) { Write-Host 'OVERRIDE_INVALID probe_parse_error' }
  exit 2
}

if (-not $meta.enabled) {
  if (-not $Quiet) { Write-Host 'OVERRIDE_INVALID gate_disabled' }
  exit 2
}

if (-not (Test-Path -LiteralPath $tokenFile)) {
  if (-not $Quiet) { Write-Host 'OVERRIDE_INVALID token_file_missing' }
  exit 2
}

$expected = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
$cand = $Candidate.Trim()

if ([string]::IsNullOrWhiteSpace($cand) -or [string]::IsNullOrWhiteSpace($expected)) {
  if (-not $Quiet) { Write-Host 'OVERRIDE_INVALID empty' }
  exit 1
}

# Constant-time-ish compare (length + char) — do not echo expected token.
if ($cand.Length -ne $expected.Length) {
  if (-not $Quiet) { Write-Host 'OVERRIDE_INVALID mismatch' }
  exit 1
}

$diff = 0
for ($i = 0; $i -lt $cand.Length; $i++) {
  $diff = $diff -bor ([byte][char]$cand[$i] -bxor [byte][char]$expected[$i])
}
if ($diff -ne 0) {
  if (-not $Quiet) { Write-Host 'OVERRIDE_INVALID mismatch' }
  exit 1
}

if (-not $Quiet) { Write-Host 'OVERRIDE_OK' }
exit 0
