import 'unified_rule_kind.dart';
import '../utils/url_rule_detector.dart';

/// Which SQLite table a unified schedule rule row lives in.
enum ScheduleRuleStorage { domain, keyword, searchQuery }

/// One row in the merged schedule blocklist (sites + keywords + search terms).
class ScheduleUnifiedRuleEntry {
  const ScheduleUnifiedRuleEntry({
    required this.id,
    required this.display,
    required this.kind,
    required this.storage,
    required this.createdAt,
    required this.row,
    this.isStem = false,
  });

  final String id;
  final String display;
  final UnifiedRuleKind kind;
  final ScheduleRuleStorage storage;
  final int createdAt;
  final Map<String, Object?> row;
  final bool isStem;

  static List<ScheduleUnifiedRuleEntry> merge({
    required List<Map<String, Object?>> domains,
    required List<Map<String, Object?>> keywords,
    required List<Map<String, Object?>> searchQueries,
  }) {
    final List<ScheduleUnifiedRuleEntry> out = <ScheduleUnifiedRuleEntry>[];

    for (final Map<String, Object?> row in domains) {
      final String host = row['host']! as String;
      final bool stem = (row['is_stem'] as int? ?? 0) == 1;
      out.add(
        ScheduleUnifiedRuleEntry(
          id: row['id']! as String,
          display: host,
          kind: stem
              ? UnifiedRuleKind.wildcard
              : UrlRuleDetector.inferStoredKind(
                  value: host,
                  isDomainRow: true,
                ),
          storage: ScheduleRuleStorage.domain,
          createdAt: row['created_at']! as int,
          row: row,
          isStem: stem,
        ),
      );
    }

    for (final Map<String, Object?> row in keywords) {
      final String pattern = row['pattern']! as String;
      out.add(
        ScheduleUnifiedRuleEntry(
          id: row['id']! as String,
          display: pattern,
          kind: UrlRuleDetector.inferStoredKind(
            value: pattern,
            isDomainRow: false,
          ),
          storage: ScheduleRuleStorage.keyword,
          createdAt: row['created_at']! as int,
          row: row,
        ),
      );
    }

    for (final Map<String, Object?> row in searchQueries) {
      final String term = row['term']! as String;
      out.add(
        ScheduleUnifiedRuleEntry(
          id: row['id']! as String,
          display: term,
          kind: UnifiedRuleKind.searchQuery,
          storage: ScheduleRuleStorage.searchQuery,
          createdAt: row['created_at']! as int,
          row: row,
        ),
      );
    }

    out.sort(
      (ScheduleUnifiedRuleEntry a, ScheduleUnifiedRuleEntry b) =>
          b.createdAt.compareTo(a.createdAt),
    );
    return out;
  }
}
