import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'cursor_agent_fix_log_service.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_hidden_process.dart';
import 'windows_offline_block_guard_service.dart';

/// Boot + periodic check for 5 Cursor-AI sabotage scenarios (S1–S5).
final class AgentTamperCase {
  const AgentTamperCase({
    required this.id,
    required this.title,
    required this.mitigated,
    required this.detail,
    required this.fix,
    this.defense = '',
  });

  final String id;
  final String title;
  final bool mitigated;
  final String detail;
  final String fix;
  final String defense;

  factory AgentTamperCase.fromJson(Map<String, dynamic> j) {
    return AgentTamperCase(
      id: j['id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      mitigated: j['mitigated'] as bool? ?? false,
      detail: j['detail'] as String? ?? '',
      fix: j['fix'] as String? ?? '',
      defense: j['defense'] as String? ?? '',
    );
  }
}

final class AgentTamperReport {
  const AgentTamperReport({
    required this.passCount,
    required this.totalCount,
    required this.scenarios,
    this.healed = false,
  });

  final int passCount;
  final int totalCount;
  final List<AgentTamperCase> scenarios;
  final bool healed;

  bool get allPass => passCount >= totalCount;

  factory AgentTamperReport.fromJson(Map<String, dynamic> j) {
    final List<AgentTamperCase> cases = <AgentTamperCase>[];
    final Object? raw = j['scenarios'];
    if (raw is List<Object?>) {
      for (final Object? item in raw) {
        if (item is Map<String, dynamic>) {
          cases.add(AgentTamperCase.fromJson(item));
        }
      }
    }
    return AgentTamperReport(
      passCount: j['passCount'] as int? ?? 0,
      totalCount: j['totalCount'] as int? ?? 6,
      scenarios: cases,
      healed: j['healed'] as bool? ?? false,
    );
  }
}

final class AgentTamperWatchdogService {
  AgentTamperWatchdogService._();
  static final AgentTamperWatchdogService instance =
      AgentTamperWatchdogService._();

  static const Duration kInterval = Duration(hours: 6);
  Timer? _timer;
  bool _running = false;

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

  Future<String?> _scriptPath(String name) async {
    final String? mobileRoot =
        await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
    if (mobileRoot == null) return null;
    final String script = p.join(mobileRoot, 'tools', name);
    if (!await File(script).exists()) return null;
    return script;
  }

  Future<AgentTamperReport?> loadLastReport() async {
    final File f = File(p.join(_localDir(), 'agent_tamper_verify_last.json'));
    if (!await f.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return AgentTamperReport.fromJson(decoded);
    } catch (e) {
      AppLogger.instance.warn('agent_tamper: load failed $e');
      return null;
    }
  }

  void start() {
    if (!Platform.isWindows) return;
    _timer?.cancel();
    _timer = Timer.periodic(kInterval, (_) {
      unawaited(runVerifyAndHeal(reason: 'periodic'));
    });
    Future<void>.delayed(const Duration(seconds: 45), () {
      unawaited(runVerifyAndHeal(reason: 'boot'));
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<AgentTamperReport?> runVerifyAndHeal({
    String reason = 'manual',
    bool autoHeal = true,
  }) async {
    if (!Platform.isWindows || _running) return loadLastReport();
    _running = true;
    try {
      final String? verify = await _scriptPath('Verify-AgentTamper.ps1');
      if (verify == null) return null;

      ProcessResult vr = await windowsRunHidden(
        _powershellExe(),
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          verify,
          '-Quiet',
        ],
      );

      AgentTamperReport? report = await loadLastReport();
      if (report != null && !report.allPass && autoHeal) {
        final String? heal = await _scriptPath('Heal-AgentTamper.ps1');
        if (heal != null) {
          await windowsRunHidden(
            _powershellExe(),
            <String>[
              '-NoProfile',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              heal,
              '-Quiet',
            ],
          );
          await WindowsOfflineBlockGuardService.instance.ensureRegistered();
          await WindowsOfflineBlockGuardService.instance.runNow();
          vr = await windowsRunHidden(
            _powershellExe(),
            <String>[
              '-NoProfile',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              verify,
              '-Quiet',
            ],
          );
          report = await loadLastReport();
        }
      }

      if (report != null) {
        BlockActivityLogService.instance.record(
          kind: BlockActivityKind.protection,
          level: report.allPass ? 'info' : 'warn',
          message:
              'Agent tamper $reason: ${report.passCount}/${report.totalCount}',
          data: <String, Object?>{
            'passCount': report.passCount,
            'failed': report.scenarios
                .where((AgentTamperCase c) => !c.mitigated)
                .map((AgentTamperCase c) => c.id)
                .toList(),
          },
        );
        if (!report.allPass) {
          await CursorAgentFixLogService.instance.record(
            CursorAgentFixEntry(
              component: 'agent_tamper_watchdog',
              action: reason,
              ok: false,
              verdict: report.scenarios
                  .where((AgentTamperCase c) => !c.mitigated)
                  .map((AgentTamperCase c) => '${c.id}:${c.detail}')
                  .join('; '),
            ),
          );
        }
      }

      AppLogger.instance.info(
        'agent_tamper: verify exit=${vr.exitCode} reason=$reason',
      );
      return report;
    } finally {
      _running = false;
    }
  }
}
