import 'dart:io';

import '../utils/cold_turkey_rule_parser.dart';
import '../utils/youtube_blocklist_parser.dart';
import 'app_logger.dart';
import 'import_service.dart';
import 'local_database.dart';

/// Imports a plain-text YouTube channel / video list into an **enabled**
/// 24/7 schedule so extension sync picks up keywords immediately.
final class YouTubeBlocklistImportService {
  YouTubeBlocklistImportService._();
  static final YouTubeBlocklistImportService instance =
      YouTubeBlocklistImportService._();

  static const String defaultScheduleName = 'YouTube · 가져온 채널';

  Future<YouTubeBlocklistImportResult> importFromFile(
    String filePath, {
    String scheduleName = defaultScheduleName,
    bool enableSchedule = true,
  }) async {
    AppLogger.instance.info('YouTube blocklist import: $filePath');
    final List<String> lines = await File(filePath).readAsLines();
    return importFromLines(lines, scheduleName: scheduleName, enableSchedule: enableSchedule);
  }

  Future<YouTubeBlocklistImportResult> importFromLines(
    List<String> lines, {
    String scheduleName = defaultScheduleName,
    bool enableSchedule = true,
  }) async {
    final YouTubeBlocklistBatch ytBatch = parseYouTubeBlocklistLines(lines);
    final ColdTurkeyImportBatch genericBatch = parseColdTurkeyLines(lines);

    final Map<String, ColdTurkeyParsedRule> merged =
        <String, ColdTurkeyParsedRule>{};
    for (final ColdTurkeyParsedRule r in ytBatch.rules) {
      merged[r.keywordPattern!] = r;
    }
    for (final ColdTurkeyParsedRule r in genericBatch.rules) {
      if (r.kind == ColdTurkeyRuleKind.domain &&
          r.domainHost == 'youtube.com') {
        continue;
      }
      final String? k = r.keywordPattern ?? r.domainHost;
      if (k != null) {
        merged.putIfAbsent(k.toLowerCase(), () => r);
      }
    }

    final ColdTurkeyImportBatch batch =
        ColdTurkeyImportBatch(rules: merged.values.toList());

    final ColdTurkeyImportResult base = await ImportService.instance
        .importBatchToDB(batch: batch, scheduleName: scheduleName);

    if (enableSchedule) {
      await LocalDatabase.instance.setScheduleEnabled(base.scheduleId, true);
    }

    AppLogger.instance.info(
      'YouTube blocklist done: keywords=${base.keywordsImported} '
      'schedule=${base.scheduleId} enabled=$enableSchedule',
    );

    return YouTubeBlocklistImportResult(
      scheduleId: base.scheduleId,
      keywordsImported: base.keywordsImported,
      skipped: base.skipped,
      sourceLines: lines.where((l) => l.trim().isNotEmpty).length,
      patternCount: batch.rules.length,
    );
  }
}

final class YouTubeBlocklistImportResult {
  const YouTubeBlocklistImportResult({
    required this.scheduleId,
    required this.keywordsImported,
    required this.skipped,
    required this.sourceLines,
    required this.patternCount,
  });

  final String scheduleId;
  final int keywordsImported;
  final int skipped;
  final int sourceLines;
  final int patternCount;
}
