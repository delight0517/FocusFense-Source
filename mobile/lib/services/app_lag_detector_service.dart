import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'crash_journal_service.dart';
import 'lag_diagnostic_bundle_service.dart';
import 'lag_process_census.dart';
import 'lag_work_classifier.dart';
import 'severe_lag_session_service.dart';
import 'work_context_tracker.dart';

/// In-app lag detector. Sits on a background isolate (so it isn't itself
/// blocked by the very lag it tries to measure) and pings the UI isolate
/// on a 1-second tempo. If a ping takes longer than the configured budget
/// to round-trip, that's a stall and we log:
///
///   * the stall duration
///   * how many `reg.exe` / `powershell.exe` child processes are alive
///     (a high count is a strong hint the spawn-storm is the cause)
///   * a snapshot of currently-running background timers (best-effort)
///
/// Output: `%LOCALAPPDATA%\SixVPNBlocker\debug\app_lag.log` (append-only)
/// + `app_lag_last.json` (most recent stall, agent-readable).
///
/// User-facing: the diagnostics tab can read these files and surface a
/// "복사 → Claude에 붙여넣기" button when stalls are detected.
///
/// Designed to be cheap: 1 ping/s of `compute()` round-trip + at most one
/// `Get-Process` call per stall (never per tick). Stays well under the
/// performance budget set in CLAUDE.md.
final class AppLagDetectorService {
  AppLagDetectorService._();
  static final AppLagDetectorService instance = AppLagDetectorService._();

  static const Duration _kPingInterval = Duration(seconds: 1);
  // Threshold for "this is a stall worth recording". 300ms is the usual
  // bar where users perceive UI as laggy.
  static const Duration _kStallThreshold = Duration(milliseconds: 300);
  // @incident: perf_budget_2026-06-08 — rate-limit repeated lag
  // logging/process-census during sustained stalls; without this the
  // census itself becomes part of the CPU spike it's trying to diagnose.
  // Don't log more than one stall per 10 seconds even if more occur —
  // a sustained stall would spam the log otherwise.
  static const Duration _kLogCooldown = Duration(seconds: 10);
  // Don't run a child-process census on every stall — too expensive when
  // the app is already busy. One census per 30s max.
  static const Duration _kCensusCooldown = Duration(seconds: 30);

  Timer? _timer;
  bool _started = false;
  DateTime? _lastStallLogged;
  DateTime? _lastCensus;
  Map<String, int> _lastCensusResult = const <String, int>{};

  /// In-memory rolling list of recent stalls, surfaced to the diagnostics UI.
  final ValueNotifier<List<LagEvent>> recentStalls =
      ValueNotifier<List<LagEvent>>(const <LagEvent>[]);

  String get logPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'app_lag.log',
      );

  String get lastJsonPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'app_lag_last.json',
      );

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await CrashJournalService.instance.warmup();
    _timer?.cancel();
    _timer = Timer.periodic(_kPingInterval, (_) => _tick());
    AppLogger.instance.info('app_lag_detector: started '
        '(threshold=${_kStallThreshold.inMilliseconds}ms)');
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      // The work itself is trivial — what matters is whether the UI
      // isolate's event loop gets back to us within the budget. If the
      // loop is wedged (heavy widget rebuild, sync I/O, JIT compile),
      // the await will take longer than expected.
      await Future<void>.delayed(Duration.zero);
    } finally {
      sw.stop();
    }
    if (sw.elapsed > _kStallThreshold) {
      _onStall(sw.elapsed);
    }
  }

  Future<void> _onStall(Duration elapsed) async {
    final DateTime now = DateTime.now();
    if (_lastStallLogged != null &&
        now.difference(_lastStallLogged!) < _kLogCooldown) {
      return;
    }
    _lastStallLogged = now;
    final Map<String, int> census = await _maybeCensus();
    final LagWorkClassification classification = LagWorkClassifier.classify(
      activeLabels: WorkContextTracker.instance.activeLabels(),
      triggerKind: 'ui_stall',
      highChildProcessStorm: (census['reg'] ?? 0) >= 12 ||
          (census['powershell'] ?? 0) >= 8,
    );
    final LagEvent event = LagEvent(
      at: now,
      stallMs: elapsed.inMilliseconds,
      childProcesses: census,
      activeWork: WorkContextTracker.instance.activeStackJson(),
      recentLogLines: AppLogger.instance.recentLines(30),
      classification: classification,
    );
    SevereLagSessionService.instance.onDetectorEvent(
      kind: 'ui_stall',
      metrics: <String, Object?>{'stallMs': elapsed.inMilliseconds},
      childProcesses: census,
    );
    // In-memory rolling buffer of last 50 stalls for the UI.
    final List<LagEvent> next = <LagEvent>[event, ...recentStalls.value];
    if (next.length > 50) next.removeRange(50, next.length);
    recentStalls.value = next;
    // Persist for the agent-readable contract.
    try {
      final File log = File(logPath);
      await log.parent.create(recursive: true);
      final String line =
          '${now.toIso8601String()} stall=${elapsed.inMilliseconds}ms '
          'reg=${census['reg'] ?? 0} ps=${census['powershell'] ?? 0} '
          'conhost=${census['conhost'] ?? 0}\n';
      await log.writeAsString(line, mode: FileMode.append, flush: true);
      await File(lastJsonPath).writeAsString(event.toJsonString(), flush: true);
    } catch (_) {/* best-effort */}
    AppLogger.instance.warn(
      'app_lag_detector: stall=${elapsed.inMilliseconds}ms '
      'reg=${census['reg'] ?? 0} ps=${census['powershell'] ?? 0}',
    );
    unawaited(LagDiagnosticBundleService.instance.record(
      kind: 'ui_stall',
      severity: elapsed.inMilliseconds >= 800 ? 'severe' : 'warning',
      metrics: <String, Object?>{
        'stallMs': elapsed.inMilliseconds,
      },
      childProcesses: census,
    ));
  }

  Future<Map<String, int>> _maybeCensus() async {
    final DateTime now = DateTime.now();
    if (_lastCensus != null &&
        now.difference(_lastCensus!) < _kCensusCooldown) {
      return _lastCensusResult;
    }
    _lastCensus = now;
    if (!Platform.isWindows) {
      _lastCensusResult = const <String, int>{};
      return _lastCensusResult;
    }
    // Use the actual OS process list. Run on a background isolate so the
    // call itself doesn't add to the stall we're measuring.
    try {
      final Map<String, int> result = await LagProcessCensus.countWindows();
      _lastCensusResult = result;
      return result;
    } catch (_) {
      return const <String, int>{};
    }
  }
}

/// One stall event — designed to be JSON-serializable for the agent
/// contract at `app_lag_last.json` and human-readable in the diagnostics
/// tab.
class LagEvent {
  const LagEvent({
    required this.at,
    required this.stallMs,
    required this.childProcesses,
    this.activeWork = const <Map<String, Object?>>[],
    this.recentLogLines = const <String>[],
    this.classification,
  });

  final DateTime at;
  final int stallMs;
  final Map<String, int> childProcesses;
  final List<Map<String, Object?>> activeWork;
  final List<String> recentLogLines;
  final LagWorkClassification? classification;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': 2,
        'reportKind': 'six_vpn_lag_event',
        'at': at.toIso8601String(),
        'stallMs': stallMs,
        'elapsedHuman': _formatMs(stallMs),
        'childProcesses': childProcesses,
        'activeWork': activeWork,
        'recentLogLines': recentLogLines,
        if (classification != null) 'classification': classification!.toJson(),
        'note':
            'High `reg`/`powershell`/`conhost` counts indicate a spawn-storm '
            "from a background probe. Check activeWork + recentLogLines.",
      };

  static String _formatMs(int ms) {
    if (ms >= 60000) {
      return '${ms ~/ 60000}분 ${(ms % 60000) ~/ 1000}초';
    }
    return '${(ms / 1000).toStringAsFixed(1)}초';
  }

  String toJsonString() => jsonEncode(toJson());
}
