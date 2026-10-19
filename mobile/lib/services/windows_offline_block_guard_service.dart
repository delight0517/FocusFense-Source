import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'autostart_result.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_hidden_process.dart';

/// Registers a **no-UAC** scheduled task that repairs HKCU policies every 10 min
/// while the main app is closed (URLBlocklist, PAC, forcelist, DoH off).
final class WindowsOfflineBlockGuardService {
  WindowsOfflineBlockGuardService._();
  static final WindowsOfflineBlockGuardService instance =
      WindowsOfflineBlockGuardService._();

  static const String kTaskName = 'SixVPNBlockerOfflineGuard';
  static const int kIntervalMinutes = 10;
  static const int kLogonDelaySeconds = 120;

  bool get isSupported => Platform.isWindows;

  String _powershellExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  String _schtasksExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'schtasks.exe');
  }

  Future<String?> _maintainScriptPath() async {
    final String? mobileRoot =
        await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
    if (mobileRoot == null) return null;
    final String script =
        p.join(mobileRoot, 'tools', 'Offline-Block-Policy-Maintain.ps1');
    if (!await File(script).exists()) return null;
    return script;
  }

  /// Wraps the PowerShell action in `wscript.exe`, which has no console
  /// subsystem at all. Task Scheduler launching `powershell.exe` directly —
  /// even with `-WindowStyle Hidden` — briefly flashes a black console frame
  /// on every trigger; since this task repeats every 10 minutes all day,
  /// that flash was the recurring "console keeps popping up" the user saw.
  /// `WScript.Shell.Run(cmd, 0, False)` never allocates a console.
  Future<String?> _writeOfflineGuardVbs(String script) async {
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    if (la.isEmpty) return null;
    final String dir = p.join(la, 'SixVPNBlocker', 'tools');
    try {
      final Directory d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      String cmdQuote(String s) => '"${s.replaceAll('"', '\\"')}"';
      String vbQuote(String s) => '"${s.replaceAll('"', '""')}"';
      final String commandLine =
          '${cmdQuote(_powershellExe())} -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ${cmdQuote(script)} -Quiet';
      final String vbs = <String>[
        'Set objShell = CreateObject("WScript.Shell")',
        'objShell.Run ${vbQuote(commandLine)}, 0, False',
      ].join('\r\n');
      final File f = File(p.join(dir, 'offline_guard_launch.vbs'));
      await f.writeAsString(vbs, flush: true);
      return f.path;
    } catch (e) {
      AppLogger.instance.warn('offline_guard: vbs write failed', error: e);
      return null;
    }
  }

  Future<bool> isRegistered() async {
    if (!isSupported) return false;
    final ProcessResult r = await windowsRunHidden(
      _schtasksExe(),
      <String>['/Query', '/TN', kTaskName, '/FO', 'LIST'],
    );
    return r.exitCode == 0;
  }

  Future<AutostartResult> ensureRegistered() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    final String? script = await _maintainScriptPath();
    if (script == null) {
      return const AutostartResult(
        ok: false,
        message: 'Offline-Block-Policy-Maintain.ps1 not found',
      );
    }

    final String ps = _powershellExe();
    final String? vbsPath = await _writeOfflineGuardVbs(script);
    if (vbsPath == null) {
      return const AutostartResult(
        ok: false,
        message: 'offline guard vbs wrapper write failed',
      );
    }
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String wscript = p.join(windir, 'System32', 'wscript.exe');
    final String vbsLit = vbsPath.replaceAll("'", "''");
    final String wscriptLit = wscript.replaceAll("'", "''");

    final String registerScript = <String>[
      r"$ErrorActionPreference='Stop'",
      "\$vbsPath='$vbsLit'",
      r'$arg="//B //Nologo `"$vbsPath`""',
      "\$a=New-ScheduledTaskAction -Execute '$wscriptLit' -Argument \$arg",
      r'$t1=New-ScheduledTaskTrigger -Once -At (Get-Date)',
      r'$t1.Repetition=(New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition',
      r'$t2=New-ScheduledTaskTrigger -AtLogOn -User $env:USERDOMAIN\$env:USERNAME',
      "\$t2.Delay='PT${kLogonDelaySeconds}S'",
      r'$s=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew',
      r'$p=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited',
      "Register-ScheduledTask -TaskName '$kTaskName' -Action \$a -Trigger @(\$t1,\$t2) -Settings \$s -Principal \$p -Force | Out-Null",
    ].join(';');

    final ProcessResult r = await windowsRunHidden(
      ps,
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        registerScript,
      ],
    );
    if (r.exitCode != 0) {
      final String err = '${r.stderr}${r.stdout}'.trim();
      AppLogger.instance.warn('offline_guard: register failed $err');
      return AutostartResult(ok: false, message: err);
    }
    AppLogger.instance.info('offline_guard: task $kTaskName registered');
    return const AutostartResult(
      ok: true,
      message: '오프라인 HKCU 정책 가드 (10분 + 로그온 2분)',
    );
  }

  /// Run maintain script immediately (no UAC).
  Future<bool> runNow() async {
    if (!isSupported) return false;
    final String? script = await _maintainScriptPath();
    if (script == null) return false;
    final ProcessResult r = await windowsRunHidden(
      _powershellExe(),
      <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script,
        '-Quiet',
      ],
    );
    return r.exitCode == 0;
  }
}
