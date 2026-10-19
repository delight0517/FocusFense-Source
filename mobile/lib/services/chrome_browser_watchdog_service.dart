import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'autostart_result.dart';
import 'chrome_load_extension_launcher.dart';
import 'easy_setup_bulletproof_prefs.dart';
import 'windows_protection_mode_prefs.dart';
import 'windows_hidden_process.dart';

/// Keeps Chrome/Edge/Firefox shortcuts pointed at silent launchers (no kill-flash loop).
final class ChromeBrowserWatchdogService {
  ChromeBrowserWatchdogService._();
  static final ChromeBrowserWatchdogService instance =
      ChromeBrowserWatchdogService._();

  static const String kTaskName = 'SixVPNBrowserGuard';
  static const int kIntervalMinutes = 5;

  static String get _markerDir => ChromeLoadExtensionLauncher.sixVpnDir;

  static String get _scriptFile => p.join(_markerDir, 'browser_guard.ps1');

  static String get _vbsLauncherFile =>
      p.join(_markerDir, 'browser_guard_launch.vbs');

  static String _schtasksExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'schtasks.exe');
  }

  static String _wscriptExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'wscript.exe');
  }

  Future<bool> isInstalled() async {
    if (!Platform.isWindows) return false;
    try {
      final ProcessResult r = await windowsRunHidden(_schtasksExe(), <String>[
        '/Query',
        '/TN',
        kTaskName,
        '/FO',
        'LIST',
      ]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeScript({required bool shortcutsOnly}) async {
    final Directory dir = Directory(_markerDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final String realtimeScript = p
        .join(_markerDir, 'browser_realtime_guard.ps1')
        .replaceAll('\\', '\\\\');

    final String ps = r'''
$ErrorActionPreference = 'SilentlyContinue'
$rt = 'REALTIME_PS1'
if (Test-Path -LiteralPath $rt) {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $rt | Out-Null
}
''';

    final String body = ps.replaceAll('REALTIME_PS1', realtimeScript);
    await File(_scriptFile).writeAsString(body, flush: true);

    final String psForVbs = _scriptFile.replaceAll('"', '""');
    final String vbs =
        'CreateObject("Wscript.Shell").Run '
        '"powershell.exe -NoProfile -ExecutionPolicy Bypass -NoLogo -NonInteractive '
        '-WindowStyle Hidden -File ""$psForVbs""", 0, False';
    await File(_vbsLauncherFile).writeAsString(vbs, flush: true);
  }

  Future<AutostartResult> install() async {
    if (!Platform.isWindows) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return const AutostartResult(
        ok: true,
        message: '수동 보호 꺼짐 상태라 브라우저 감시 작업 등록을 건너뜁니다.',
      );
    }
    final bool hijack = await EasySetupBulletproofPrefs.instance
        .hijackShortcuts();
    await _writeScript(shortcutsOnly: hijack);

    final String tr = '${_wscriptExe()} //B //Nologo "$_vbsLauncherFile"';
    final ProcessResult create =
        await windowsRunHidden(_schtasksExe(), <String>[
          '/Create',
          '/F',
          '/TN',
          kTaskName,
          '/SC',
          'MINUTE',
          '/MO',
          '$kIntervalMinutes',
          '/RL',
          'LIMITED',
          '/TR',
          tr,
        ]);
    if (create.exitCode != 0) {
      final String err = '${create.stderr}'.trim();
      return AutostartResult(
        ok: false,
        message: err.isEmpty ? '브라우저 감시 작업 등록 실패 (${create.exitCode})' : err,
      );
    }
    AppLogger.instance.info(
      'browser_guard: task installed shortcutsOnly=$hijack',
    );
    return AutostartResult(
      ok: true,
      message: hijack
          ? '브라우저 바로가기 유지: ${kIntervalMinutes}분마다 Chrome·Edge·Firefox 보호 실행기로 재연결'
          : '브라우저 감시: 보호 없이 켜진 Chrome/Edge 정리 (강화 모드)',
    );
  }

  Future<AutostartResult> uninstall() async {
    if (!Platform.isWindows) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    try {
      final ProcessResult del = await windowsRunHidden(_schtasksExe(), <String>[
        '/Delete',
        '/F',
        '/TN',
        kTaskName,
      ]);
      if (del.exitCode != 0) {
        return AutostartResult(
          ok: false,
          message: '${del.stderr}'.trim().isEmpty
              ? '작업 삭제 실패'
              : '${del.stderr}'.trim(),
        );
      }
    } catch (e) {
      return AutostartResult(ok: false, message: e.toString());
    }
    return const AutostartResult(ok: true, message: '브라우저 감시 해제됨');
  }

  Future<void> syncIfEnabled() async {
    if (!Platform.isWindows) return;
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
    if (!await EasySetupBulletproofPrefs.instance.browserWatchdog()) return;
    if (!await isInstalled()) return;
    final bool hijack = await EasySetupBulletproofPrefs.instance
        .hijackShortcuts();
    await _writeScript(shortcutsOnly: hijack);
  }
}
