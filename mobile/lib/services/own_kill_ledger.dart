import 'dart:collection';

/// Records every browser/app termination that **this app** initiates, so
/// [BrowserExitWatcherService] can tell self-inflicted exits apart from
/// "Chrome just disappeared for no visible reason" cases (system crash,
/// AV kill, user closing the window, OS update).
///
/// Each kill site MUST `stamp(...)` right before invoking taskkill /
/// Stop-Process. The watcher reads `wasOursRecently(pid)` when it
/// notices a PID disappeared from the process snapshot.
///
/// Lifetime windows:
///   * `stamp(pid)` entries live ~3 minutes — long enough for the watcher's
///     30 s tick to catch the exit and for a slow chrome.exe child-tree
///     shutdown to settle, short enough not to swallow a later external
///     kill of a reused PID.
///   * `stampImage(exe)` entries live ~90 seconds — covers `taskkill /F /IM`
///     calls where we don't know individual PIDs.
final class OwnKillLedger {
  OwnKillLedger._();
  static final OwnKillLedger instance = OwnKillLedger._();

  static const Duration _pidTtl = Duration(minutes: 3);
  static const Duration _imageTtl = Duration(seconds: 90);
  static const int _maxEntries = 256;

  final LinkedHashMap<int, _KillEntry> _byPid =
      LinkedHashMap<int, _KillEntry>();
  final LinkedHashMap<String, _KillEntry> _byImage =
      LinkedHashMap<String, _KillEntry>();
  final List<_KillEntry> _recent = <_KillEntry>[];

  /// Stamps a kill we're about to perform on a specific PID.
  /// [reason] flows into the user-facing notice ("스케줄: 평일 14:00", etc).
  /// [reasonKey] is a short stable identifier for telemetry/debounce.
  void stampPid({
    required int pid,
    required String imageName,
    required String reason,
    required String reasonKey,
    String? scheduleLabel,
  }) {
    final _KillEntry e = _KillEntry(
      pid: pid,
      imageName: imageName.toLowerCase(),
      reason: reason,
      reasonKey: reasonKey,
      scheduleLabel: scheduleLabel,
      at: DateTime.now(),
    );
    _byPid[pid] = e;
    _recent.insert(0, e);
    _trim();
  }

  /// Stamps a kill targeted by image name (taskkill /F /IM chrome.exe).
  /// The watcher consults this when a PID disappears whose image matches.
  void stampImage({
    required String imageName,
    required String reason,
    required String reasonKey,
    String? scheduleLabel,
  }) {
    final String key = imageName.toLowerCase();
    final _KillEntry e = _KillEntry(
      pid: null,
      imageName: key,
      reason: reason,
      reasonKey: reasonKey,
      scheduleLabel: scheduleLabel,
      at: DateTime.now(),
    );
    _byImage[key] = e;
    _recent.insert(0, e);
    _trim();
  }

  /// True when [pid] (image [imageName]) was killed by this app in the
  /// last [_pidTtl] (per-PID stamp) or [_imageTtl] (whole-image stamp).
  bool wasOursRecently({required int pid, required String imageName}) {
    final DateTime now = DateTime.now();
    final _KillEntry? pidHit = _byPid[pid];
    if (pidHit != null && now.difference(pidHit.at) <= _pidTtl) {
      return true;
    }
    final _KillEntry? imgHit = _byImage[imageName.toLowerCase()];
    if (imgHit != null && now.difference(imgHit.at) <= _imageTtl) {
      return true;
    }
    return false;
  }

  /// Latest matching reason if recorded, else null. The watcher uses this
  /// to log `we killed it because [reason]` instead of double-firing the
  /// external-cause notice.
  OwnKillReason? reasonFor({required int pid, required String imageName}) {
    final DateTime now = DateTime.now();
    final _KillEntry? pidHit = _byPid[pid];
    if (pidHit != null && now.difference(pidHit.at) <= _pidTtl) {
      return OwnKillReason._(pidHit);
    }
    final _KillEntry? imgHit = _byImage[imageName.toLowerCase()];
    if (imgHit != null && now.difference(imgHit.at) <= _imageTtl) {
      return OwnKillReason._(imgHit);
    }
    return null;
  }

  /// Diagnostic snapshot — last [max] entries (newest first).
  List<OwnKillReason> recent({int max = 20}) {
    return _recent
        .take(max)
        .map((_KillEntry e) => OwnKillReason._(e))
        .toList(growable: false);
  }

  void clearForTest() {
    _byPid.clear();
    _byImage.clear();
    _recent.clear();
  }

  void _trim() {
    final DateTime now = DateTime.now();
    _byPid.removeWhere(
      (_, _KillEntry e) => now.difference(e.at) > _pidTtl,
    );
    _byImage.removeWhere(
      (_, _KillEntry e) => now.difference(e.at) > _imageTtl,
    );
    while (_recent.length > _maxEntries) {
      _recent.removeLast();
    }
  }
}

final class OwnKillReason {
  OwnKillReason._(_KillEntry e)
      : pid = e.pid,
        imageName = e.imageName,
        reason = e.reason,
        reasonKey = e.reasonKey,
        scheduleLabel = e.scheduleLabel,
        at = e.at;

  final int? pid;
  final String imageName;
  final String reason;
  final String reasonKey;
  final String? scheduleLabel;
  final DateTime at;
}

final class _KillEntry {
  _KillEntry({
    required this.pid,
    required this.imageName,
    required this.reason,
    required this.reasonKey,
    required this.scheduleLabel,
    required this.at,
  });

  final int? pid;
  final String imageName;
  final String reason;
  final String reasonKey;
  final String? scheduleLabel;
  final DateTime at;
}
