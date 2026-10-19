import 'package:sqflite/sqflite.dart';

import '../models/active_app_block_entry.dart';
import '../models/block_app.dart';
import '../models/quick_block_user_bundle.dart';
import 'app_operation_progress_service.dart';
import 'local_database.dart';
import 'quick_block_session_service.dart';
import 'work_context_tracker.dart';

/// Resolves which apps are blocked now and **why** (schedule / quick / maintenance).
final class ActiveAppBlockRegistryService {
  ActiveAppBlockRegistryService._();
  static final ActiveAppBlockRegistryService instance =
      ActiveAppBlockRegistryService._();

  Future<List<ActiveAppBlockEntry>> activeEntriesNow() async {
    final DateTime now = DateTime.now();
    final Map<String, ActiveAppBlockEntry> byKey =
        <String, ActiveAppBlockEntry>{};

    final Database db = await LocalDatabase.instance.database;
    final List<Map<String, Object?>> activeSchedules = await LocalDatabase
        .instance
        .schedulesActiveNow(now);
    if (activeSchedules.isNotEmpty) {
      final Map<String, _ScheduleWindow> windows = await _scheduleWindows(
        activeSchedules,
        now,
      );
      final List<String> ids = activeSchedules
          .map((Map<String, Object?> r) => r['id']! as String)
          .toList();
      final String placeholders = List<String>.filled(
        ids.length,
        '?',
      ).join(',');
      final List<Map<String, Object?>> rows = await db.rawQuery(
        'SELECT name, bundle_id, schedule_id FROM blocked_apps '
        'WHERE deleted_at IS NULL AND schedule_id IN ($placeholders)',
        ids,
      );
      for (final Map<String, Object?> r in rows) {
        final BlockApp? app = LocalDatabase.blockedAppRowToBlockApp(r);
        if (app == null) continue;
        final String sid = '${r['schedule_id']}';
        final _ScheduleWindow? win = windows[sid];
        final ActiveAppBlockEntry entry = ActiveAppBlockEntry(
          app: app,
          context: AppBlockContext(
            source: AppBlockSource.schedule,
            scheduleLabels: <String>[if (win != null) win.name else '스케줄'],
            endsAt: win?.endsAt,
          ),
        );
        _mergeEntry(byKey, entry);
      }
    }

    final QuickBlockSession? quick = await QuickBlockSessionService.instance
        .activeSession();
    if (quick != null) {
      final DateTime until = DateTime.fromMillisecondsSinceEpoch(quick.untilMs);
      for (final BlockApp app
          in await QuickBlockSessionService.instance.activeBlockApps()) {
        final ActiveAppBlockEntry entry = ActiveAppBlockEntry(
          app: app,
          context: AppBlockContext(
            source: AppBlockSource.quickBlock,
            scheduleLabels: const <String>['빠른 차단'],
            endsAt: quick.releaseRequired ? null : until,
            browserReleaseHold: quick.releaseRequired,
          ),
        );
        _mergeEntry(byKey, entry);
      }
    }

    final AppBlockContext? maintenance = _maintenanceContext();
    if (maintenance != null) {
      for (final ActiveAppBlockEntry e in byKey.values.toList()) {
        byKey[e.dedupeKey] = ActiveAppBlockEntry(
          app: e.app,
          context: e.context.merge(maintenance),
        );
      }
    }

    return byKey.values.toList();
  }

  void _mergeEntry(
    Map<String, ActiveAppBlockEntry> byKey,
    ActiveAppBlockEntry entry,
  ) {
    final String key = entry.dedupeKey;
    final ActiveAppBlockEntry? prev = byKey[key];
    if (prev == null) {
      byKey[key] = entry;
      return;
    }
    byKey[key] = ActiveAppBlockEntry(
      app: prev.app,
      context: prev.context.merge(entry.context),
    );
  }

  AppBlockContext? _maintenanceContext() {
    if (!WorkContextTracker.instance.isBusy) return null;
    final AppOperationProgress? op =
        AppOperationProgressService.instance.primary;
    if (op == null) return null;
    return AppBlockContext(
      source: AppBlockSource.maintenance,
      scheduleLabels: const <String>[],
      maintenanceTitle: op.title,
      maintenanceDetail: op.step,
    );
  }

  Future<Map<String, _ScheduleWindow>> _scheduleWindows(
    List<Map<String, Object?>> schedules,
    DateTime now,
  ) async {
    final Map<String, _ScheduleWindow> out = <String, _ScheduleWindow>{};
    final int today = now.weekday - 1;
    final int minuteOfDay = now.hour * 60 + now.minute;

    for (final Map<String, Object?> s in schedules) {
      final String id = s['id']! as String;
      final String name = (s['name'] as String?)?.trim().isNotEmpty == true
          ? (s['name'] as String).trim()
          : '스케줄';
      final List<Map<String, Object?>> slots = await LocalDatabase.instance
          .slotsForSchedule(id);
      int? endMinute;
      for (final Map<String, Object?> slot in slots) {
        if ((slot['day'] as int?) != today) continue;
        final int st = slot['start_minute']! as int;
        final int en = slot['end_minute']! as int;
        final bool hit = st == 0 && en >= 1440
            ? true
            : minuteOfDay >= st && minuteOfDay < en;
        if (hit) {
          endMinute = endMinute == null
              ? en
              : (en > endMinute ? en : endMinute);
        }
      }
      endMinute ??= _legacyEndMinute(s, minuteOfDay);
      out[id] = _ScheduleWindow(
        name: name,
        endsAt: endMinute == null ? null : _endDateTime(now, endMinute),
      );
    }
    return out;
  }

  int? _legacyEndMinute(Map<String, Object?> s, int minuteOfDay) {
    final int start = s['start_minute']! as int;
    final int end = s['end_minute']! as int;
    if (start == end) return end >= 1440 ? 1440 : end;
    if (start < end) {
      if (minuteOfDay >= start && minuteOfDay < end) return end;
    } else {
      if (minuteOfDay >= start || minuteOfDay < end) return end;
    }
    return null;
  }

  DateTime _endDateTime(DateTime now, int endMinute) {
    if (endMinute >= 1440) {
      return DateTime(now.year, now.month, now.day, 23, 59);
    }
    return DateTime(
      now.year,
      now.month,
      now.day,
      endMinute ~/ 60,
      endMinute % 60,
    );
  }
}

final class _ScheduleWindow {
  const _ScheduleWindow({required this.name, this.endsAt});
  final String name;
  final DateTime? endsAt;
}
