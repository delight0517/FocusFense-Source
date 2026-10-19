import 'dart:convert';

import 'app_logger.dart';
import 'local_database.dart';

/// Export schedules, rules, and configurations to JSON/txt formats.
final class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  /// Export all schedules with their domains/keywords to JSON.
  Future<String> exportSchedulesToJson() async {
    AppLogger.instance.info('exporting all schedules to JSON');
    try {
      final db = LocalDatabase.instance;
      final schedules = await db.schedules();

      final List<Map<String, dynamic>> exported = [];
      for (final sched in schedules) {
        final id = sched['id'] as String;
        final domains = await db.domainsForSchedule(id);
        final keywords = await db.keywordsForSchedule(id);

        exported.add({
          'schedule': sched,
          'domains': domains,
          'keywords': keywords,
        });
      }

      return jsonEncode(exported);
    } catch (e) {
      AppLogger.instance.error('failed to export schedules to JSON', error: e);
      rethrow;
    }
  }

  /// Export domains from a schedule as plaintext (one per line).
  Future<String> exportScheduleDomainsAsText(String scheduleId) async {
    AppLogger.instance.info('exporting domains from schedule $scheduleId as text');
    try {
      final db = LocalDatabase.instance;
      final sched = await db.scheduleById(scheduleId);
      if (sched == null) throw Exception('Schedule not found');

      final domains = await db.domainsForSchedule(scheduleId);
      final lines = <String>[];

      // Add header
      lines.add('# Schedule: ${sched['name']}');
      lines.add('# Generated: ${DateTime.now()}');
      lines.add('# Domains: ${domains.length}');
      lines.add('');

      // Add domains
      for (final d in domains) {
        if ((d['enabled'] as int?) == 1) {
          lines.add(d['host'] as String);
        }
      }

      return lines.join('\n');
    } catch (e) {
      AppLogger.instance.error('failed to export domains as text', error: e);
      rethrow;
    }
  }

  /// Export all enabled domains across all schedules.
  Future<String> exportAllDomainsAsText() async {
    AppLogger.instance.info('exporting all domains as text');
    try {
      final db = LocalDatabase.instance;
      final schedules = await db.schedules();
      final Set<String> allDomains = <String>{};

      for (final sched in schedules) {
        final id = sched['id'] as String;
        final domains = await db.domainsForSchedule(id);
        for (final d in domains) {
          if ((d['enabled'] as int?) == 1) {
            allDomains.add(d['host'] as String);
          }
        }
      }

      final lines = <String>[];
      lines.add('# All enabled domains');
      lines.add('# Generated: ${DateTime.now()}');
      lines.add('# Total: ${allDomains.length}');
      lines.add('');

      final sorted = allDomains.toList()..sort();
      lines.addAll(sorted);

      return lines.join('\n');
    } catch (e) {
      AppLogger.instance.error('failed to export all domains', error: e);
      rethrow;
    }
  }
}
