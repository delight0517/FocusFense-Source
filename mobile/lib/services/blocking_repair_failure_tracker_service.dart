import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';
import 'cursor_agent_fix_log_service.dart';

/// Tracks repeated blocking-repair failures and writes **Cursor-readable**
/// artifacts when a subsystem keeps failing (reconsider architecture signal).
final class BlockingRepairFailureTrackerService {
  BlockingRepairFailureTrackerService._();
  static final BlockingRepairFailureTrackerService instance =
      BlockingRepairFailureTrackerService._();

  static const int kEscalateAfterConsecutiveFailures = 3;

  String get streakPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'blocking_repair_failure_streak.json',
      );

  String get cursorPromptPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'blocking_repair_cursor_prompt.txt',
      );

  Future<void> record({
    required String component,
    required String action,
    required bool ok,
    required String verdict,
    String reason = 'auto',
    Map<String, Object?> details = const <String, Object?>{},
    List<String> failedLayers = const <String>[],
    List<String> appliedLayers = const <String>[],
    List<String> fixesAttempted = const <String>[],
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) return;

    await CursorAgentFixLogService.instance.record(
      CursorAgentFixEntry(
        component: component,
        action: action,
        ok: ok,
        verdict: verdict,
        reason: reason,
        details: details,
        failedLayers: failedLayers,
        appliedLayers: appliedLayers,
        fixesAttempted: fixesAttempted,
      ),
    );

    final Map<String, Object?> streak = await _loadStreak();
    final Map<String, Object?> components = Map<String, Object?>.from(
      streak['components'] as Map? ?? <String, Object?>{},
    );
    final Map<String, Object?> prev = Map<String, Object?>.from(
      components[component] as Map? ?? <String, Object?>{},
    );
    final int consecutive = ok
        ? 0
        : ((prev['consecutiveFailures'] as int? ?? 0) + 1);
    final List<Object?> history = List<Object?>.from(
      prev['recent'] as List? ?? <Object?>[],
    );
    history.insert(0, <String, Object?>{
      'at': DateTime.now().toIso8601String(),
      'ok': ok,
      'action': action,
      'verdict': verdict,
      'reason': reason,
      'failedLayers': failedLayers,
    });
    while (history.length > 12) {
      history.removeLast();
    }

    components[component] = <String, Object?>{
      'consecutiveFailures': consecutive,
      'lastOk': ok,
      'lastVerdict': verdict,
      'lastAt': DateTime.now().toIso8601String(),
      'recent': history,
    };

    final String build = await BuildIdentityService.instance.summaryLine();
    final Map<String, Object?> body = <String, Object?>{
      'updatedAt': DateTime.now().toIso8601String(),
      'build': build,
      'components': components,
      'cursorReadme': 'mobile/tools/Read-CursorAgentFixLog.ps1',
      'fixLogJsonl': CursorAgentFixLogService.instance.jsonlPath,
      'fixLogLast': CursorAgentFixLogService.instance.lastPath,
    };

    await CrashJournalService.instance.warmup();
    await File(streakPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(body),
      flush: true,
    );

    if (!ok && consecutive >= kEscalateAfterConsecutiveFailures) {
      await _writeCursorPrompt(
        component: component,
        consecutive: consecutive,
        verdict: verdict,
        details: details,
        failedLayers: failedLayers,
        build: build,
      );
      AppLogger.instance.warn(
        'blocking_repair: $component failed $consecutive× — cursor prompt written',
      );
    }
  }

  Future<Map<String, Object?>> _loadStreak() async {
    try {
      final File f = File(streakPath);
      if (!await f.exists()) return <String, Object?>{};
      final Object? j = jsonDecode(await f.readAsString());
      if (j is Map) return Map<String, Object?>.from(j);
    } catch (_) {}
    return <String, Object?>{};
  }

  Future<void> _writeCursorPrompt({
    required String component,
    required int consecutive,
    required String verdict,
    required Map<String, Object?> details,
    required List<String> failedLayers,
    required String build,
  }) async {
    final StringBuffer sb = StringBuffer();
    sb.writeln('=== Focus Fense — Blocking repair keeps failing ===');
    sb.writeln('Build: $build');
    sb.writeln('Component: $component');
    sb.writeln('Consecutive failures: $consecutive');
    sb.writeln('Last verdict: $verdict');
    sb.writeln('Failed layers: ${failedLayers.join(", ")}');
    sb.writeln();
    sb.writeln('Cursor: read these files first:');
    sb.writeln('  ${CursorAgentFixLogService.instance.lastPath}');
    sb.writeln('  $streakPath');
    sb.writeln('  ${p.join(CrashJournalService.instance.debugFolderPath, "numeric_apex_hosts_gap_heal_last.json")}');
    sb.writeln('  ${p.join(CrashJournalService.instance.debugFolderPath, "autonomous_apply_last.json")}');
    sb.writeln('  ${p.join(CrashJournalService.instance.debugFolderPath, "boot_browser_autofix_last.json")}');
    sb.writeln();
    sb.writeln('Details JSON:');
    sb.writeln(const JsonEncoder.withIndent('  ').convert(details));
    sb.writeln();
    sb.writeln('Action: reconsider this repair pipeline — HKCU-only false success,');
    sb.writeln('UAC not approved, or hosts payload missing numeric apex (mingky01.live).');
    sb.writeln('See docs/AUTONOMOUS_DIAGNOSTIC_AGENT_BLUEPRINT.md');

    await File(cursorPromptPath).writeAsString(sb.toString(), flush: true);
  }
}
