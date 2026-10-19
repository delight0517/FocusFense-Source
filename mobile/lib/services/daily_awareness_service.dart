import '../data/daily_addiction_awareness_content.dart';

/// Picks today's "오늘의 이야기" line — purely local/offline, deterministic by
/// calendar date so it's stable across app restarts within the same day and
/// needs no network or server.
final class DailyAwarenessService {
  DailyAwarenessService._();
  static final DailyAwarenessService instance = DailyAwarenessService._();

  String messageFor(DateTime day) {
    final int dayIndex = day.year * 372 + day.month * 31 + day.day;
    final List<String> pool = kDailyAddictionAwarenessMessages;
    return pool[dayIndex % pool.length];
  }

  String todayMessage() => messageFor(DateTime.now());

  String get drugHeadline => kDrugZeroToleranceHeadline;
}
