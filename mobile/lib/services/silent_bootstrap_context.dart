/// While true, automated paths must not spawn UAC / blocking confirm dialogs.
abstract final class SilentBootstrapContext {
  /// Safety valve — if `endPostRebuild()` is never reached (e.g. a hang or
  /// process-spawn storm inside `PostRebuildBootstrapService.runIfNeeded()`),
  /// don't suppress user-facing notices forever. Observed 2026-07-06:
  /// `notification_history.jsonl` showed every browser-exit event tagged
  /// `suppressReason: silent_bootstrap` for 20+ minutes across a process
  /// restart because the "heavy" post-rebuild pass never finished (see
  /// project_2026_07_06_four_bugs_fix / firefox-close-investigation memory).
  /// 3 minutes comfortably covers a normal heavy pass; anything longer means
  /// the pipeline is stuck, and suppression should lapse rather than hide
  /// every close reason indefinitely.
  static const Duration _maxSuppression = Duration(minutes: 3);

  static DateTime? _suppressedSince;

  static bool get _active {
    final DateTime? since = _suppressedSince;
    if (since == null) return false;
    return DateTime.now().difference(since) < _maxSuppression;
  }

  static bool get suppressElevated => _active;
  static bool get suppressUserPrompts => _active;

  static void beginPostRebuild() {
    _suppressedSince = DateTime.now();
  }

  static void endPostRebuild() {
    _suppressedSince = null;
  }
}
