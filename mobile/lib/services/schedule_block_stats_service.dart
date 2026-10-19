import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'local_database.dart';

/// Per-schedule block trigger counts + estimated time saved.
final class ScheduleBlockStats {
  const ScheduleBlockStats({
    required this.triggerCount,
    required this.estimatedSavedSeconds,
  });

  final int triggerCount;
  final int estimatedSavedSeconds;

  static const ScheduleBlockStats empty = ScheduleBlockStats(
    triggerCount: 0,
    estimatedSavedSeconds: 0,
  );
}

/// Tracks how often each schedule's rules fired and estimates time saved.
final class ScheduleBlockStatsService {
  ScheduleBlockStatsService._();
  static final ScheduleBlockStatsService instance =
      ScheduleBlockStatsService._();

  static const String _kPrefsKey = 'schedule_block_stats_v1';

  Future<ScheduleBlockStats> statsFor(String scheduleId) async {
    final Map<String, ScheduleBlockStats> all = await _loadAll();
    return all[scheduleId] ?? ScheduleBlockStats.empty;
  }

  Future<void> recordBlockHit({
    required String rule,
    String? url,
  }) async {
    final List<String> scheduleIds =
        await _resolveScheduleIds(rule: rule, url: url);
    if (scheduleIds.isEmpty) return;

    final int saved = _estimateSavedSeconds(rule: rule, url: url);
    final Map<String, ScheduleBlockStats> all = await _loadAll();
    for (final String sid in scheduleIds) {
      final ScheduleBlockStats prev = all[sid] ?? ScheduleBlockStats.empty;
      all[sid] = ScheduleBlockStats(
        triggerCount: prev.triggerCount + 1,
        estimatedSavedSeconds: prev.estimatedSavedSeconds + saved,
      );
    }
    await _saveAll(all);
  }

  /// Active (foreground) usage seconds today for web hosts in this schedule.
  Future<int> activeUsageSecondsToday(String scheduleId) async {
    final List<Map<String, Object?>> domains =
        await LocalDatabase.instance.domainsForSchedule(scheduleId);
    final DateTime now = DateTime.now();
    int total = 0;
    for (final Map<String, Object?> d in domains) {
      final String host = '${d['host'] ?? ''}'.trim().toLowerCase();
      if (host.isEmpty) continue;
      final String subject = LocalDatabase.usageSubjectForWebHost(host);
      total += await LocalDatabase.instance.usageDailyFgTotal(subject, now);
    }
    // YouTube keywords → youtube.com host bucket
    final List<Map<String, Object?>> kws =
        await LocalDatabase.instance.keywordsForSchedule(scheduleId);
    bool hasYt = false;
    for (final Map<String, Object?> k in kws) {
      final String p = '${k['pattern'] ?? ''}'.toLowerCase();
      if (p.contains('youtube') || p.contains('youtu.be') || p.startsWith('@')) {
        hasYt = true;
        break;
      }
    }
    if (hasYt) {
      total += await LocalDatabase.instance.usageDailyFgTotal(
        LocalDatabase.usageSubjectForWebHost('youtube.com'),
        now,
      );
    }
    return total;
  }

  static String formatDuration(int seconds) {
    if (seconds <= 0) return '0분';
    if (seconds < 60) return '${seconds}초';
    final int m = seconds ~/ 60;
    if (m < 60) return '$m분';
    final int h = m ~/ 60;
    final int rm = m % 60;
    return rm == 0 ? '$h시간' : '$h시간 $rm분';
  }

  Future<List<String>> _resolveScheduleIds({
    required String rule,
    String? url,
  }) async {
    final String r = rule.trim().toLowerCase();
    final String u = (url ?? '').trim().toLowerCase();
    final Set<String> ids = <String>{};
    final Database db = await LocalDatabase.instance.database;

    final List<Map<String, Object?>> kws = await db.query(
      'keywords',
      where: 'deleted_at IS NULL AND enabled = 1 AND schedule_id IS NOT NULL',
    );
    for (final Map<String, Object?> row in kws) {
      final String pattern = '${row['pattern'] ?? ''}'.toLowerCase();
      if (pattern.isEmpty) continue;
      if (_matches(r, pattern) || (u.isNotEmpty && _matches(u, pattern))) {
        final String? sid = row['schedule_id'] as String?;
        if (sid != null && sid.isNotEmpty) ids.add(sid);
      }
    }

    final List<Map<String, Object?>> doms = await db.query(
      'domains',
      where: 'deleted_at IS NULL AND enabled = 1 AND schedule_id IS NOT NULL',
    );
    for (final Map<String, Object?> row in doms) {
      final String host = '${row['host'] ?? ''}'.toLowerCase();
      if (host.isEmpty) continue;
      if (_matches(r, host) || (u.isNotEmpty && u.contains(host))) {
        final String? sid = row['schedule_id'] as String?;
        if (sid != null && sid.isNotEmpty) ids.add(sid);
      }
    }
    return ids.toList();
  }

  static bool _matches(String haystack, String needle) {
    if (haystack.isEmpty || needle.isEmpty) return false;
    return haystack.contains(needle) || needle.contains(haystack);
  }

  static int _estimateSavedSeconds({required String rule, String? url}) {
    final String r = rule.toLowerCase();
    final String u = (url ?? '').toLowerCase();
    if (u.contains('watch?v=') || r.contains('watch?v=')) return 480;
    if (r.contains('youtube') || r.startsWith('@') || u.contains('youtube')) {
      return 300;
    }
    if (r.contains('.') && !r.contains(' ')) return 180;
    return 240;
  }

  Future<Map<String, ScheduleBlockStats>> _loadAll() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_kPrefsKey);
    if (raw == null || raw.isEmpty) return <String, ScheduleBlockStats>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, ScheduleBlockStats>{};
      final Map<String, ScheduleBlockStats> out = <String, ScheduleBlockStats>{};
      for (final MapEntry<dynamic, dynamic> e in decoded.entries) {
        if (e.value is! Map) continue;
        final Map<String, dynamic> m = Map<String, dynamic>.from(e.value as Map);
        out[e.key as String] = ScheduleBlockStats(
          triggerCount: (m['triggers'] as num?)?.toInt() ?? 0,
          estimatedSavedSeconds: (m['savedSeconds'] as num?)?.toInt() ?? 0,
        );
      }
      return out;
    } catch (_) {
      return <String, ScheduleBlockStats>{};
    }
  }

  Future<void> _saveAll(Map<String, ScheduleBlockStats> all) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Map<String, Object?> encoded = <String, Object?>{};
    for (final MapEntry<String, ScheduleBlockStats> e in all.entries) {
      encoded[e.key] = <String, Object?>{
        'triggers': e.value.triggerCount,
        'savedSeconds': e.value.estimatedSavedSeconds,
      };
    }
    await prefs.setString(_kPrefsKey, jsonEncode(encoded));
  }
}
