import 'dart:async';

import 'app_logger.dart';
import 'app_operation_progress_service.dart';
import 'cpu_spike_detector_service.dart';

/// Tracks nested "heavy work" labels with start time and duration history.
///
/// Services wrap expensive tasks with [run] so CPU/lag/freeze captures know
/// exactly which pipeline step was active when the user felt lag.
final class WorkContextTracker {
  WorkContextTracker._();
  static final WorkContextTracker instance = WorkContextTracker._();

  static const int _kMaxCompleted = 40;

  final List<_ActiveFrame> _stack = <_ActiveFrame>[];
  final List<_CompletedWork> _completed = <_CompletedWork>[];

  /// Run [body] under [label]. Automatically registers with
  /// [CpuSpikeDetectorService] and logs start/finish + duration.
  Future<T> run<T>(String label, Future<T> Function() body) async {
    _begin(label);
    try {
      return await body();
    } catch (e, st) {
      AppLogger.instance.error(
        '[WorkContext] fail $label',
        error: e,
        stack: st,
      );
      rethrow;
    } finally {
      _end(label);
    }
  }

  void begin(String label) => _begin(label);

  void end(String label) => _end(label);

  void _begin(String label) {
    final _ActiveFrame frame = _ActiveFrame(label: label, startedAt: DateTime.now());
    _stack.add(frame);
    AppOperationProgressService.instance.beginFromWorkContext(label);
    CpuSpikeDetectorService.instance.noteActivity(label);
    AppLogger.instance.info(
      '[WorkContext] ▶ $label depth=${_stack.length}',
    );
  }

  void _end(String label) {
    final DateTime endedAt = DateTime.now();
    int idx = _stack.length - 1;
    while (idx >= 0 && _stack[idx].label != label) {
      idx--;
    }
    if (idx < 0) {
      AppOperationProgressService.instance.endFromWorkContext(label);
      CpuSpikeDetectorService.instance.clearActivity(label);
      return;
    }
    final _ActiveFrame frame = _stack.removeAt(idx);
    final int ms = endedAt.difference(frame.startedAt).inMilliseconds;
    _completed.insert(
      0,
      _CompletedWork(label: label, startedAt: frame.startedAt, durationMs: ms),
    );
    while (_completed.length > _kMaxCompleted) {
      _completed.removeLast();
    }
    AppOperationProgressService.instance.endFromWorkContext(label);
    CpuSpikeDetectorService.instance.clearActivity(label);
    AppLogger.instance.info('[WorkContext] ◀ $label ${ms}ms');
  }

  List<Map<String, Object?>> activeStackJson() {
    final DateTime now = DateTime.now();
    return _stack
        .map(
          (_ActiveFrame f) => <String, Object?>{
            'label': f.label,
            'startedAt': f.startedAt.toIso8601String(),
            'runningMs': now.difference(f.startedAt).inMilliseconds,
          },
        )
        .toList();
  }

  List<Map<String, Object?>> recentCompletedJson({int limit = 20}) {
    return _completed
        .take(limit)
        .map(
          (_CompletedWork w) => <String, Object?>{
            'label': w.label,
            'startedAt': w.startedAt.toIso8601String(),
            'durationMs': w.durationMs,
          },
        )
        .toList();
  }

  List<String> activeLabels() => _stack.map((_ActiveFrame f) => f.label).toList();

  /// True while any [run]/[begin] pipeline is active — background polls skip.
  bool get isBusy => _stack.isNotEmpty;
}

final class _ActiveFrame {
  _ActiveFrame({required this.label, required this.startedAt});
  final String label;
  final DateTime startedAt;
}

final class _CompletedWork {
  _CompletedWork({
    required this.label,
    required this.startedAt,
    required this.durationMs,
  });
  final String label;
  final DateTime startedAt;
  final int durationMs;
}
