import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'silent_bootstrap_context.dart';
import 'windows_hidden_process.dart';

/// Explains an **involuntary restart of this app**.
///
/// When the user (or anything) force-kills Focus Fense — Task Manager End
/// Task, `taskkill`, a crash — the watchdog silently relaunches it within ≤1
/// min. Previously that respawn was completely silent, so the app just
/// "reappeared" with no explanation, which reads as malware. This service
/// detects that case on the next launch and shows the branded 6VPN toast:
/// "방금 강제 종료돼서 자동으로 다시 켰습니다 — 차단은 유지됩니다."
///
/// How detection works without a crash hook (a hard kill leaves no Dart error):
///   * While running, a **heartbeat** file is refreshed every 60 s.
///   * On a graceful quit (tray "종료"), a **clean-exit flag** is written.
///   * On launch: heartbeat recent  +  no clean-exit flag  =  it was killed.
///
/// False-positive guards: just-booted (OS restart / logon autostart), a fresh
/// dev rebuild relaunch, and the silent-bootstrap window are all suppressed.
final class AppForceRestartNoticeService {
  AppForceRestartNoticeService._();
  static final AppForceRestartNoticeService instance =
      AppForceRestartNoticeService._();

  // 60 s heartbeat: one tiny file write per tick, no child process. Must keep
  // ticking while hidden to tray (that is exactly when a kill happens), so —
  // unlike probe timers — it does NOT skip on AppLifecycleState != resumed.
  // Cost per tick: a single ~60-byte file write. Well under the perf budget.
  static const Duration _heartbeatEvery = Duration(seconds: 60);

  /// A previous heartbeat newer than this means "the app was alive moments
  /// ago" — consistent with a kill + watchdog respawn (≤1 min) plus slack.
  static const Duration _recentlyAlive = Duration(minutes: 5);

  /// Below this uptime we assume the OS just booted and the app autostarted —
  /// not an involuntary kill, so stay quiet.
  static const Duration _justBooted = Duration(minutes: 2);

  Timer? _timer;
  bool _started = false;

  String _dir() =>
      p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'SixVPNBlocker');
  String get _heartbeatPath => p.join(_dir(), 'app_heartbeat.json');
  String get _cleanExitPath => p.join(_dir(), 'app_clean_exit.flag');
  String get _rebuildLogPath => p.join(_dir(), 'rebuild_console.log');

  /// Milliseconds since OS boot via kernel32!GetTickCount64 (not exposed by the
  /// win32 package, so bound directly). Used only as a "did the OS just boot?"
  /// guard, so a failure falls back to a large value (don't suppress).
  static final int Function() _getTickCount64 = () {
    try {
      return DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Uint64 Function(), int Function()>('GetTickCount64');
    } catch (_) {
      return () => 1 << 40; // ~12 days — treat as long uptime
    }
  }();

  int _uptimeMs() {
    try {
      return _getTickCount64();
    } catch (_) {
      return 1 << 40;
    }
  }

  /// Run once at launch, BEFORE [start]. Decides whether the previous process
  /// death was an involuntary kill and, if so, shows the branded notice.
  Future<void> detectAndNotifyOnLaunch() async {
    if (!Platform.isWindows) return;
    try {
      final File hb = File(_heartbeatPath);
      final File flag = File(_cleanExitPath);
      final bool cleanExit = await flag.exists();

      DateTime? lastBeat;
      if (await hb.exists()) {
        try {
          final Map<String, dynamic> j =
              jsonDecode(await hb.readAsString()) as Map<String, dynamic>;
          final String? at = j['at'] as String?;
          if (at != null) lastBeat = DateTime.tryParse(at);
        } catch (_) {/* corrupt heartbeat → treat as none */}
      }

      final bool recentlyAlive = lastBeat != null &&
          DateTime.now().difference(lastBeat) <= _recentlyAlive;

      final bool killed = !cleanExit && recentlyAlive;

      // Consume the clean-exit flag regardless, so it can't mask a later kill.
      if (cleanExit) {
        try {
          await flag.delete();
        } catch (_) {}
      }

      if (killed && _shouldNotify()) {
        AppLogger.instance.info(
          'force_restart: involuntary kill detected (lastBeat=$lastBeat) — notifying',
        );
        await _showBrandedToast(
          title: 'Focus Fense가 다시 켜졌어요',
          body: '앱이 강제 종료되어 자동으로 복구했습니다. 차단은 계속 유지됩니다 — '
              '바이러스가 아니라 정상 보호 동작입니다.',
        );
      }
    } catch (e) {
      AppLogger.instance.warn('force_restart: detect failed: $e');
    } finally {
      // Always lay down a fresh heartbeat so the NEXT launch can reason about
      // this session even if start() somehow doesn't run.
      await _writeHeartbeat();
    }
  }

  /// Suppress the notice on OS boot, right after a dev rebuild relaunch, or
  /// during the silent bootstrap window.
  bool _shouldNotify() {
    if (SilentBootstrapContext.suppressUserPrompts) return false;
    if (_uptimeMs() < _justBooted.inMilliseconds) return false;
    try {
      final File log = File(_rebuildLogPath);
      if (log.existsSync()) {
        final Duration since = DateTime.now().difference(log.lastModifiedSync());
        if (since < const Duration(minutes: 3)) return false;
      }
    } catch (_) {}
    return true;
  }

  Future<void> _writeHeartbeat() async {
    try {
      await Directory(_dir()).create(recursive: true);
      await File(_heartbeatPath).writeAsString(
        jsonEncode(<String, Object>{
          'at': DateTime.now().toIso8601String(),
          'pid': pid,
        }),
        flush: true,
      );
    } catch (_) {/* best-effort */}
  }

  void start() {
    if (!Platform.isWindows || _started) return;
    _started = true;
    unawaited(_writeHeartbeat());
    _timer = Timer.periodic(_heartbeatEvery, (_) => unawaited(_writeHeartbeat()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  /// Mark a graceful shutdown so the next launch does NOT show the kill notice.
  /// Written **synchronously** because it runs during teardown / right before
  /// the process exits, when async IO may not finish.
  void markCleanExit() {
    if (!Platform.isWindows) return;
    try {
      final Directory dir = Directory(_dir());
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(_cleanExitPath)
          .writeAsStringSync(DateTime.now().toIso8601String(), flush: true);
    } catch (_) {/* best-effort */}
  }

  /// Branded, always-on-top 6VPN toast (same WinForms card as the close-notice
  /// and browser-guide). Frameless dark card, teal stripe, brand line, auto
  /// dismiss. Reads {title,body} from a JSON sidecar so Korean never needs
  /// shell escaping.
  Future<void> _showBrandedToast({
    required String title,
    required String body,
  }) async {
    if (!Platform.isWindows) return;
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String psExe = p.join(windir, 'System32', 'WindowsPowerShell',
          'v1.0', 'powershell.exe');
      final String dir = _dir();
      await Directory(dir).create(recursive: true);
      final String scriptPath = p.join(dir, 'ShowSixVpnToast.ps1');
      await File(scriptPath).writeAsString(_kToastScript, flush: true);
      final String payloadPath =
          p.join(dir, 'restart_${DateTime.now().microsecondsSinceEpoch}.json');
      await File(payloadPath).writeAsString(
        jsonEncode(<String, String>{'title': title, 'body': body}),
        flush: true,
      );
      await windowsRunHidden(psExe, <String>[
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptPath,
        '-Payload',
        payloadPath,
      ]);
    } catch (e) {
      AppLogger.instance.warn('force_restart: toast failed: $e');
    }
  }

  /// Same renderer as [AppBlockUserNoticeService] so the restart notice looks
  /// identical to every other 6VPN toast.
  static const String _kToastScript = r'''
param([string]$Payload)
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$title='Focus Fense'; $body=''
try {
  if ($Payload -and (Test-Path -LiteralPath $Payload)) {
    $j = Get-Content -LiteralPath $Payload -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.title) { $title = [string]$j.title }
    if ($j.body)  { $body  = [string]$j.body }
    Remove-Item -LiteralPath $Payload -Force -ErrorAction SilentlyContinue
  }
} catch {}
$accent=[System.Drawing.Color]::FromArgb(56,209,159)
$bg=[System.Drawing.Color]::FromArgb(26,27,32)
$sub=[System.Drawing.Color]::FromArgb(178,180,190)
$f=New-Object System.Windows.Forms.Form
$f.FormBorderStyle='None'; $f.StartPosition='Manual'; $f.TopMost=$true; $f.ShowInTaskbar=$false
$f.Width=400; $f.Height=132; $f.BackColor=$bg
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
$lt.AutoSize=$false; $lt.Left=22; $lt.Top=36; $lt.Width=360; $lt.Height=24
$lb=New-Object System.Windows.Forms.Label
$lb.Text=$body; $lb.ForeColor=$sub; $lb.BackColor=$bg
$lb.Font=New-Object System.Drawing.Font('Segoe UI',9.5)
$lb.AutoSize=$false; $lb.Left=22; $lb.Top=63; $lb.Width=362; $lb.Height=58
$f.Controls.Add($brand); $f.Controls.Add($lt); $f.Controls.Add($lb)
$close={ try { $f.Close() } catch {} }
$f.Add_Click($close); $brand.Add_Click($close); $lt.Add_Click($close); $lb.Add_Click($close)
$t=New-Object System.Windows.Forms.Timer; $t.Interval=9000; $t.Add_Tick({ $f.Close() }); $t.Start()
$f.Opacity=0
$fi=New-Object System.Windows.Forms.Timer; $fi.Interval=16; $fi.Add_Tick({ if($f.Opacity -lt 0.96){ $f.Opacity=$f.Opacity+0.08 } else { $fi.Stop() } }); $fi.Start()
[System.Media.SystemSounds]::Asterisk.Play()
$f.Add_Shown({ $f.Activate(); $f.BringToFront() })
[System.Windows.Forms.Application]::Run($f)
''';
}
