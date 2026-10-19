import 'package:shared_preferences/shared_preferences.dart';

import 'local_database.dart';

/// Safari 확장 이벤트 전까지 쌓을 수 있는 **로컬** 지표.
final class AppStats {
  AppStats._();

  static const String _hostsIngested = 'stats_hosts_ingested_total';
  static const String _exports = 'stats_rules_export_total';
  static const String _lastExportMs = 'stats_last_export_epoch_ms';

  static Future<void> addIngestedHosts(int n) async {
    if (n <= 0) return;
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setInt(_hostsIngested, (p.getInt(_hostsIngested) ?? 0) + n);
  }

  static Future<void> recordExport() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setInt(_exports, (p.getInt(_exports) ?? 0) + 1);
    await p.setInt(_lastExportMs, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<StatsOverview> loadOverview(LocalDatabase db) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final RuleCounts counts = await db.ruleCounts();
    return StatsOverview(
      keywordsTotal: counts.keywordsTotal,
      keywordsEnabled: counts.keywordsEnabled,
      domainsTotal: counts.domainsTotal,
      domainsEnabled: counts.domainsEnabled,
      serpFiltersTotal: counts.serpFiltersTotal,
      serpFiltersEnabled: counts.serpFiltersEnabled,
      searchBlocksTotal: counts.searchBlocksTotal,
      searchBlocksEnabled: counts.searchBlocksEnabled,
      hostsIngestedLifetime: p.getInt(_hostsIngested) ?? 0,
      rulesExportsLifetime: p.getInt(_exports) ?? 0,
      lastExportEpochMs: p.getInt(_lastExportMs),
    );
  }
}

final class StatsOverview {
  const StatsOverview({
    required this.keywordsTotal,
    required this.keywordsEnabled,
    required this.domainsTotal,
    required this.domainsEnabled,
    required this.serpFiltersTotal,
    required this.serpFiltersEnabled,
    required this.searchBlocksTotal,
    required this.searchBlocksEnabled,
    required this.hostsIngestedLifetime,
    required this.rulesExportsLifetime,
    this.lastExportEpochMs,
  });

  final int keywordsTotal;
  final int keywordsEnabled;
  final int domainsTotal;
  final int domainsEnabled;
  final int serpFiltersTotal;
  final int serpFiltersEnabled;
  final int searchBlocksTotal;
  final int searchBlocksEnabled;
  final int hostsIngestedLifetime;
  final int rulesExportsLifetime;
  final int? lastExportEpochMs;
}
