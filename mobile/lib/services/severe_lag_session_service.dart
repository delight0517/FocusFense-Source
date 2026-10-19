import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'app_operation_progress_service.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';
import 'lag_diagnostic_bundle_service.dart';
import 'lag_process_census.dart';
import 'lag_work_classifier.dart';
import 'work_context_tracker.dart';

/// Central orchestrator for severe lag / freeze / CPU spike sessions.
///
/// Drives the full-screen [SevereLagOverlay], writes agent-readable
/// `severe_lag_session_last.json`, and unifies detector events.
final class SevereLagSessionService {
  SevereLagSessionService._();
  static final SevereLagSessionService instance = SevereLagSessionService._();

  // 2026-06-19 perf fix: was 500ms — 120 ticks/min just to check whether
  // an overlay should appear/disappear. The actual severe events are pushed
  // via onDetectorEvent; this poll only handles "long bg work" debounce and
  // the post-event recovery check. 2s is more than fast enough for both.
  static const Duration _kPollInterval = Duration(seconds: 2);
  static const Duration _kBgWorkOverlayDelay = Duration(seconds: 8);
  static const Duration _kMinOverlayDuration = Duration(seconds: 2);
  static const int _kStormRegThreshold = 12;
  static const int _kStormPsThreshold = 8;

  Timer? _poll;
  bool _started = false;
  SevereLagSession? _active;
  DateTime? _overlayShownAt;
  int _stallBurst = 0;
  DateTime? _lastStallAt;

  final ValueNotifier<SevereLagSession?> session =
      ValueNotifier<SevereLagSession?>(null);

  String get lastJsonPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'severe_lag_session_last.json',
      );

  void start() {
    if (_started) return;
    _started = true;
    _poll = Timer.periodic(_kPollInterval, (_) => _evaluate());
    AppLogger.instance.info('severe_lag_session: started');
  }

  void stop() {
    _poll?.cancel();
    _poll = null;
    _started = false;
    _endSession(reason: 'service_stop');
  }

  /// Called by UI stall / freeze / CPU detectors.
  void onDetectorEvent({
    required String kind,
    required Map<String, Object?> metrics,
    Map<String, int>? childProcesses,
  }) {
    if (kind == 'ui_stall') {
      final int stallMs = metrics['stallMs'] as int? ?? 0;
      if (stallMs >= 800) {
        final DateTime now = DateTime.now();
        if (_lastStallAt != null &&
            now.difference(_lastStallAt!) < const Duration(seconds: 4)) {
          _stallBurst++;
        } else {
          _stallBurst = 1;
        }
        _lastStallAt = now;
      }
    }
    final bool severe = _isSevereDetectorEvent(kind, metrics);
    if (!severe) return;
    unawaited(_openOrRefresh(
      triggerKind: kind,
      metrics: metrics,
      childProcesses: childProcesses,
    ));
  }

  bool _isSevereDetectorEvent(String kind, Map<String, Object?> metrics) {
    switch (kind) {
      case 'severe_ui_freeze':
        return true;
      case 'ui_freeze':
        final int ms = metrics['freezeMs'] as int? ?? 0;
        return ms >= 2500;
      case 'ui_stall':
        final int ms = metrics['stallMs'] as int? ?? 0;
        return ms >= 1500 || _stallBurst >= 3;
      case 'cpu_spike':
        final double cpu = (metrics['cpuPctOneCore'] as num?)?.toDouble() ?? 0;
        return cpu >= 55;
      default:
        return false;
    }
  }

  void _evaluate() {
    final AppOperationProgress? op =
        AppOperationProgressService.instance.primary;
    final List<String> labels = WorkContextTracker.instance.activeLabels();
    final bool explicitOp = op != null && op.explicit;
    final bool longBg = labels.isNotEmpty &&
        op != null &&
        !op.explicit &&
        op.elapsed >= _kBgWorkOverlayDelay;
    if (explicitOp || longBg) {
      final AppOperationProgress progress = op;
      unawaited(_openOrRefresh(
        triggerKind: explicitOp ? 'proactive_progress' : 'proactive_bg_work',
        metrics: <String, Object?>{
          'progressPercent': progress.percent,
          'progressTitle': progress.title,
        },
      ));
      return;
    }
    if (_active != null && _overlayShownAt != null) {
      final Duration shown = DateTime.now().difference(_overlayShownAt!);
      if (shown < _kMinOverlayDuration) return;
      if (!WorkContextTracker.instance.isBusy &&
          !AppOperationProgressService.instance.hasActive &&
          _stallBurst == 0) {
        _endSession(reason: 'recovered');
      }
    }
  }

  Future<void> _openOrRefresh({
    required String triggerKind,
    Map<String, Object?> metrics = const <String, Object?>{},
    Map<String, int>? childProcesses,
  }) async {
    final DateTime now = DateTime.now();
    final AppOperationProgress? op =
        AppOperationProgressService.instance.primary;
    final List<String> labels = WorkContextTracker.instance.activeLabels();
    final Map<String, int> census =
        childProcesses ?? await LagProcessCensus.countWindows();
    final bool storm = (census['reg'] ?? 0) >= _kStormRegThreshold ||
        (census['powershell'] ?? 0) >= _kStormPsThreshold;

    final LagWorkClassification classification = LagWorkClassifier.classify(
      activeLabels: labels,
      progressTitle: op?.title,
      triggerKind: triggerKind,
      highChildProcessStorm: storm,
    );

    // 2026-06-20 UX fix v2: the full-screen overlay was landing on top of
    // *expected* heavy work like 자율 점검 적용 (3-minute pipeline) and
    // 원탭 차단 적용 — blocking the user from using the app for 5-10
    // minutes for what is clearly normal background work. The first pass
    // of this fix gated on `&& !storm` but the storm threshold
    // (powershell ≥ 8) hits during normal pipeline runs, so the overlay
    // still appeared. **Rule now**: legitimacy == expectedHeavy or
    // backgroundMaintenance ALWAYS skips the overlay. The strip footer
    // surfaces progress non-modally and the activity log captures the
    // storm-process counts for diagnostics. Only unexpectedBug opens the
    // modal — i.e. UI freeze without a matching WorkContextTracker label.
    final bool expectedClassification = classification.legitimacy ==
            LagLegitimacy.expectedHeavy ||
        classification.legitimacy == LagLegitimacy.backgroundMaintenance;
    if (expectedClassification) {
      if (_active == null) {
        AppLogger.instance.info(
          'severe_lag_session: SUPPRESSED overlay '
          '(${classification.legitimacy.name}, label=${classification.primaryLabel}, '
          'trigger=$triggerKind, storm=$storm, ps=${census['powershell']} reg=${census['reg']})',
        );
      }
      // End any leftover overlay session immediately — we shouldn't keep
      // the modal up just because a prior trigger opened it before this
      // gate was in place.
      if (_active != null) {
        _endSession(reason: 'expected_work_suppress');
      }
      return;
    }

    if (_active == null) {
      _active = SevereLagSession(
        id: 'lag_${now.millisecondsSinceEpoch}',
        startedAt: now,
        triggerKind: triggerKind,
        classification: classification,
        metrics: Map<String, Object?>.from(metrics),
        childProcesses: census,
      );
      _overlayShownAt = now;
      session.value = _active;
      AppLogger.instance.warn(
        'severe_lag_session: OPEN $triggerKind '
        '${classification.legitimacy.name} '
        'label=${classification.primaryLabel}',
      );
    } else {
      _active = _active!.copyWith(
        lastRefreshAt: now,
        triggerKind: triggerKind,
        classification: classification,
        metrics: <String, Object?>{
          ..._active!.metrics,
          ...metrics,
        },
        childProcesses: census,
        refreshCount: _active!.refreshCount + 1,
      );
      session.value = _active;
    }
    unawaited(_persistSnapshot(_active!, partial: true));
  }

  void _endSession({required String reason}) {
    final SevereLagSession? cur = _active;
    if (cur == null) return;
    final DateTime endedAt = DateTime.now();
    final SevereLagSession finalSession = cur.copyWith(
      endedAt: endedAt,
      endReason: reason,
    );
    _active = null;
    _overlayShownAt = null;
    _stallBurst = 0;
    session.value = null;
    unawaited(_persistSnapshot(finalSession, partial: false));
    unawaited(LagDiagnosticBundleService.instance.record(
      kind: finalSession.classification.legitimacy ==
              LagLegitimacy.unexpectedBug
          ? 'severe_lag_session_bug'
          : 'severe_lag_session_expected',
      severity: finalSession.classification.legitimacy ==
              LagLegitimacy.unexpectedBug
          ? 'critical'
          : 'info',
      metrics: finalSession.toMetrics(),
      childProcesses: finalSession.childProcesses,
    ));
    AppLogger.instance.info(
      'severe_lag_session: END ${finalSession.elapsedMs}ms reason=$reason',
    );
  }

  Future<void> _persistSnapshot(
    SevereLagSession s, {
    required bool partial,
  }) async {
    try {
      String buildLine = '';
      try {
        buildLine = await BuildIdentityService.instance.summaryLine();
      } catch (_) {}
      final Map<String, Object?> doc = s.toJson(
        buildIdentity: buildLine,
        partial: partial,
        activeWork: WorkContextTracker.instance.activeStackJson(),
        recentWork: WorkContextTracker.instance.recentCompletedJson(),
        recentLogLines: AppLogger.instance.recentLines(40),
      );
      final File f = File(lastJsonPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(doc),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('severe_lag_session persist failed: $e');
    }
  }

  /// Clipboard-ready block for Cursor / Claude (includes elapsed time).
  Future<String> copyableAgentReport() async {
    final StringBuffer sb = StringBuffer()
      ..writeln('=== 6 VPN Blocker — Severe lag session report ===')
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln('Folder: ${CrashJournalService.instance.debugFolderPath}')
      ..writeln('');

  final SevereLagSession? live = _active ?? session.value;
    if (live != null) {
      sb.writeln('--- LIVE session (in progress) ---');
      sb.writeln(_formatSessionHuman(live));
      sb.writeln('');
    }

    try {
      final File f = File(lastJsonPath);
      if (await f.exists()) {
        sb.writeln('--- severe_lag_session_last.json ---');
        sb.writeln(await f.readAsString());
        sb.writeln('');
      }
    } catch (_) {}

    sb.writeln(await LagDiagnosticBundleService.instance.agentPrompt(tailEvents: 3));
    if (!Platform.isWindows && !Platform.isMacOS) {
      sb.writeln('');
      sb.writeln(
        'Tip (iOS/Android): paste this entire block into Cursor chat on your PC.',
      );
    }
    return sb.toString();
  }

  static String _formatSessionHuman(SevereLagSession s) {
    final String elapsed = _formatDuration(Duration(milliseconds: s.elapsedMs));
    return 'trigger=${s.triggerKind} · ${s.classification.legitimacyLabelKo}\n'
        '작업: ${s.classification.headlineKo}\n'
        '경과: $elapsed\n'
        '${s.classification.explainKo}';
  }

  static String _formatDuration(Duration d) {
    if (d.inHours >= 1) {
      return '${d.inHours}시간 ${d.inMinutes % 60}분 ${d.inSeconds % 60}초';
    }
    if (d.inMinutes >= 1) {
      return '${d.inMinutes}분 ${d.inSeconds % 60}초';
    }
    return '${d.inSeconds}초';
  }
}

final class SevereLagSession {
  SevereLagSession({
    required this.id,
    required this.startedAt,
    required this.triggerKind,
    required this.classification,
    this.metrics = const <String, Object?>{},
    this.childProcesses = const <String, int>{},
    this.lastRefreshAt,
    this.endedAt,
    this.endReason,
    this.refreshCount = 0,
  });

  final String id;
  final DateTime startedAt;
  final String triggerKind;
  final LagWorkClassification classification;
  final Map<String, Object?> metrics;
  final Map<String, int> childProcesses;
  final DateTime? lastRefreshAt;
  final DateTime? endedAt;
  final String? endReason;
  final int refreshCount;

  int get elapsedMs =>
      (endedAt ?? DateTime.now()).difference(startedAt).inMilliseconds;

  SevereLagSession copyWith({
    String? triggerKind,
    LagWorkClassification? classification,
    Map<String, Object?>? metrics,
    Map<String, int>? childProcesses,
    DateTime? lastRefreshAt,
    DateTime? endedAt,
    String? endReason,
    int? refreshCount,
  }) {
    return SevereLagSession(
      id: id,
      startedAt: startedAt,
      triggerKind: triggerKind ?? this.triggerKind,
      classification: classification ?? this.classification,
      metrics: metrics ?? this.metrics,
      childProcesses: childProcesses ?? this.childProcesses,
      lastRefreshAt: lastRefreshAt ?? this.lastRefreshAt,
      endedAt: endedAt ?? this.endedAt,
      endReason: endReason ?? this.endReason,
      refreshCount: refreshCount ?? this.refreshCount,
    );
  }

  Map<String, Object?> toMetrics() => <String, Object?>{
        'sessionId': id,
        'triggerKind': triggerKind,
        'elapsedMs': elapsedMs,
        'refreshCount': refreshCount,
        'endReason': endReason,
        ...metrics,
        ...classification.toJson(),
      };

  Map<String, Object?> toJson({
    String buildIdentity = '',
    bool partial = false,
    List<Map<String, Object?>> activeWork = const <Map<String, Object?>>[],
    List<Map<String, Object?>> recentWork = const <Map<String, Object?>>[],
    List<String> recentLogLines = const <String>[],
  }) =>
      <String, Object?>{
        'schemaVersion': 1,
        'reportKind': 'six_vpn_severe_lag_session',
        'partial': partial,
        'sessionId': id,
        'startedAt': startedAt.toIso8601String(),
        'lastRefreshAt': (lastRefreshAt ?? startedAt).toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'elapsedMs': elapsedMs,
        'elapsedHuman': SevereLagSessionService._formatDuration(
          Duration(milliseconds: elapsedMs),
        ),
        'triggerKind': triggerKind,
        'endReason': endReason,
        'refreshCount': refreshCount,
        'buildIdentity': buildIdentity,
        'classification': classification.toJson(),
        'metrics': metrics,
        'childProcesses': childProcesses,
        'activeWork': activeWork,
        'recentWork': recentWork,
        'recentLogLines': recentLogLines,
        'agentHints': <String, Object?>{
          'expectedVsBug':
              'legitimacy=expectedHeavy|backgroundMaintenance → user wait OK; '
              'unexpectedBug → investigate spawn-storm / missing WorkContext label',
          'copyCommand': 'Settings → Diagnostics → AI bundle copy',
          'powershell': 'mobile/tools/Read-LagDiagnostics.ps1',
        },
      };
}
