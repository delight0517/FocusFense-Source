import 'package:shared_preferences/shared_preferences.dart';

/// App-wide daily usage ceiling (macOS foreground + extension web ingest).
final class GlobalUsageCapService {
  GlobalUsageCapService._();
  static final GlobalUsageCapService instance = GlobalUsageCapService._();

  static const String _kEnabled = 'global_usage_cap_enabled_v1';
  static const String _kMaxSeconds = 'global_usage_cap_max_seconds_v1';

  Future<bool> isEnabled() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabled) ?? false;
  }

  Future<int> maxSecondsPerDay() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_kMaxSeconds) ?? 7200).clamp(60, 86400);
  }

  Future<void> setEnabled(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
  }

  Future<void> setMaxSecondsPerDay(int seconds) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMaxSeconds, seconds.clamp(60, 86400));
  }

  Future<void> setMaxMinutes(int minutes) async {
    await setMaxSecondsPerDay(minutes.clamp(1, 1440) * 60);
  }

  Future<Map<String, Object?>> toBackupMap() async => <String, Object?>{
        'enabled': await isEnabled(),
        'maxSecondsPerDay': await maxSecondsPerDay(),
      };

  Future<void> restoreFromBackup(Object? raw) async {
    if (raw is! Map) return;
    final Map<String, Object?> m = Map<String, Object?>.from(raw);
    if (m.containsKey('enabled')) {
      await setEnabled(m['enabled'] == true || m['enabled'] == 1);
    }
    final Object? sec = m['maxSecondsPerDay'] ?? m['max_seconds_per_day'];
    if (sec is int) await setMaxSecondsPerDay(sec);
    if (sec is num) await setMaxSecondsPerDay(sec.toInt());
  }
}
