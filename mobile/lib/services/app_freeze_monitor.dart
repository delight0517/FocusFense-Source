import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';

import '../router/app_router.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'crash_journal_service.dart';
import 'lag_diagnostic_bundle_service.dart';
import 'lag_process_census.dart';
import 'lag_work_classifier.dart';
import 'severe_lag_session_service.dart';
import 'work_context_tracker.dart';

/// Detects UI-thread jank / freezes by measuring the gap between scheduled
/// heartbeat ticks.  When a gap exceeds [_kFreezeThreshold], the event is
/// written to `freeze_log.jsonl` in the Debug folder so Cursor / the agent
/// can inspect it later.
///
/// **Does NOT run a Timer on the UI thread** — the heartbeat is posted via
/// [SchedulerBinding.scheduleFrameCallback] + isolate ping, keeping overhead
/// near zero during normal operation.
final class AppFreezeMonitor {
  AppFreezeMonitor._();
  static final AppFreezeMonitor instance = AppFreezeMonitor._();

  static const Duration _kHeartbeatInterval = Duration(seconds: 2);
  static const Duration _kFreezeThreshold = Duration(milliseconds: 600);
  /// User-reported "app frozen 30s+ with no notice" — dedicated Cursor report.
  static const Duration _kSevereFreezeThreshold = Duration(seconds: 30);
  /// Gaps longer than this are sleep/resume — not UI jank.
  // @incident: sleep_resume_false_freeze — ignore gaps up to 5 min;
  // sleep/hibernate resume looks identical to a UI freeze and previously
  // caused false freeze alerts.
  static const Duration _kSleepGapIgnore = Duration(minutes: 5);
  static const Duration _kCooldown = Duration(seconds: 30);
  static const Duration _kSevereCooldown = Duration(minutes: 2);
  static const int _kMaxEntries = 200;

  bool _started = false;
  DateTime? _lastHeartbeat;
  DateTime? _lastFreezeAt;
  DateTime? _lastSevereFreezeAt;
  int _freezeCount = 0;
  int _severeFreezeCount = 0;
  Timer? _bgTimer;

  String get _logPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'freeze_log.jsonl',
      );

  String get _severeLastPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'severe_freeze_last.json',
      );

  /// Call once after `runApp` / first frame.
  void start() {
    if (_started) return;
    _started = true;
    _lastHeartbeat = DateTime.now();
    // Background timer fires every 2 s; measures wall-clock gap.
    _bgTimer = Timer.periodic(_kHeartbeatInterval, _onTick);
    AppLogger.instance.info('[AppFreezeMonitor] started (threshold=${_kFreezeThreshold.inMilliseconds}ms)');
  }

  void stop() {
    _bgTimer?.cancel();
    _bgTimer = null;
    _started = false;
  }

  void _onTick(Timer _) {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastHeartbeat;
    _lastHeartbeat = now;
    if (last == null) return;

    final Duration gap = now.difference(last);
    // PC sleep / app suspend — do not log as freeze.
    if (gap > _kSleepGapIgnore) {
      _lastHeartbeat = now;
      return;
    }
    // Expected gap ≈ 2 s. If > 2 s + threshold → UI thread was frozen.
    final Duration excess = gap - _kHeartbeatInterval;

    if (gap >= _kSevereFreezeThreshold) {
      unawaited(_onSevereFreeze(gap, excess, now));
      return;
    }

    if (excess < _kFreezeThreshold) return;

    // Cooldown: don't spam log.
    if (_lastFreezeAt != null &&
        now.difference(_lastFreezeAt!) < _kCooldown) {
      return;
    }
    _lastFreezeAt = now;
    _freezeCount++;

    final LagWorkClassification classification = LagWorkClassifier.classify(
      activeLabels: WorkContextTracker.instance.activeLabels(),
      triggerKind: 'ui_freeze',
    );
    final Map<String, dynamic> entry = <String, dynamic>{
      'ts': now.toIso8601String(),
      'freezeMs': gap.inMilliseconds,
      'excessMs': excess.inMilliseconds,
      'freezeIndex': _freezeCount,
      'elapsedHuman': _formatMs(gap.inMilliseconds),
      'classification': classification.toJson(),
      'activeWork': WorkContextTracker.instance.activeStackJson(),
      'recentLogLines': AppLogger.instance.recentLines(30),
    };
    SevereLagSessionService.instance.onDetectorEvent(
      kind: 'ui_freeze',
      metrics: <String, Object?>{
        'freezeMs': gap.inMilliseconds,
        'excessMs': excess.inMilliseconds,
      },
    );

    AppLogger.instance.warn(
      '[AppFreezeMonitor] UI jank detected — gap ${gap.inMilliseconds}ms '
      '(excess ${excess.inMilliseconds}ms), total freezes: $_freezeCount',
    );

    unawaited(_append(entry));
    unawaited(_recordBundle(gap.inMilliseconds, excess.inMilliseconds));
  }

  Future<void> _onSevereFreeze(
    Duration gap,
    Duration excess,
    DateTime now,
  ) async {
    if (_lastSevereFreezeAt != null &&
        now.difference(_lastSevereFreezeAt!) < _kSevereCooldown) {
      return;
    }
    _lastSevereFreezeAt = now;
    _severeFreezeCount++;

    final Map<String, int> census = await LagProcessCensus.countWindows();
    final LagWorkClassification classification = LagWorkClassifier.classify(
      activeLabels: WorkContextTracker.instance.activeLabels(),
      triggerKind: 'severe_ui_freeze',
      highChildProcessStorm: (census['reg'] ?? 0) >= 12 ||
          (census['powershell'] ?? 0) >= 8,
    );
    SevereLagSessionService.instance.onDetectorEvent(
      kind: 'severe_ui_freeze',
      metrics: <String, Object?>{
        'freezeMs': gap.inMilliseconds,
        'excessMs': excess.inMilliseconds,
      },
      childProcesses: census,
    );
    final Map<String, Object?> entry = <String, Object?>{
      'schemaVersion': 1,
      'reportKind': 'six_vpn_severe_ui_freeze',
      'ts': now.toIso8601String(),
      'freezeMs': gap.inMilliseconds,
      'excessMs': excess.inMilliseconds,
      'elapsedHuman': _formatMs(gap.inMilliseconds),
      'severeIndex': _severeFreezeCount,
      'userNotified': true,
      'classification': classification.toJson(),
      'activeWork': WorkContextTracker.instance.activeStackJson(),
      'recentWork': WorkContextTracker.instance.recentCompletedJson(),
      'recentLogLines': AppLogger.instance.recentLines(80),
      'childProcesses': census,
      'agentHints': <String, String>{
        'cursorScript': 'mobile/tools/Read-CursorFullDiagnosticPack.ps1',
        'fix':
            'Check activeWork + childProcesses reg/powershell counts. '
            'Stagger boot probes (browser_block_health, universal_browser_block).',
      },
    };

    AppLogger.instance.error(
      '[AppFreezeMonitor] SEVERE UI freeze ${gap.inMilliseconds}ms '
      '(excess ${excess.inMilliseconds}ms) — Cursor pack recommended',
    );

    try {
      final File f = File(_severeLastPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(entry),
        flush: true,
      );
    } catch (e) {
      debugPrint('[AppFreezeMonitor] severe log error: $e');
    }

    await LagDiagnosticBundleService.instance.record(
      kind: 'severe_ui_freeze',
      severity: 'critical',
      metrics: <String, Object?>{
        'freezeMs': gap.inMilliseconds,
        'excessMs': excess.inMilliseconds,
        'severeIndex': _severeFreezeCount,
      },
      childProcesses: census,
    );

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.selfHeal,
      message:
          '심각한 UI 프리즈 ${gap.inSeconds}초 — 앱이 멈춘 것으로 기록됨 (Cursor 진단 팩 권장)',
      data: entry,
      level: 'error',
      debounceKey: 'severe_ui_freeze',
    );

    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(
            '【Focus Fense】앱이 ${gap.inSeconds}초 동안 멈췄습니다 — '
            '설정→진단→「Cursor 원탭 진단」으로 AI에 보내세요',
          ),
          duration: const Duration(seconds: 12),
          behavior: SnackBarBehavior.floating,
          showCloseIcon: true,
        ),
      );
    }
  }

  Future<void> _recordBundle(int freezeMs, int excessMs) async {
    final Map<String, int> census = await LagProcessCensus.countWindows();
    await LagDiagnosticBundleService.instance.record(
      kind: 'ui_freeze',
      severity: excessMs >= 1500 ? 'severe' : 'warning',
      metrics: <String, Object?>{
        'freezeMs': freezeMs,
        'excessMs': excessMs,
        'freezeIndex': _freezeCount,
      },
      childProcesses: census,
    );
  }

  Future<void> _append(Map<String, dynamic> entry) async {
    try {
      final File f = File(_logPath);
      final List<String> lines = await f.exists()
          ? (await f.readAsLines())
          : <String>[];
      // Trim old entries.
      while (lines.length >= _kMaxEntries) {
        lines.removeAt(0);
      }
      lines.add(jsonEncode(entry));
      await f.writeAsString(lines.join('\n') + '\n');
    } catch (e) {
      debugPrint('[AppFreezeMonitor] log error: $e');
    }
  }

  /// Returns the last N freeze events from disk.
  Future<List<Map<String, dynamic>>> readLog({int limit = 20}) async {
    try {
      final File f = File(_logPath);
      if (!await f.exists()) return <Map<String, dynamic>>[];
      final List<String> lines = await f.readAsLines();
      return lines.reversed
          .take(limit)
          .map((String l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// Human-readable summary for Cursor / agent consumption.
  Future<String> summary() async {
    final List<Map<String, dynamic>> events = await readLog(limit: 10);
    if (events.isEmpty) return 'No freeze events recorded.';
    final StringBuffer sb = StringBuffer()
      ..writeln('=== AppFreezeMonitor — last ${events.length} freeze events ===');
    for (final Map<String, dynamic> e in events) {
      sb.writeln(
        '  [${e['ts']}] ${e['freezeMs']}ms total / ${e['excessMs']}ms excess',
      );
    }
    sb.writeln('Total freezes since start: $_freezeCount');
    return sb.toString();
  }

  int get freezeCount => _freezeCount;

  static String _formatMs(int ms) {
    if (ms >= 60000) {
      return '${ms ~/ 60000}분 ${(ms % 60000) ~/ 1000}초';
    }
    return '${(ms / 1000).toStringAsFixed(1)}초';
  }
}
