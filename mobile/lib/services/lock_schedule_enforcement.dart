import '../models/rules_meta.dart';
import 'local_database.dart';
import 'lock_policy_service.dart';
import 'trusted_time_service.dart';

/// Applies night-schedule auto-focus when the wall clock is inside the window.
///
/// Uses [TrustedTimeService.now] — an NTP-anchored monotonic clock — so a user
/// who drags the system clock back to noon during a 22:00–06:00 block can't
/// "skip" the window. If the local clock is detected as tampered, we engage
/// the lock unconditionally regardless of what the wallclock reports.
Future<void> enforceLockScheduleIfNeeded() async {
  final LockPolicyService lock = LockPolicyService.instance;
  final ScheduleConfig cfg = await lock.loadSchedule();
  final TrustedTimeService time = TrustedTimeService.instance;
  final DateTime nowLocal = time.now(); // updates isClockTampered as a side-effect
  final bool inWindow = lock.isWithinScheduleNow(cfg, nowLocal);
  final bool tampered = time.isClockTampered;
  // @incident: clock_tamper_schedule_bypass — clock-tamper flag defeats a
  // schedule-bypass technique (rolling system clock back); do not gate this
  // on anything else.
  if (!inWindow && !tampered) return;
  final RulesMeta meta = await LocalDatabase.instance.rulesMeta();
  if (!meta.focusEnabled) {
    await LocalDatabase.instance
        .saveRulesMeta(meta.copyWith(focusEnabled: true));
  }
}
