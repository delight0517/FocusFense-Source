import '../platform/rules_platform.dart';
import 'app_stats.dart';
import 'local_database.dart';
import 'rules_host_resolver.dart';

final class RulesExportService {
  RulesExportService({
    LocalDatabase? database,
    RulesPlatform? platform,
    RulesHostResolver? resolver,
  })  : _db = database ?? LocalDatabase.instance,
        _platform = platform ?? RulesPlatform(),
        _resolver = resolver ?? RulesHostResolver.instance;

  final LocalDatabase _db;
  final RulesPlatform _platform;
  final RulesHostResolver _resolver;

  Future<String?> exportCurrentRules() async {
    final bundle = await _db.buildRulesBundle();
    final String? path = await _resolver.writeRulesJson(_platform, bundle.toJsonString());
    if (path != null) {
      await AppStats.recordExport();
    }
    return path;
  }

  Future<String?> storagePathForDisplay() => _resolver.pathForDisplay(_platform);
}
