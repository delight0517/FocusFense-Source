import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_hidden_process.dart';
import 'windows_offline_block_guard_service.dart';

/// Models + runner for startup-failure and bypass-hole live tests.
final class StartupBypassCase {
  const StartupBypassCase({
    required this.id,
    required this.title,
    required this.mitigated,
    required this.detail,
    required this.fix,
  });

  final String id;
  final String title;
  final bool mitigated;
  final String detail;
  final String fix;

  factory StartupBypassCase.fromJson(Map<String, dynamic> j) {
    return StartupBypassCase(
      id: j['id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      mitigated: j['mitigated'] as bool? ?? false,
      detail: j['detail'] as String? ?? '',
      fix: j['fix'] as String? ?? '',
    );
  }
}

final class StartupBypassTestReport {
  const StartupBypassTestReport({
    required this.passCount,
    required this.totalCount,
    required this.startupScenarios,
    required this.bypassHoles,
    required this.appRunning,
    this.youtubeSinkholed,
    this.youtubeIp,
  });

  final int passCount;
  final int totalCount;
  final List<StartupBypassCase> startupScenarios;
  final List<StartupBypassCase> bypassHoles;
  final bool appRunning;
  final bool? youtubeSinkholed;
  final String? youtubeIp;

  bool get allPass => passCount >= totalCount;

  factory StartupBypassTestReport.fromJson(Map<String, dynamic> j) {
    List<StartupBypassCase> parseList(Object? raw) {
      if (raw is! List<Object?>) return <StartupBypassCase>[];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(StartupBypassCase.fromJson)
          .toList();
    }

    final Map<String, dynamic>? yt =
        j['youtubeDns'] as Map<String, dynamic>?;
    return StartupBypassTestReport(
      passCount: j['passCount'] as int? ?? 0,
      totalCount: j['totalCount'] as int? ?? 9,
      startupScenarios: parseList(j['startupScenarios']),
      bypassHoles: parseList(j['bypassHoles']),
      appRunning: j['appRunning'] as bool? ?? false,
      youtubeSinkholed: yt?['sinkholed'] as bool?,
      youtubeIp: yt?['ip'] as String?,
    );
  }
}

final class StartupBypassResilienceService {
  StartupBypassResilienceService._();
  static final StartupBypassResilienceService instance =
      StartupBypassResilienceService._();

  String _localDir() {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker');
  }

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

  Future<String?> _testScriptPath() async {
    final String? mobileRoot =
        await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
    if (mobileRoot == null) return null;
    final String script =
        p.join(mobileRoot, 'tools', 'Test-Startup-And-Bypass.ps1');
    if (!await File(script).exists()) return null;
    return script;
  }

  Future<StartupBypassTestReport?> loadLastReport() async {
    final File f = File(p.join(_localDir(), 'startup_bypass_test_last.json'));
    if (!await f.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return StartupBypassTestReport.fromJson(decoded);
    } catch (e) {
      AppLogger.instance.warn('startup_bypass: load failed $e');
      return null;
    }
  }

  /// Runs live probes; optionally runs offline maintain first.
  Future<StartupBypassTestReport?> runLiveTest({
    bool runOfflineMaintain = true,
  }) async {
    if (!Platform.isWindows) return null;
    if (runOfflineMaintain) {
      await WindowsOfflineBlockGuardService.instance.runNow();
    }
    final String? script = await _testScriptPath();
    if (script == null) return null;

    final List<String> args = <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script,
    ];
    if (runOfflineMaintain) args.add('-RunOfflineMaintain');

    final ProcessResult r = await windowsRunHidden(_powershellExe(), args);
    AppLogger.instance.info(
      'startup_bypass: test exit=${r.exitCode} stdout=${r.stdout}',
    );
    return loadLastReport();
  }
}
