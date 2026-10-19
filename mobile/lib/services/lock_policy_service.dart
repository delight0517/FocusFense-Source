import 'package:shared_preferences/shared_preferences.dart';

import '../models/rules_meta.dart';
import 'unlock_code_vault_service.dart';

final class ScheduleConfig {
  const ScheduleConfig({
    required this.enabled,
    required this.startMinuteOfDay,
    required this.endMinuteOfDay,
    this.daysMask = kScheduleDaysMaskAll,
  });

  final bool enabled;
  final int startMinuteOfDay;
  final int endMinuteOfDay;

  /// Bit i set = Monday+i participates (same as `schedule_slots.day`: 0=Mon..6=Sun).
  final int daysMask;
}

/// All weekdays — bit 0 Mon … bit 6 Sun.
const int kScheduleDaysMaskAll = 0x7F;

final class LockPolicyService {
  LockPolicyService._();
  static final LockPolicyService instance = LockPolicyService._();

  static const String _kScheduleEnabled = 'schedule_enabled_v1';
  static const String _kScheduleStartMinute = 'schedule_start_minute_v1';
  static const String _kScheduleEndMinute = 'schedule_end_minute_v1';
  static const String _kScheduleDaysMask = 'schedule_days_mask_v1';
  static const String _kGraceExpiresAt = 'lock_grace_expires_at_v1';
  static const Duration kGraceWindow = Duration(minutes: 5);

  Future<ScheduleConfig> loadSchedule() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool enabled = prefs.getBool(_kScheduleEnabled) ?? false;
    final int start = prefs.getInt(_kScheduleStartMinute) ?? (22 * 60);
    final int end = prefs.getInt(_kScheduleEndMinute) ?? (7 * 60);
    final int rawMask = prefs.getInt(_kScheduleDaysMask) ?? kScheduleDaysMaskAll;
    final int mask = (rawMask & kScheduleDaysMaskAll);
    return ScheduleConfig(
      enabled: enabled,
      startMinuteOfDay: start,
      endMinuteOfDay: end,
      daysMask: mask == 0 ? kScheduleDaysMaskAll : mask,
    );
  }

  Future<void> saveSchedule(ScheduleConfig cfg) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    int mask = cfg.daysMask & kScheduleDaysMaskAll;
    if (mask == 0) mask = kScheduleDaysMaskAll;
    await prefs.setBool(_kScheduleEnabled, cfg.enabled);
    await prefs.setInt(_kScheduleStartMinute, cfg.startMinuteOfDay);
    await prefs.setInt(_kScheduleEndMinute, cfg.endMinuteOfDay);
    await prefs.setInt(_kScheduleDaysMask, mask);
  }

  Future<Map<String, Object?>> toBackupMap() async {
    final ScheduleConfig cfg = await loadSchedule();
    return <String, Object?>{
      'enabled': cfg.enabled,
      'startMinuteOfDay': cfg.startMinuteOfDay,
      'endMinuteOfDay': cfg.endMinuteOfDay,
      'daysMask': cfg.daysMask,
    };
  }

  Future<void> restoreFromBackupMap(Object? raw) async {
    if (raw is! Map) return;
    final Map<String, Object?> m = raw.map<String, Object?>(
      (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
    );
    final bool enabled = m['enabled'] == true;
    final int start = _asInt(m['startMinuteOfDay'], 22 * 60);
    final int end = _asInt(m['endMinuteOfDay'], 7 * 60);
    int mask = _asInt(m['daysMask'], kScheduleDaysMaskAll) & kScheduleDaysMaskAll;
    if (mask == 0) mask = kScheduleDaysMaskAll;
    await saveSchedule(ScheduleConfig(
      enabled: enabled,
      startMinuteOfDay: start,
      endMinuteOfDay: end,
      daysMask: mask,
    ));
  }

  static int _asInt(Object? v, [int fallback = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    if (v is bool) return v ? 1 : 0;
    return fallback;
  }

  bool isLockedByPolicy(RulesMeta meta) => meta.unlockPinRequired && meta.focusEnabled;

  /// Start a one-shot 5-minute grace window during which `isEffectivelyLocked`
  /// returns false even though the underlying lock is still on. The window is
  /// wall-clock based, so leaving and re-entering the Settings screen does NOT
  /// re-lock the user — they get the full 5 minutes from the moment they tap
  /// "Unlock for 5 minutes".
  Future<void> startGrace() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int expiry = DateTime.now()
        .add(kGraceWindow)
        .millisecondsSinceEpoch;
    await prefs.setInt(_kGraceExpiresAt, expiry);
  }

  Future<void> clearGrace() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kGraceExpiresAt);
  }

  Future<DateTime?> graceExpiresAt() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? ms = prefs.getInt(_kGraceExpiresAt);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<bool> isInGrace() async {
    // Vault-driven unlock takes precedence: if the user verified their
    // delay-and-reveal code, treat the settings as unlocked for the full
    // unlock window (10 min by default — see UnlockCodeVaultService).
    if (await UnlockCodeVaultService.instance.isUnlocked()) return true;
    final DateTime? exp = await graceExpiresAt();
    if (exp == null) return false;
    return DateTime.now().isBefore(exp);
  }

  /// True when the user is locked AND not currently in a grace window.
  Future<bool> isEffectivelyLocked(RulesMeta meta) async {
    if (!isLockedByPolicy(meta)) return false;
    return !(await isInGrace());
  }

  bool isWithinScheduleNow(ScheduleConfig cfg, DateTime now) {
    if (!cfg.enabled) return false;
    final int dow = now.weekday - 1;
    final int bit = 1 << dow;
    final int mask = cfg.daysMask & kScheduleDaysMaskAll;
    if (mask != 0 && (mask & bit) == 0) return false;
    final int m = now.hour * 60 + now.minute;
    if (cfg.startMinuteOfDay == cfg.endMinuteOfDay) return true;
    if (cfg.startMinuteOfDay < cfg.endMinuteOfDay) {
      return m >= cfg.startMinuteOfDay && m < cfg.endMinuteOfDay;
    }
    return m >= cfg.startMinuteOfDay || m < cfg.endMinuteOfDay;
  }
}
