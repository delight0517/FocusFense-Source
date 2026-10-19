import 'dart:io';

import 'package:uuid/uuid.dart';

import '../utils/cold_turkey_rule_parser.dart';
import 'app_logger.dart';
import 'local_database.dart';

/// Result of importing a Cold Turkey / blocklist file into a schedule.
final class ColdTurkeyImportResult {
  const ColdTurkeyImportResult({
    required this.scheduleId,
    required this.domainsImported,
    required this.keywordsImported,
    required this.domainRules,
    required this.pathRules,
    required this.urlPatternRules,
    required this.skipped,
  });

  final String scheduleId;
  final int domainsImported;
  final int keywordsImported;
  final int domainRules;
  final int pathRules;
  final int urlPatternRules;
  final int skipped;

  int get totalImported => domainsImported + keywordsImported;
}

/// Cold Turkey Blocker / generic blocklist import.
///
/// Three enforcement layers (see `docs/SCHEDULE_URL_KEYWORD_BLOCK_BLUEPRINT.md`):
///   * **Domain** → `domains` table → `/etc/hosts` (macOS/Windows)
///   * **Path / URL pattern** → `keywords` table → browser extension URL match
final class ImportService {
  ImportService._();
  static final ImportService instance = ImportService._();

  /// Parses a blocklist file into classified rules (domain / path / wildcard).
  Future<ColdTurkeyImportBatch> parseColdTurkeyFile(String filePath) async {
    AppLogger.instance.info('parsing blocklist file: $filePath');
    final File file = File(filePath);
    final List<String> lines = await file.readAsLines();
    final ColdTurkeyImportBatch batch = parseColdTurkeyLines(lines);
    AppLogger.instance.info(
      'parsed ${batch.rules.length} rules '
      '(domains=${batch.domainCount} path=${batch.pathCount} '
      'urlPattern=${batch.urlPatternCount}) from $filePath',
    );
    return batch;
  }

  /// Legacy API — returns domain hosts only. Prefer [parseColdTurkeyFile].
  Future<List<String>> parseHostsFile(String filePath) async {
    final ColdTurkeyImportBatch batch = await parseColdTurkeyFile(filePath);
    return batch.domainHosts;
  }

  /// Imports [batch] into a new schedule (disabled by default).
  Future<ColdTurkeyImportResult> importBatchToDB({
    required ColdTurkeyImportBatch batch,
    required String scheduleName,
  }) async {
    AppLogger.instance.info(
      'importing batch: domains=${batch.domainCount} '
      'keywords=${batch.pathCount + batch.urlPatternCount} → $scheduleName',
    );
    final LocalDatabase db = LocalDatabase.instance;
    final String scheduleId = const Uuid().v4();
    await db.upsertSchedule(
      id: scheduleId,
      name: scheduleName,
      startMinute: 0,
      endMinute: 1440,
      daysMask: 127,
      enabled: false,
    );

    int domainsImported = 0;
    int keywordsImported = 0;
    int skipped = 0;

    for (final ColdTurkeyParsedRule rule in batch.rules) {
      try {
        switch (rule.kind) {
          case ColdTurkeyRuleKind.domain:
            await db.insertDomain(
              id: const Uuid().v4(),
              host: rule.domainHost!,
              includeSubdomains: rule.includeSubdomains,
              source: 'imported',
              enabled: true,
              scheduleId: scheduleId,
              isStem: false,
            );
            domainsImported++;
            break;
          case ColdTurkeyRuleKind.path:
          case ColdTurkeyRuleKind.urlPattern:
            await db.insertKeyword(
              id: const Uuid().v4(),
              pattern: rule.keywordPattern!,
              scheduleId: scheduleId,
              enabled: true,
            );
            keywordsImported++;
            break;
        }
      } catch (e) {
        skipped++;
        AppLogger.instance.warn('import skip: ${rule.raw}', error: e);
      }
    }

    AppLogger.instance.info(
      'import done schedule=$scheduleId domains=$domainsImported '
      'keywords=$keywordsImported skipped=$skipped',
    );
    return ColdTurkeyImportResult(
      scheduleId: scheduleId,
      domainsImported: domainsImported,
      keywordsImported: keywordsImported,
      domainRules: batch.domainCount,
      pathRules: batch.pathCount,
      urlPatternRules: batch.urlPatternCount,
      skipped: skipped,
    );
  }

  /// Legacy: flat host list → domains only (no path/query rules).
  Future<int> importToDB({
    required List<String> hosts,
    required String scheduleName,
  }) async {
    final ColdTurkeyImportBatch batch = parseColdTurkeyLines(hosts);
    final ColdTurkeyImportResult r = await importBatchToDB(
      batch: batch,
      scheduleName: scheduleName,
    );
    return r.totalImported;
  }

  static bool looksLikeColdTurkey(String content) {
    final Iterable<String> lines = content.split('\n').take(20);
    final int turkeyPatterns = lines.where((String l) {
      final String trimmed = l.trim();
      return trimmed.startsWith('*') ||
          trimmed.contains('*q=*') ||
          trimmed.contains('*p=*') ||
          trimmed.contains('search_query=') ||
          trimmed.endsWith('.xxx');
    }).length;
    return turkeyPatterns > 2;
  }
}
