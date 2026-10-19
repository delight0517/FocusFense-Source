import 'dart:async';

import 'package:flutter/foundation.dart';

/// Global in-app progress — every long task reports title, step, % and ETA.
final class AppOperationProgressService {
  AppOperationProgressService._();
  static final AppOperationProgressService instance =
      AppOperationProgressService._();

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final Map<String, AppOperationProgress> _active =
      <String, AppOperationProgress>{};
  int _idSeq = 0;

  List<AppOperationProgress> get operations =>
      List<AppOperationProgress>.unmodifiable(_active.values);

  AppOperationProgress? get primary {
    if (_active.isEmpty) return null;
    AppOperationProgress? best;
    for (final AppOperationProgress op in _active.values) {
      if (best == null) {
        best = op;
        continue;
      }
      if (op.explicit && !best.explicit) {
        best = op;
        continue;
      }
      if (op.updatedAt.isAfter(best.updatedAt)) best = op;
    }
    return best;
  }

  bool get hasActive => _active.isNotEmpty;

  /// Starts a tracked operation. Returns [id] for [update]/[end].
  String begin({
    required String title,
    String? step,
    double fraction = 0,
    Duration? estimatedTotal,
    String? id,
    bool explicit = true,
  }) {
    final String opId = id ?? 'op_${++_idSeq}';
    final DateTime now = DateTime.now();
    _active[opId] = AppOperationProgress(
      id: opId,
      title: title,
      step: step ?? title,
      fraction: fraction.clamp(0.0, 1.0),
      startedAt: now,
      updatedAt: now,
      estimatedTotal: estimatedTotal,
      explicit: explicit,
      indeterminate: false,
    );
    revision.value++;
    return opId;
  }

  /// Background [WorkContextTracker] pipelines — indeterminate until explicit %.
  void beginFromWorkContext(String label) {
    final String opId = 'wc:$label';
    if (_active.containsKey(opId)) return;
    final DateTime now = DateTime.now();
    _active[opId] = AppOperationProgress(
      id: opId,
      title: _humanizeWorkLabel(label),
      step: '실행 중…',
      fraction: 0,
      startedAt: now,
      updatedAt: now,
      explicit: false,
      indeterminate: true,
    );
    revision.value++;
  }

  void endFromWorkContext(String label) {
    end('wc:$label');
  }

  void update(
    String id, {
    String? title,
    String? step,
    double? fraction,
    Duration? estimatedTotal,
    bool? indeterminate,
  }) {
    final AppOperationProgress? cur = _active[id];
    if (cur == null) return;
    _active[id] = cur.copyWith(
      title: title,
      step: step,
      fraction: fraction,
      estimatedTotal: estimatedTotal,
      updatedAt: DateTime.now(),
      indeterminate: indeterminate,
    );
    revision.value++;
  }

  void end(String id) {
    if (_active.remove(id) != null) {
      revision.value++;
    }
  }

  /// Convenience: run async work with automatic begin/end.
  Future<T> run<T>({
    required String title,
    required Future<T> Function(AppOperationHandle handle) body,
    Duration? estimatedTotal,
  }) async {
    final AppOperationHandle handle = AppOperationHandle._(
      service: this,
      id: begin(title: title, estimatedTotal: estimatedTotal),
    );
    try {
      return await body(handle);
    } finally {
      handle.done();
    }
  }

  static String _humanizeWorkLabel(String label) {
    const Map<String, String> map = <String, String>{
      'autonomous_apply.full_pipeline': '자율 점검·차단 적용',
      'universal_browser_block.syncNow': '브라우저 URL 차단 동기화',
      'browser_block_health.probe': '브라우저 차단 상태 점검',
      'post_rebuild_bootstrap': '리빌드 후 초기 설정',
    };
    return map[label] ?? label.replaceAll('.', ' · ');
  }
}

final class AppOperationHandle {
  AppOperationHandle._({required AppOperationProgressService service, required String id})
      : _service = service,
        id = id;

  final AppOperationProgressService _service;
  final String id;

  void step(String stepLabel, double fraction) {
    _service.update(id, step: stepLabel, fraction: fraction);
  }

  void indeterminate(String stepLabel) {
    _service.update(id, step: stepLabel, indeterminate: true);
  }

  void done() => _service.end(id);
}

final class AppOperationProgress {
  const AppOperationProgress({
    required this.id,
    required this.title,
    required this.step,
    required this.fraction,
    required this.startedAt,
    required this.updatedAt,
    this.estimatedTotal,
    this.explicit = true,
    this.indeterminate = false,
  });

  final String id;
  final String title;
  final String step;
  final double fraction;
  final DateTime startedAt;
  final DateTime updatedAt;
  final Duration? estimatedTotal;
  final bool explicit;
  final bool indeterminate;

  int get percent => (fraction.clamp(0, 1) * 100).round();

  Duration get elapsed => DateTime.now().difference(startedAt);

  Duration? get estimatedRemaining {
    if (indeterminate || fraction >= 0.995) return null;
    if (estimatedTotal != null) {
      final Duration left = estimatedTotal! - elapsed;
      return left.isNegative ? Duration.zero : left;
    }
    if (fraction < 0.03) return null;
    final int totalMs = (elapsed.inMilliseconds / fraction).round();
    final int leftMs = totalMs - elapsed.inMilliseconds;
    if (leftMs <= 0) return Duration.zero;
    return Duration(milliseconds: leftMs);
  }

  Duration? get estimatedTotalDuration {
    if (estimatedTotal != null) return estimatedTotal;
    if (fraction < 0.03) return null;
    return Duration(
      milliseconds: (elapsed.inMilliseconds / fraction).round(),
    );
  }

  String get etaLabel => AppOperationProgressFormat.etaKo(estimatedRemaining);

  String get totalLabel =>
      AppOperationProgressFormat.totalKo(estimatedTotalDuration);

  String get summaryLine {
    if (indeterminate) {
      return '$title — $step · $totalLabel';
    }
    return '$title — $step · $percent% · $etaLabel';
  }

  AppOperationProgress copyWith({
    String? title,
    String? step,
    double? fraction,
    DateTime? updatedAt,
    Duration? estimatedTotal,
    bool? explicit,
    bool? indeterminate,
  }) {
    return AppOperationProgress(
      id: id,
      title: title ?? this.title,
      step: step ?? this.step,
      fraction: fraction ?? this.fraction,
      startedAt: startedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      estimatedTotal: estimatedTotal ?? this.estimatedTotal,
      explicit: explicit ?? this.explicit,
      indeterminate: indeterminate ?? this.indeterminate,
    );
  }
}

abstract final class AppOperationProgressFormat {
  static String etaKo(Duration? remaining) {
    if (remaining == null) return '예상 시간 계산 중…';
    if (remaining <= Duration.zero) return '곧 완료';
    if (remaining.inHours >= 1) {
      return '약 ${remaining.inHours}시간 ${remaining.inMinutes % 60}분 남음';
    }
    if (remaining.inMinutes >= 1) {
      return '약 ${remaining.inMinutes}분 ${remaining.inSeconds % 60}초 남음';
    }
    return '약 ${remaining.inSeconds}초 남음';
  }

  static String totalKo(Duration? total) {
    if (total == null) return '예상 총 시간 계산 중';
    if (total.inMinutes >= 2) return '예상 총 ${total.inMinutes}분';
    return '예상 총 ${total.inSeconds}초';
  }
}
