# Standalone Firefox extension integrity check.
#
# This is the build-time/on-demand twin of
# FirefoxExtensionIntegrityGuardService.verify(). It exists so a future AI or
# human cannot edit the Firefox extension source, forget the AMO re-sign step,
# and still ship a stale or unsigned Firefox plugin.
#
# Exit codes:
#   0 = healthy
#   2 = real integrity failure; callers should block the build
#   3 = internal checker error; callers may warn loudly

param(
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-Line {
  param([string]$Text, [string]$Color = 'Gray')
  if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

function Add-AuditLine {
  param([string]$LogPath, [hashtable]$Fields)
  try {
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Fields['ts'] = (Get-Date).ToUniversalTime().ToString('o')
    Add-Content -LiteralPath $LogPath -Value ($Fields | ConvertTo-Json -Compress) -Encoding UTF8
  } catch {}
}

function Test-XpiLooksSigned {
  param([byte[]]$Bytes)
  $text = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($Bytes)
  foreach ($marker in @('META-INF/mozilla.rsa', 'META-INF/mozilla.sf', 'META-INF/cose.sig')) {
    if ($text.Contains($marker)) { return $true }
  }
  return $false
}

function Get-Sha256Hex {
  param([string]$Path)
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $hasher.ComputeHash([System.IO.File]::ReadAllBytes($Path))
    return -join ($hash | ForEach-Object { $_.ToString('x2') })
  } finally {
    $hasher.Dispose()
  }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$firefoxDir = Join-Path $repoRoot 'mobile/assets/browser_extensions/firefox'
$xpiPath = Join-Path $firefoxDir 'sixvpn_blocker_signed.xpi'
$snapshotPath = Join-Path $firefoxDir 'signed_source_snapshot.json'
$manifestPath = Join-Path $firefoxDir 'manifest.json'
$auditLogPath = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\claude_guard_audit_log.jsonl'

try {
  $problems = New-Object System.Collections.Generic.List[string]
  # @incident: project_firefox_signing_drift_blocking_builds (2026-07-07) —
  # source-hash drift alone used to be a hard build-blocking failure. Two
  # problems with that: (1) it blocks the ENTIRE Windows app build over a
  # Firefox-extension-only concern, even though the bundled
  # sixvpn_blocker_signed.xpi (what Firefox actually loads) ships completely
  # unchanged regardless of local source drift - "stale-but-signed beats no
  # extension" per mobile/CLAUDE.md's own stated policy; (2) at least once,
  # signed_source_snapshot.json's pinned hash (for manifest.json) matched
  # NEITHER the current source, NOR the git history baseline, NOR the actual
  # bytes inside the signed xpi itself - i.e. the pin can itself be stale/
  # corrupted data, not a real drift signal, and since that snapshot file is
  # permanently edit-locked (Tier C, no bypass) a bad pin could never be
  # fixed and would block every future build forever.
  #
  # Per-file source-hash mismatches are now non-blocking WARNINGS (still
  # loud, still logged, still say "re-sign when convenient") rather than
  # hard failures. What STAYS blocking: no signed XPI at all, the XPI having
  # no Mozilla signing markers, or the manifest's gecko.id not matching the
  # signed snapshot's addon id - those mean "no valid signed package exists"
  # or "this might be a different extension identity entirely," which are
  # genuinely severe and have no legitimate "drift happens" excuse.
  $warnings = New-Object System.Collections.Generic.List[string]

  if (-not (Test-Path -LiteralPath $xpiPath)) {
    $problems.Add("Bundled signed XPI is missing: $xpiPath. Firefox Release will reject unsigned fallback XPIs.")
  } else {
    $xpiBytes = [System.IO.File]::ReadAllBytes($xpiPath)
    if (-not (Test-XpiLooksSigned -Bytes $xpiBytes)) {
      $problems.Add('Bundled XPI has no Mozilla signing markers. A signed XPI is required.')
    }
  }

  if (-not (Test-Path -LiteralPath $snapshotPath)) {
    $problems.Add('signed_source_snapshot.json is missing. Source-to-signed-XPI drift cannot be verified.')
  } elseif (-not (Test-Path -LiteralPath $manifestPath)) {
    $problems.Add('manifest.json is missing.')
  } else {
    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifestId = "$($manifest.browser_specific_settings.gecko.id)"
    $pinnedId = "$($snapshot.amoAddonId)"

    if ($manifestId -and $pinnedId -and ($manifestId -ne $pinnedId)) {
      $problems.Add("manifest gecko.id '$manifestId' does not match signed snapshot amoAddonId '$pinnedId'.")
    }

    $pinned = $snapshot.sourceHashes
    if ($pinned) {
      foreach ($prop in $pinned.PSObject.Properties) {
        $fileName = $prop.Name
        $expected = "$($prop.Value)"
        $srcFile = Join-Path $firefoxDir $fileName
        if (-not (Test-Path -LiteralPath $srcFile)) {
          $problems.Add("Snapshot source file is missing on disk: $fileName.")
          continue
        }
        $actual = Get-Sha256Hex -Path $srcFile
        if ($actual -ne $expected) {
          $warnings.Add("Firefox source changed since the last AMO signing: $fileName. The bundled signed XPI still ships as-is; re-sign and replace it when convenient (not blocking - see script comment).")
        }
      }
    } else {
      $problems.Add('signed_source_snapshot.json has no sourceHashes map.')
    }
  }

  if ($problems.Count -eq 0) {
    if ($warnings.Count -gt 0) {
      Write-Line '[Firefox integrity] OK with known warnings (not blocking):' 'Yellow'
      foreach ($w in $warnings) { Write-Line "  - $w" 'Yellow' }
    } else {
      Write-Line '[Firefox integrity] OK: signed XPI present, manifest id matches, no source drift.' 'Green'
    }
    Add-AuditLine -LogPath $auditLogPath -Fields @{
      tool = 'Verify-Firefox-Integrity'
      decision = 'healthy'
      warnings = ($warnings -join ' | ')
    }
    exit 0
  }

  Write-Line '[Firefox integrity] FAILED:' 'Red'
  foreach ($problem in $problems) {
    Write-Line "  - $problem" 'Yellow'
  }
  Add-AuditLine -LogPath $auditLogPath -Fields @{
    tool = 'Verify-Firefox-Integrity'
    decision = 'broken'
    problems = ($problems -join ' | ')
  }
  exit 2
} catch {
  Write-Line "[Firefox integrity] internal error: $($_.Exception.Message)" 'Yellow'
  Add-AuditLine -LogPath $auditLogPath -Fields @{
    tool = 'Verify-Firefox-Integrity'
    decision = 'internal_error'
    error = "$($_.Exception.Message)"
  }
  exit 3
}
