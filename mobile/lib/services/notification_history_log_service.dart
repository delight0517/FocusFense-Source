import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'crash_journal_service.dart';

/// Append-only 7-day history of every 알림창(toast) **decision** this app
/// makes — not just the ones that actually popped up. For each notice-worthy
/// event we record whether the toast was shown or suppressed (and why:
/// cooldown, silent-bootstrap, no UI context, …) so a user report like
/// "왜 안 떴지?" / "왜 자꾸 뜨지?" can be answered from the log instead of
/// guesswork.
///
/// Same debug folder + jsonl/summary pattern as
/// `chat_schedule_audit_log_service.dart` — see that file for the
/// conventions this mirrors.
final class NotificationHistoryLogService {
  NotificationHistoryLogService._();
  static final NotificationHistoryLogService instance =
      NotificationHistoryLogService._();

  static const Duration kRetention = Duration(days: 7);
  static const int _kMaxMem = 500;
  static const Duration _kCompactInterval = Duration(hours: 1);

  final List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  DateTime? _lastCompactAt;
  bool _loaded = false;

  String get jsonlPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'notification_history.jsonl',
  );

  String get summaryPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'notification_history_summary.json',
  );

  /// Records one toast decision.
  ///
  /// [kind] — which notify* call site this came from (e.g. `browserKilled`,
  /// `appLaunchBlocked`, `externalExit`, `activityToast`).
  /// [target] — the app/browser display name the notice was about.
  /// [reason] — the human-readable Korean reason text shown to the user
  /// (or that would have been shown).
  /// [shown] — true if the toast/snackbar actually fired.
  /// [suppressReason] — when [shown] is false, why (`cooldown`,
  /// `silent_bootstrap`, `no_ui_context`).
  Future<void> record({
    required String kind,
    required String target,
    required String reason,
    required bool shown,
    String? suppressReason,
  }) async {
    await _ensureLoaded();
    final Map<String, Object?> entry = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'kind': kind,
      'target': target,
      'reason': reason,
      'shown': shown,
      if (!shown && suppressReason != null) 'suppressReason': suppressReason,
    };
    _entries.add(entry);
    if (_entries.length > _kMaxMem) {
      _entries.removeRange(0, _entries.length - _kMaxMem);
    }
    try {
      final Directory dir = Directory(
        CrashJournalService.instance.debugFolderPath,
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(jsonlPath).writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('notification_history append failed: $e');
    }
    unawaited(_maybeCompact());
    unawaited(_writeSummary());
  }

  /// All entries within [kRetention], oldest first.
  Future<List<Map<String, Object?>>> recentEntries() async {
    await _ensureLoaded();
    _pruneInMemory();
    return List<Map<String, Object?>>.unmodifiable(_entries);
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final File f = File(jsonlPath);
      if (await f.exists()) {
        final List<String> lines = await f.readAsLines();
        final DateTime cutoff = DateTime.now().subtract(kRetention);
        for (final String line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final Object? decoded = jsonDecode(line);
            if (decoded is Map<String, Object?>) {
              final DateTime? ts = DateTime.tryParse('${decoded['ts']}');
              if (ts != null && ts.isBefore(cutoff)) continue;
              _entries.add(decoded);
            }
          } catch (_) {
            // skip malformed line
          }
        }
        if (_entries.length > _kMaxMem) {
          _entries.removeRange(0, _entries.length - _kMaxMem);
        }
      }
    } catch (e) {
      AppLogger.instance.warn('notification_history load failed: $e');
    }
  }

  void _pruneInMemory() {
    final DateTime cutoff = DateTime.now().subtract(kRetention);
    _entries.removeWhere((Map<String, Object?> e) {
      final DateTime? ts = DateTime.tryParse('${e['ts']}');
      return ts == null || ts.isBefore(cutoff);
    });
  }

  /// Rewrites the jsonl file dropping entries older than [kRetention].
  /// Throttled so a burst of notices doesn't rewrite the file every time.
  Future<void> _maybeCompact() async {
    final DateTime now = DateTime.now();
    if (_lastCompactAt != null &&
        now.difference(_lastCompactAt!) < _kCompactInterval) {
      return;
    }
    _lastCompactAt = now;
    _pruneInMemory();
    try {
      final StringBuffer sb = StringBuffer();
      for (final Map<String, Object?> e in _entries) {
        sb.writeln(jsonEncode(e));
      }
      final File f = File(jsonlPath);
      final File tmp = File('$jsonlPath.tmp');
      await tmp.writeAsString(sb.toString(), flush: true);
      try {
        await tmp.rename(f.path);
      } catch (_) {
        await tmp.copy(f.path);
        await tmp.delete();
      }
    } catch (e) {
      AppLogger.instance.warn('notification_history compact failed: $e');
    }
  }

  Future<void> _writeSummary() async {
    try {
      final List<Map<String, Object?>> recent = _entries.reversed
          .take(100)
          .toList();
      final int shownCount = _entries.where((Map<String, Object?> e) => e['shown'] == true).length;
      final int suppressedCount = _entries.length - shownCount;
      final Map<String, Object?> summary = <String, Object?>{
        'updatedAt': DateTime.now().toIso8601String(),
        'retentionDays': kRetention.inDays,
        'entryCount': _entries.length,
        'shownCount': shownCount,
        'suppressedCount': suppressedCount,
        'jsonl': jsonlPath,
        'entries': recent,
      };
      final Directory dir = Directory(
        CrashJournalService.instance.debugFolderPath,
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(summaryPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(summary),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('notification_history summary write failed: $e');
    }
  }
}
