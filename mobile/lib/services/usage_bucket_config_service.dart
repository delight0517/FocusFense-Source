import 'package:shared_preferences/shared_preferences.dart';

/// Local-midnight-aligned usage buckets: 1h = calendar hour; N>1 = N-hour blocks.
final class UsageBucketConfigService {
  UsageBucketConfigService._();
  static final UsageBucketConfigService instance = UsageBucketConfigService._();

  static const String _kPeriodHours = 'usage_period_hours_v1';

  Future<int> getPeriodHours() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int h = prefs.getInt(_kPeriodHours) ?? 1;
    return h.clamp(1, 24);
  }

  Future<void> setPeriodHours(int hours) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPeriodHours, hours.clamp(1, 24));
  }

  Future<void> restoreFromBackup(Object? raw) async {
    if (raw == null) return;
    if (raw is int) {
      await setPeriodHours(raw);
      return;
    }
    if (raw is num) {
      await setPeriodHours(raw.toInt());
    }
  }

  /// Start of the current bucket in local time (stored in `usage_hourly.hour_start_ms`).
  static int periodStartMs(DateTime nowLocal, int periodHours) {
    final int h = periodHours.clamp(1, 24);
    if (h == 1) {
      return DateTime(nowLocal.year, nowLocal.month, nowLocal.day, nowLocal.hour)
          .millisecondsSinceEpoch;
    }
    final DateTime midnight =
        DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
    final int elapsed = nowLocal.difference(midnight).inMilliseconds;
    final int periodMs = h * 3600 * 1000;
    final int idx = elapsed ~/ periodMs;
    return midnight.add(Duration(milliseconds: idx * periodMs)).millisecondsSinceEpoch;
  }
}
