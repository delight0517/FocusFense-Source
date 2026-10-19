import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// Keeps the **IFEO browser-launch toast** working and branded.
///
/// Unprotected browsers (Edge, Whale, Opera, Vivaldi) are blocked at the OS
/// level via an Image-File-Execution-Options `Debugger` hook on their exe that
/// points at `C:\ProgramData\SixVPNBlocker\ShowBlockedBrowserToast.ps1`. When
/// the user launches one, Windows runs that script *instead of* the browser.
///
/// The old script used the native WinRT toast API — which is silently
/// suppressed on this box (same finding that birthed the WinForms card in
/// [AppBlockUserNoticeService]) — and its Korean text was mojibake. Net effect:
/// the browser just never opened and **nothing** explained why, which reads as
/// the app being broken / a virus.
///
/// This service ships the corrected script (frameless branded WinForms card,
/// correct Korean, derives the browser name from the IFEO arg) and:
///   * writes it to a user-writable **staging** path every launch, and
///   * exposes [elevatedDeployFragment] so the elevated apply copies staging →
///     ProgramData (that file is admin-owned, so the app can't overwrite it
///     directly).
///
/// **Phase 6 (2026-07):** the same launcher/toast is now also the landing
/// point for *schedule-driven* exes (any app, not just these 4 browsers) —
/// see `WindowsAppBlockService._syncIfeoSidecar` and
/// `Elevated-Maintain-Block.ps1`. The toast script reads a sidecar JSON to
/// show the right name/reason for those; this fixed 4-browser feature is
/// unrelated and unaffected (never goes through the sidecar).
final class BlockedBrowserLaunchNoticeService {
  BlockedBrowserLaunchNoticeService._();
  static final BlockedBrowserLaunchNoticeService instance =
      BlockedBrowserLaunchNoticeService._();

  static const String programDataScript =
      r'C:\ProgramData\SixVPNBlocker\ShowBlockedBrowserToast.ps1';
  static const String programDataVbs =
      r'C:\ProgramData\SixVPNBlocker\BlockedBrowserToastLauncher.vbs';

  static String stagingScriptPath() => p.join(
    Platform.environment['LOCALAPPDATA'] ?? '',
    'SixVPNBlocker',
    'ShowBlockedBrowserToast.ps1',
  );

  static String stagingVbsPath() => p.join(
    Platform.environment['LOCALAPPDATA'] ?? '',
    'SixVPNBlocker',
    'BlockedBrowserToastLauncher.vbs',
  );

  /// Write the corrected script to the user-writable staging path. PowerShell
  /// 5.1 decodes a BOM-less `.ps1` as ANSI and mangles Korean (the original
  /// bug), so we prepend a UTF-8 BOM.
  Future<void> deployStagingScript() async {
    if (!Platform.isWindows) return;
    try {
      final String stage = stagingScriptPath();
      await Directory(p.dirname(stage)).create(recursive: true);
      final List<int> bom = <int>[0xEF, 0xBB, 0xBF];
      await File(
        stage,
      ).writeAsBytes(<int>[...bom, ...utf8.encode(_kScript)], flush: true);
      // VBS launcher is pure ASCII — write as-is (wscript reads ANSI).
      await File(stagingVbsPath()).writeAsString(_kVbsLauncher, flush: true);
    } catch (e) {
      AppLogger.instance.warn('blocked_browser_toast: stage write failed: $e');
    }
  }

  /// PS fragment for the elevated apply script. Two jobs:
  ///   1. Copy the branded toast script + VBS launcher staging → ProgramData.
  ///   2. Repoint every IFEO `Debugger` that already references our toast from
  ///      a bare `powershell.exe -WindowStyle Hidden …` (which still flashes a
  ///      conhost window before it hides) to `wscript //B … .vbs`, which runs
  ///      the PowerShell with `WshShell.Run(…, 0)` — truly windowless, no flash.
  /// Only touches IFEO keys we already own (Debugger references our script), so
  /// it never creates a NEW browser block.
  static String elevatedDeployFragment() {
    final String stage = stagingScriptPath().replaceAll("'", "''");
    final String stageVbs = stagingVbsPath().replaceAll("'", "''");
    return '''
  # --- 6 VPN Blocker: refresh IFEO blocked-browser toast + kill console flash ---
  try {
    \$srcPs  = '$stage'
    \$srcVbs = '$stageVbs'
    \$dstDir = 'C:\\ProgramData\\SixVPNBlocker'
    if (-not (Test-Path -LiteralPath \$dstDir)) { New-Item -ItemType Directory -Force -Path \$dstDir | Out-Null }
    if (Test-Path -LiteralPath \$srcPs)  { Copy-Item -LiteralPath \$srcPs  -Destination (Join-Path \$dstDir 'ShowBlockedBrowserToast.ps1') -Force }
    if (Test-Path -LiteralPath \$srcVbs) { Copy-Item -LiteralPath \$srcVbs -Destination (Join-Path \$dstDir 'BlockedBrowserToastLauncher.vbs') -Force }
    \$newDbg = 'C:\\Windows\\System32\\wscript.exe //B //Nologo "C:\\ProgramData\\SixVPNBlocker\\BlockedBrowserToastLauncher.vbs"'
    \$ifeoRoot = 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options'
    Get-ChildItem \$ifeoRoot -ErrorAction SilentlyContinue | ForEach-Object {
      \$dbg = (Get-ItemProperty -Path \$_.PSPath -Name Debugger -ErrorAction SilentlyContinue).Debugger
      if (\$dbg -and (\$dbg -match 'ShowBlockedBrowserToast') -and (\$dbg -notmatch 'BlockedBrowserToastLauncher')) {
        Set-ItemProperty -Path \$_.PSPath -Name Debugger -Value \$newDbg
      }
    }
  } catch {}
''';
  }

  /// The corrected IFEO toast. Frameless branded WinForms card (same renderer
  /// as every other 6VPN toast — proven to show on this box). `$args[0]` is the
  /// attempted browser exe path that Windows hands the IFEO debugger.
  static const String _kScript = r'''
# 6 VPN Blocker - branded toast shown when an IFEO-blocked browser is launched.
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$attempted = if ($args.Count -gt 0) { [string]$args[0] } else { 'unknown' }
$exeName = Split-Path $attempted -Leaf
# Phase 6 (L5): schedule-driven exes are registered dynamically, so their
# display name/reason come from the sidecar WindowsAppBlockService writes
# (unprivileged, %LOCALAPPDATA%) rather than a fixed switch statement. Falls
# back to the static browser map below when the exe isn't in the sidecar
# (the always-blocked Edge/Whale/Opera/Vivaldi 4 never go through it).
$dynamicDisplay = $null
$dynamicReason = $null
try {
  $sidecar = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\process_layer_active_exes.json'
  if (Test-Path -LiteralPath $sidecar) {
    $parsed = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json
    $entry = $parsed.activeExes.($exeName.ToLower())
    if ($entry) {
      $dynamicDisplay = "$($entry.displayName)"
      $dynamicReason = "$($entry.reason)"
    }
  }
} catch {}
$display = if ($dynamicDisplay) { $dynamicDisplay } else {
  switch -wildcard ($exeName.ToLower()) {
    'chrome.exe'  { 'Google Chrome' }
    'msedge.exe'  { 'Microsoft Edge' }
    'opera.exe'   { 'Opera' }
    'opera_gx*'   { 'Opera GX' }
    'whale.exe'   { 'Naver Whale' }
    'vivaldi.exe' { 'Vivaldi' }
    default       { $exeName }
  }
}
try {
  Add-Content -Path 'C:\ProgramData\SixVPNBlocker\browser_launch_attempts.log' -Value ('[' + (Get-Date -Format 'o') + '] BLOCKED ' + $display + ' (' + $attempted + ')') -Encoding UTF8
} catch {}
$title = $display + ' 실행 차단됨'
$body = if ($dynamicReason) {
  "Focus Fense가 지금 이 앱 실행을 막고 있습니다 ($dynamicReason). 바이러스가 아니라 정상 보호 동작입니다."
} else {
  'Focus Fense가 이 브라우저 실행을 막았습니다. Chrome · Firefox · Brave를 사용해 주세요 — 바이러스가 아니라 정상 보호 동작입니다.'
}
$accent=[System.Drawing.Color]::FromArgb(56,209,159)
$bg=[System.Drawing.Color]::FromArgb(26,27,32)
$sub=[System.Drawing.Color]::FromArgb(178,180,190)
$f=New-Object System.Windows.Forms.Form
$f.FormBorderStyle='None'; $f.StartPosition='Manual'; $f.TopMost=$true; $f.ShowInTaskbar=$false
$f.Width=420; $f.Height=140; $f.BackColor=$bg
$wa=[System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
$f.Left=$wa.Right-$f.Width-20; $f.Top=$wa.Bottom-$f.Height-20
$r=14
$gp=New-Object System.Drawing.Drawing2D.GraphicsPath
$gp.AddArc(0,0,$r,$r,180,90)
$gp.AddArc($f.Width-$r-1,0,$r,$r,270,90)
$gp.AddArc($f.Width-$r-1,$f.Height-$r-1,$r,$r,0,90)
$gp.AddArc(0,$f.Height-$r-1,$r,$r,90,90)
$gp.CloseAllFigures()
$f.Region=New-Object System.Drawing.Region($gp)
$f.Add_Paint({ param($s,$e) $e.Graphics.SmoothingMode='AntiAlias'; $e.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush($accent)),0,0,5,$f.Height) })
$brand=New-Object System.Windows.Forms.Label
$brand.Text=[char]9679 + ' FOCUS FENSE'; $brand.ForeColor=$accent; $brand.BackColor=$bg
$brand.Font=New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Bold)
$brand.AutoSize=$true; $brand.Left=22; $brand.Top=14
$lt=New-Object System.Windows.Forms.Label
$lt.Text=$title; $lt.ForeColor=[System.Drawing.Color]::White; $lt.BackColor=$bg
$lt.Font=New-Object System.Drawing.Font('Segoe UI Semibold',12,[System.Drawing.FontStyle]::Bold)
$lt.AutoSize=$false; $lt.Left=22; $lt.Top=36; $lt.Width=380; $lt.Height=24
$lb=New-Object System.Windows.Forms.Label
$lb.Text=$body; $lb.ForeColor=$sub; $lb.BackColor=$bg
$lb.Font=New-Object System.Drawing.Font('Segoe UI',9.5)
$lb.AutoSize=$false; $lb.Left=22; $lb.Top=63; $lb.Width=384; $lb.Height=66
$f.Controls.Add($brand); $f.Controls.Add($lt); $f.Controls.Add($lb)
$close={ try { $f.Close() } catch {} }
$f.Add_Click($close); $brand.Add_Click($close); $lt.Add_Click($close); $lb.Add_Click($close)
$t=New-Object System.Windows.Forms.Timer; $t.Interval=9000; $t.Add_Tick({ $f.Close() }); $t.Start()
# 2026-07-06 fix: same white-square flash root cause as AppBlockUserNoticeService's
# toast — Opacity<1 forces WS_EX_LAYERED rendering and the first composited frame
# (before BackColor/labels paint) shows as a blank white rounded square. Removed.
[System.Media.SystemSounds]::Asterisk.Play()
$f.Add_Shown({ $f.Activate(); $f.BringToFront() })
[System.Windows.Forms.Application]::Run($f)
exit 0
''';

  /// Windowless launcher the IFEO `Debugger` points at. `wscript //B` is itself
  /// console-less, and `WshShell.Run(cmd, 0, False)` starts PowerShell already
  /// hidden — so unlike `powershell.exe -WindowStyle Hidden` (which flashes a
  /// conhost window before hiding) there is NO black console flash. The blocked
  /// browser's exe path arrives as `WScript.Arguments(0)` and is forwarded to
  /// the toast script.
  static const String _kVbsLauncher = r'''
Dim sh, browserPath, cmd
Set sh = CreateObject("WScript.Shell")
browserPath = ""
If WScript.Arguments.Count > 0 Then browserPath = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\ProgramData\SixVPNBlocker\ShowBlockedBrowserToast.ps1"" """ & browserPath & """"
sh.Run cmd, 0, False
''';
}
