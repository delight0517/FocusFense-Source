import 'package:shared_preferences/shared_preferences.dart';

/// Separate friction layer for editing **usage caps** (not schedule locks).
///
/// Lets the user commit to a future moment (e.g. tomorrow morning) before
/// daily limits can be weakened or removed.
final class UsageLimitPolicyService {
  UsageLimitPolicyService._();
  static final UsageLimitPolicyService instance = UsageLimitPolicyService._();

  static const String _kUnlockUntilMs = 'usage_limits_edit_unlock_until_ms_v1';

  Future<DateTime?> editUnlockUntil() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? ms = prefs.getInt(_kUnlockUntilMs);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// `true` when edits to [usage_limits] rows are allowed.
  Future<bool> canEditLimitsNow() async {
    final DateTime? u = await editUnlockUntil();
    if (u == null) return true;
    return !DateTime.now().isBefore(u);
  }

  /// Unlocks editing from [when] onward (local wall clock).
  Future<void> scheduleEditUnlockFrom(DateTime when) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kUnlockUntilMs, when.millisecondsSinceEpoch);
  }

  /// Next local day at [hour]:[minute] (if that moment already passed today,
  /// uses tomorrow).
  Future<void> unlockTomorrowMorning({int hour = 6, int minute = 0}) async {
    final DateTime now = DateTime.now();
    DateTime t = DateTime(now.year, now.month, now.day, hour, minute);
    if (!t.isAfter(now)) {
      t = t.add(const Duration(days: 1));
    }
    await scheduleEditUnlockFrom(t);
  }

  Future<void> clearScheduledUnlock() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUnlockUntilMs);
  }
}
