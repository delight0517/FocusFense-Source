import 'dart:async';
import 'dart:io';

import 'app_logger.dart';
import 'block_sync_service.dart';
import 'global_usage_cap_service.dart';
import 'game_daily_budget_service.dart';
import 'local_database.dart';
import 'mac_system_block_service.dart';
import 'usage_bucket_config_service.dart';

/// Quota policy for a site/app subject.
enum UsageQuotaMode {
  daily,
  rolling,
  session,

  /// Per-clock-hour foreground-only cap, active only during a nightly time
  /// window (e.g. 23:00–11:00, wrapping midnight). Background/minimized/
  /// unfocused playback is never capped under this mode — only being the
  /// visible/active tab or app window counts against the hourly budget.
  /// Enforcement is NOT a DNS block (that would also kill background
  /// playback) — see [UsageQuotaEnforcerService.fgLockedHosts].
  hourlyForegroundWindow,
}

/// Evaluates usage caps and applies **full DNS lock** via hosts when exceeded.
final class UsageQuotaEnforcerService {
  UsageQuotaEnforcerService._();
  static final UsageQuotaEnforcerService instance =
      UsageQuotaEnforcerService._();

  Timer? _timer;
  Set<String> _lockedHosts = <String>{};
  Set<String> _fgLockedHosts = <String>{};
  bool _globalCapActive = false;

  Set<String> get lockedHosts => Set<String>.unmodifiable(_lockedHosts);

  /// Hosts currently over their [UsageQuotaMode.hourlyForegroundWindow]
  /// budget. Unlike [lockedHosts] this is **not** DNS-blocked — background
  /// playback keeps working. The browser extension polls
  /// `/usage/lock-status` and only blocks the visible tab/window itself.
  Set<String> get fgLockedHosts => Set<String>.unmodifiable(_fgLockedHosts);

  bool isForegroundLocked(String host) =>
      _fgLockedHosts.contains(host.trim().toLowerCase());

  bool get globalCapActive => _globalCapActive;

  void start() {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    _timer?.cancel();
    unawaited(evaluateAndApply());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(evaluateAndApply());
    });
    AppLogger.instance.info('usage_quota_enforcer: started (30s)');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static UsageQuotaMode modeFromDb(Object? raw) {
    final String s = '${raw ?? 'daily'}'.toLowerCase();
    switch (s) {
      case 'rolling':
        return UsageQuotaMode.rolling;
      case 'session':
        return UsageQuotaMode.session;
      case 'hourly_fg_window':
        return UsageQuotaMode.hourlyForegroundWindow;
      default:
        return UsageQuotaMode.daily;
    }
  }

  /// True when [hour] (0–23) falls inside a nightly window that may wrap
  /// midnight (e.g. start=23, end=11 covers 23,0,1,...,10).
  static bool hourInNightlyWindow(int hour, int startHour, int endHour) {
    if (startHour < 0 || startHour > 23 || endHour < 0 || endHour > 23) {
      return false;
    }
    if (startHour == endHour) return true;
    if (startHour < endHour) return hour >= startHour && hour < endHour;
    return hour >= startHour || hour < endHour;
  }

  static String? hostFromSubject(String subject) {
    if (subject.startsWith('web|')) {
      return subject.substring(4).trim().toLowerCase();
    }
    return null;
  }

  /// Call after usage seconds are recorded (ingest / foreground poll).
  Future<void> onUsageRecorded(String subject, int seconds) async {
    if (seconds <= 0) return;
    final List<Map<String, Object?>> limits = await LocalDatabase.instance
        .usageLimitsForSubject(subject);
    for (final Map<String, Object?> row in limits) {
      if ((row['enabled'] as int? ?? 1) != 1) continue;
      if (modeFromDb(row['quota_mode']) != UsageQuotaMode.session) continue;
      final String id = row['id']! as String;
      await LocalDatabase.instance.addQuotaSessionSeconds(id, seconds);
    }
    await evaluateAndApply();
  }

  Future<void> evaluateAndApply() async {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    final DateTime now = DateTime.now();
    final Set<String> nextLocked = <String>{};
    final Set<String> nextFgLocked = <String>{};
    await GameDailyBudgetService.instance.refresh();
    final List<Map<String, Object?>> limits = await LocalDatabase.instance
        .usageLimits();

    final bool globalOn = await GlobalUsageCapService.instance.isEnabled();
    final int globalMax = await GlobalUsageCapService.instance
        .maxSecondsPerDay();
    final int grandTotal = await LocalDatabase.instance.usageDailyGrandTotal(
      now,
    );
    final bool globalExceeded = globalOn && grandTotal >= globalMax;
    final bool wasGlobal = _globalCapActive;
    _globalCapActive = globalExceeded;

    for (final Map<String, Object?> row in limits) {
      if ((row['enabled'] as int? ?? 1) != 1) continue;
      final String subject = row['subject']! as String;
      final String? host = hostFromSubject(subject);
      if (host == null || host.isEmpty) continue;

      if (globalExceeded) {
        // A blown global daily pool is always a full DNS lock, even for
        // hourly-foreground-window rows — that policy is stricter by design.
        nextLocked.add(host);
        AppLogger.instance.info(
          'usage_quota: LOCK $host (${row['display_label']}) (global cap)',
        );
        continue;
      }

      final UsageQuotaMode mode = modeFromDb(row['quota_mode']);
      if (mode == UsageQuotaMode.hourlyForegroundWindow) {
        final bool fgOver = await _isOverQuotaHourlyFgWindow(row, subject, now);
        if (fgOver) {
          nextFgLocked.add(host);
          AppLogger.instance.info(
            'usage_quota: FG-LOCK $host (${row['display_label']}) '
            'mode=hourly_fg_window (background stays unlimited)',
          );
        }
        continue;
      }

      final bool locked = await _isOverQuota(row, subject, now);
      if (locked) {
        nextLocked.add(host);
        AppLogger.instance.info(
          'usage_quota: LOCK $host (${row['display_label']}) '
          'mode=${row['quota_mode']}',
        );
      }
    }

    final bool changed =
        !_setEquals(_lockedHosts, nextLocked) || wasGlobal != globalExceeded;
    _lockedHosts = nextLocked;
    _fgLockedHosts = nextFgLocked;
    if (changed) {
      BlockSyncService.instance.requestApply();
    }
  }

  /// True when global daily pool is exhausted (ingest may skip crediting).
  Future<bool> isGlobalCapExceededNow() async {
    if (!await GlobalUsageCapService.instance.isEnabled()) return false;
    final DateTime now = DateTime.now();
    final int grand = await LocalDatabase.instance.usageDailyGrandTotal(now);
    final int cap = await GlobalUsageCapService.instance.maxSecondsPerDay();
    return grand >= cap;
  }

  bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final String x in a) {
      if (!b.contains(x)) return false;
    }
    return true;
  }

  Future<bool> _isOverQuota(
    Map<String, Object?> row,
    String subject,
    DateTime now,
  ) async {
    final int maxSec = (row['max_seconds_per_day'] as int?) ?? 900;
    final UsageQuotaMode mode = modeFromDb(row['quota_mode']);

    switch (mode) {
      case UsageQuotaMode.daily:
        final int used = await LocalDatabase.instance.usageDailyTotal(
          subject,
          now,
        );
        int cap = maxSec;
        if (await GlobalUsageCapService.instance.isEnabled()) {
          final int globalMax = await GlobalUsageCapService.instance
              .maxSecondsPerDay();
          cap = cap < globalMax ? cap : globalMax;
        }
        return used >= cap;
      case UsageQuotaMode.rolling:
        final int window =
            (row['window_seconds'] as int?) ??
            const Duration(hours: 3).inSeconds;
        final int since = now.millisecondsSinceEpoch - window * 1000;
        final int used = await LocalDatabase.instance.usageSecondsSince(
          subject,
          since,
        );
        return used >= maxSec;
      case UsageQuotaMode.session:
        final String id = row['id']! as String;
        final int period =
            (row['session_period_seconds'] as int?) ??
            const Duration(minutes: 30).inSeconds;
        final int sessionMax = (row['session_max_seconds'] as int?) ?? 0;
        final int cap = sessionMax > 0 ? sessionMax : maxSec;
        await LocalDatabase.instance.ensureQuotaSessionPeriod(
          limitId: id,
          periodSeconds: period,
          now: now,
        );
        final int used = await LocalDatabase.instance.quotaSessionUsedSeconds(
          id,
        );
        return used >= cap;
      case UsageQuotaMode.hourlyForegroundWindow:
        return _isOverQuotaHourlyFgWindow(row, subject, now);
    }
  }

  /// True when [subject] is currently inside its configured nightly window
  /// AND has used up its per-hour foreground budget for the current clock
  /// hour. Outside the window, or with no window configured, this is always
  /// false (no cap at all) — background usage is never counted here.
  Future<bool> _isOverQuotaHourlyFgWindow(
    Map<String, Object?> row,
    String subject,
    DateTime now,
  ) async {
    final int startHour = (row['window_start_hour'] as int?) ?? -1;
    final int endHour = (row['window_end_hour'] as int?) ?? -1;
    if (!hourInNightlyWindow(now.hour, startHour, endHour)) return false;
    final int cap = (row['max_seconds_per_hour'] as int?) ?? 900;
    // Force a real clock-hour bucket regardless of the user's global
    // aggregation-period setting — "1시간에 15분" means a calendar hour.
    final int bucketStart = UsageBucketConfigService.periodStartMs(now, 1);
    final int used = await LocalDatabase.instance.usageHourlyFgSecondsAt(
      subject,
      bucketStart,
    );
    return used >= cap;
  }

  /// Hosts merged into the managed block region (quota lock only).
  Future<List<String>> quotaLockedHostsExpanded() async {
    final Set<String> out = <String>{};
    for (final String host in _lockedHosts) {
      final String canonical = MacSystemBlockService.canonicalHost(host);
      if (canonical.isEmpty) continue;
      out.addAll(MacSystemBlockService.expandWithCommonSubdomains(canonical));
    }
    return out.toList()..sort();
  }

  /// UI: remaining seconds before lock (null if already locked or no limit).
  Future<QuotaStatus?> statusForLimit(Map<String, Object?> row) async {
    final String subject = row['subject']! as String;
    final DateTime now = DateTime.now();
    final int maxSec = (row['max_seconds_per_day'] as int?) ?? 900;
    final UsageQuotaMode mode = modeFromDb(row['quota_mode']);
    final bool locked = await _isOverQuota(row, subject, now);

    int used = 0;
    int cap = maxSec;
    switch (mode) {
      case UsageQuotaMode.daily:
        used = await LocalDatabase.instance.usageDailyTotal(subject, now);
        break;
      case UsageQuotaMode.rolling:
        final int window =
            (row['window_seconds'] as int?) ??
            const Duration(hours: 3).inSeconds;
        cap = maxSec;
        used = await LocalDatabase.instance.usageSecondsSince(
          subject,
          now.millisecondsSinceEpoch - window * 1000,
        );
        break;
      case UsageQuotaMode.session:
        final String id = row['id']! as String;
        final int period =
            (row['session_period_seconds'] as int?) ??
            const Duration(minutes: 30).inSeconds;
        final int sessionMax = (row['session_max_seconds'] as int?) ?? 0;
        cap = sessionMax > 0 ? sessionMax : maxSec;
        await LocalDatabase.instance.ensureQuotaSessionPeriod(
          limitId: id,
          periodSeconds: period,
          now: now,
        );
        used = await LocalDatabase.instance.quotaSessionUsedSeconds(id);
        break;
      case UsageQuotaMode.hourlyForegroundWindow:
        cap = (row['max_seconds_per_hour'] as int?) ?? 900;
        final int startHour = (row['window_start_hour'] as int?) ?? -1;
        final int endHour = (row['window_end_hour'] as int?) ?? -1;
        if (hourInNightlyWindow(now.hour, startHour, endHour)) {
          final int bucketStart = UsageBucketConfigService.periodStartMs(
            now,
            1,
          );
          used = await LocalDatabase.instance.usageHourlyFgSecondsAt(
            subject,
            bucketStart,
          );
        } else {
          used = 0;
        }
        break;
    }

    return QuotaStatus(
      usedSeconds: used,
      capSeconds: cap,
      locked: locked,
      mode: mode,
    );
  }
}

final class QuotaStatus {
  const QuotaStatus({
    required this.usedSeconds,
    required this.capSeconds,
    required this.locked,
    required this.mode,
  });

  final int usedSeconds;
  final int capSeconds;
  final bool locked;
  final UsageQuotaMode mode;

  int get remainingSeconds => (capSeconds - usedSeconds).clamp(0, capSeconds);
}
