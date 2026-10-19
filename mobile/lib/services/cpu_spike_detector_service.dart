import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'app_logger.dart';
import 'crash_journal_service.dart';
import 'lag_diagnostic_bundle_service.dart';
import 'lag_process_census.dart';
import 'lag_work_classifier.dart';
import 'severe_lag_session_service.dart';
import 'work_context_tracker.dart';

/// "CPU가 엄청나게 늘어나게 되는 순간"을 캐치해서, 그 때 무엇이 돌아가고
/// 있었는지를 정확히 기록하는 서비스. The user complained that lag was
/// happening repeatedly and there was no record of WHAT was running when
/// CPU spiked.
///
/// How it measures (no child-process spawn — PERFORMANCE BUDGET safe):
///   * Calls Win32 `GetProcessTimes` via dart:ffi on the current process.
///     Returns user + kernel CPU time in 100-ns units. No `tasklist`,
///     no `wmic`, no PowerShell spawn — measurement is essentially free.
///   * Samples every 6 seconds. Computes CPU% per core from the delta.
///   * Maintains a rolling baseline (median of last 10 samples).
///   * SPIKE = current CPU% ≥ max(50%, baseline × 3) for the just-finished window.
///
/// What it captures when a spike fires (only at the spike — rare):
///   * Self process: CPU%, uptime, peak working-set, current rss
///   * Child process census via tasklist (one spawn, gated by 60s cooldown)
///   * Most recent in-memory app log lines (no I/O)
///   * Currently-tagged "active service" labels (services voluntarily
///     register what they are doing via `noteActivity`)
///
/// Output (agent-readable):
///   * `%LOCALAPPDATA%\SixVPNBlocker\debug\cpu_spikes.jsonl` (append-only,
///     rotated at 256KB)
///   * `cpu_spike_last.json` (the most recent spike's full context)
///
/// In-app exposure: `recentSpikes` ValueNotifier so the diagnostics tab
/// can render the list with a one-click copy-to-Claude button.
final class CpuSpikeDetectorService {
  CpuSpikeDetectorService._();
  static final CpuSpikeDetectorService instance = CpuSpikeDetectorService._();

  // 2026-06-19 perf fix: was 6s → still 10 wakeups/min when the user is
  // idle, which kept the event loop hot and contributed to background lag.
  // CLAUDE.md rule #1 is absolute (≥30s); the FFI-is-cheap excuse doesn't
  // override it. Spikes lasting <30s are very rare and already covered by
  // the explicit detector-event path (onDetectorEvent).
  static const Duration _kSampleInterval = Duration(seconds: 30);
  // Spike threshold: 50% / core sustained, OR 3× the rolling baseline.
  static const double _kAbsoluteSpikePct = 50.0;
  static const double _kBaselineMultiplier = 3.0;
  // Don't dump context more often than this — would itself contribute to lag.
  static const Duration _kCaptureCooldown = Duration(seconds: 60);
  // Rolling window for baseline calculation.
  static const int _kBaselineWindow = 10;
  // Cap on the in-memory list shown in the UI (jsonl on disk keeps full history).
  static const int _kUiBufferSize = 30;
  // Approximate logical processor count for per-core normalization. Fixed
  // because Platform.numberOfProcessors returns the box's total — close enough.
  static int get _coreCount =>
      Platform.numberOfProcessors > 0 ? Platform.numberOfProcessors : 1;

  Timer? _timer;
  bool _started = false;
  bool _capturing = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  // Last sample's process time + wall clock — for delta CPU%.
  int? _lastProcessTimeNs;
  DateTime? _lastSampledAt;
  DateTime? _lastCaptureAt;

  // Rolling baseline.
  final List<double> _recentCpuPct = <double>[];

  // Activity labels — services call `noteActivity('hkcu_policy_apply')` when
  // they begin a heavy task and `clearActivity('hkcu_policy_apply')` when
  // done. The set is sampled when a spike fires so we know which service
  // was running.
  final Set<String> _activityLabels = <String>{};

  /// Subscribe in the UI for the live list of spikes.
  final ValueNotifier<List<CpuSpikeEvent>> recentSpikes =
      ValueNotifier<List<CpuSpikeEvent>>(const <CpuSpikeEvent>[]);

  String get jsonlPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'cpu_spikes.jsonl',
      );

  String get lastJsonPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'cpu_spike_last.json',
      );

  /// Public — call from any service entering a heavy task. The label appears
  /// in the next spike's captured context, telling the agent what was running.
  void noteActivity(String label) {
    _activityLabels.add(label);
  }

  /// Pair with [noteActivity] when the work finishes.
  void clearActivity(String label) {
    _activityLabels.remove(label);
  }

  Future<void> start() async {
    if (_started) return;
    if (!Platform.isWindows) return;
    _started = true;
    await CrashJournalService.instance.warmup();
    AppLogger.instance.info('cpu_spike_detector: started');
    _timer?.cancel();
    _timer = Timer.periodic(_kSampleInterval, (_) {
      if (_lifecycle != AppLifecycleState.resumed) return;
      _sample();
    });
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  void onLifecycleChange(AppLifecycleState state) {
    _lifecycle = state;
  }

  Future<void> _sample() async {
    final int? nowProcTimeNs = _readProcessTimeNs();
    final DateTime nowWall = DateTime.now();
    if (nowProcTimeNs == null) return;

    final int? prevNs = _lastProcessTimeNs;
    final DateTime? prevWall = _lastSampledAt;
    _lastProcessTimeNs = nowProcTimeNs;
    _lastSampledAt = nowWall;
    if (prevNs == null || prevWall == null) return;
    final int dtNs = nowProcTimeNs - prevNs;
    final int wallNs = nowWall.difference(prevWall).inMicroseconds * 1000;
    if (wallNs <= 0 || dtNs < 0) return;
    // CPU% per single core: dtNs / wallNs. As % of one core, multiply by 100.
    final double cpuPctOneCore = (dtNs / wallNs) * 100.0;
    // Update baseline.
    _recentCpuPct.add(cpuPctOneCore);
    if (_recentCpuPct.length > _kBaselineWindow) {
      _recentCpuPct.removeAt(0);
    }
    final double baseline = _baseline();
    final bool overAbsolute = cpuPctOneCore >= _kAbsoluteSpikePct;
    final bool overRelative =
        baseline > 5.0 && cpuPctOneCore >= baseline * _kBaselineMultiplier;
    if (!overAbsolute && !overRelative) return;
    // Cooldown so a sustained spike doesn't capture every 6s.
    if (_lastCaptureAt != null &&
        nowWall.difference(_lastCaptureAt!) < _kCaptureCooldown) {
      return;
    }
    _lastCaptureAt = nowWall;
    unawaited(_capture(
      cpuPctOneCore: cpuPctOneCore,
      baseline: baseline,
      reason: overAbsolute ? 'absolute>=50%' : 'baseline×3',
      sampledAt: nowWall,
    ));
  }

  double _baseline() {
    if (_recentCpuPct.isEmpty) return 0.0;
    final List<double> sorted = List<double>.from(_recentCpuPct)..sort();
    final int mid = sorted.length ~/ 2;
    return sorted[mid];
  }

  Future<void> _capture({
    required double cpuPctOneCore,
    required double baseline,
    required String reason,
    required DateTime sampledAt,
  }) async {
    if (_capturing) return;
    _capturing = true;
    try {
      List<String> activities = WorkContextTracker.instance.activeLabels();
      if (activities.isEmpty) {
        activities = _activityLabels.toList();
      }
      final List<String> recentLogs = AppLogger.instance.recentLines(50);
      final Map<String, int> children = await LagProcessCensus.countWindows();
      final int rssBytes = ProcessInfo.currentRss;
      final int maxRssBytes = ProcessInfo.maxRss;
      final LagWorkClassification classification = LagWorkClassifier.classify(
        activeLabels: activities,
        triggerKind: 'cpu_spike',
        highChildProcessStorm: (children['reg'] ?? 0) >= 12 ||
            (children['powershell'] ?? 0) >= 8,
      );
      final CpuSpikeEvent event = CpuSpikeEvent(
        at: sampledAt,
        cpuPctOneCore: cpuPctOneCore,
        cpuPctAcrossAllCores: cpuPctOneCore / _coreCount,
        baselinePct: baseline,
        reason: reason,
        currentRssMb: rssBytes / (1024 * 1024),
        peakRssMb: maxRssBytes / (1024 * 1024),
        appUptimeSeconds: sampledAt
            .difference(_appStartedAt ?? sampledAt)
            .inSeconds,
        activeServiceLabels: activities,
        childProcesses: children,
        recentLogLines: recentLogs,
        classification: classification,
      );
      SevereLagSessionService.instance.onDetectorEvent(
        kind: 'cpu_spike',
        metrics: <String, Object?>{
          'cpuPctOneCore': cpuPctOneCore,
          'baselinePct': baseline,
          'reason': reason,
        },
        childProcesses: children,
      );
      // Persist.
      try {
        final File last = File(lastJsonPath);
        await last.parent.create(recursive: true);
        await last.writeAsString(
          const JsonEncoder.withIndent('  ').convert(event.toJson()),
          flush: true,
        );
        final File jsonl = File(jsonlPath);
        // Rotate at 256KB.
        if (await jsonl.exists() && (await jsonl.length()) > 256 * 1024) {
          final File rotated = File('${jsonl.path}.1');
          if (await rotated.exists()) await rotated.delete();
          await jsonl.rename(rotated.path);
          await File(jsonl.path).create();
        }
        await File(jsonlPath).writeAsString(
          '${jsonEncode(event.toJson())}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (e) {
        AppLogger.instance.warn('cpu_spike persist failed: $e');
      }
      // UI buffer.
      final List<CpuSpikeEvent> next = <CpuSpikeEvent>[event, ...recentSpikes.value];
      if (next.length > _kUiBufferSize) next.removeRange(_kUiBufferSize, next.length);
      recentSpikes.value = next;
      AppLogger.instance.warn(
        'cpu_spike: cpu=${cpuPctOneCore.toStringAsFixed(1)}%/core '
        'baseline=${baseline.toStringAsFixed(1)}% reason=$reason '
        'children=${children['powershell'] ?? 0}ps/${children['reg'] ?? 0}reg '
        'activities=${activities.join(",")}',
      );
      unawaited(LagDiagnosticBundleService.instance.record(
        kind: 'cpu_spike',
        severity: cpuPctOneCore >= 80 ? 'severe' : 'warning',
        metrics: <String, Object?>{
          'cpuPctOneCore': cpuPctOneCore,
          'baselinePct': baseline,
          'reason': reason,
          'activeServiceLabels': activities,
        },
        childProcesses: children,
      ));
    } finally {
      _capturing = false;
    }
  }

  DateTime? _appStartedAt;
  void noteAppStart() {
    _appStartedAt ??= DateTime.now();
  }

  // ─────────────── Win32 GetProcessTimes via dart:ffi ────────────────
  //
  // GetProcessTimes(hProcess, lpCreationTime, lpExitTime, lpKernelTime,
  //   lpUserTime). All time outputs are FILETIME (64-bit, units of 100ns).
  // hProcess = -1 (GetCurrentProcess pseudo-handle).
  int? _readProcessTimeNs() {
    try {
      final Pointer<FILETIME> creation = calloc<FILETIME>();
      final Pointer<FILETIME> exit = calloc<FILETIME>();
      final Pointer<FILETIME> kernel = calloc<FILETIME>();
      final Pointer<FILETIME> user = calloc<FILETIME>();
      try {
        final int ok = GetProcessTimes(
          GetCurrentProcess(),
          creation,
          exit,
          kernel,
          user,
        );
        if (ok == 0) return null;
        final int kernelTicks = _filetimeToInt(kernel.ref);
        final int userTicks = _filetimeToInt(user.ref);
        // 100ns ticks → ns.
        return (kernelTicks + userTicks) * 100;
      } finally {
        calloc.free(creation);
        calloc.free(exit);
        calloc.free(kernel);
        calloc.free(user);
      }
    } catch (e) {
      AppLogger.instance.warn('cpu_spike: GetProcessTimes failed: $e');
      return null;
    }
  }

  int _filetimeToInt(FILETIME ft) {
    return (ft.dwHighDateTime << 32) | (ft.dwLowDateTime & 0xFFFFFFFF);
  }
}

/// One captured spike — schema-versioned for the agent contract.
class CpuSpikeEvent {
  const CpuSpikeEvent({
    required this.at,
    required this.cpuPctOneCore,
    required this.cpuPctAcrossAllCores,
    required this.baselinePct,
    required this.reason,
    required this.currentRssMb,
    required this.peakRssMb,
    required this.appUptimeSeconds,
    required this.activeServiceLabels,
    required this.childProcesses,
    required this.recentLogLines,
    this.classification,
  });

  final DateTime at;
  final double cpuPctOneCore;
  final double cpuPctAcrossAllCores;
  final double baselinePct;
  final String reason;
  final double currentRssMb;
  final double peakRssMb;
  final int appUptimeSeconds;
  final List<String> activeServiceLabels;
  final Map<String, int> childProcesses;
  final List<String> recentLogLines;
  final LagWorkClassification? classification;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': 1,
        'reportKind': 'six_vpn_cpu_spike',
        'docsRef': 'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md',
        'at': at.toIso8601String(),
        'cpuPctOneCore': double.parse(cpuPctOneCore.toStringAsFixed(2)),
        'cpuPctAcrossAllCores':
            double.parse(cpuPctAcrossAllCores.toStringAsFixed(2)),
        'baselinePct': double.parse(baselinePct.toStringAsFixed(2)),
        'reason': reason,
        'currentRssMb': double.parse(currentRssMb.toStringAsFixed(1)),
        'peakRssMb': double.parse(peakRssMb.toStringAsFixed(1)),
        'appUptimeSeconds': appUptimeSeconds,
        'activeServiceLabels': activeServiceLabels,
        'childProcesses': childProcesses,
        'recentLogLines': recentLogLines,
        if (classification != null) 'classification': classification!.toJson(),
        'agentHints': <String, Object?>{
          'note':
              'High `powershell` or `reg` counts indicate a child-process '
              'spawn-storm from a periodic probe. Cross-reference '
              'activeServiceLabels and recentLogLines to identify the '
              'culprit service. Then enforce CLAUDE.md PERFORMANCE BUDGET '
              'rules (no probe faster than 30s, no spawning probe faster '
              'than 5 minutes).',
          'primaryFiles': <String>[
            'mobile/lib/services/browser_block_health_monitor_service.dart',
            'mobile/lib/services/cursor_agent_snapshot_service.dart',
            'mobile/lib/services/windows_extension_policy_watchdog.dart',
            'mobile/lib/widgets/live_block_status_card.dart',
          ],
        },
      };
}
