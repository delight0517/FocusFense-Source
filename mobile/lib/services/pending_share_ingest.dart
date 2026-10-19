import 'dart:convert';
import 'dart:io';

import '../constants/app_constants.dart';
import '../platform/rules_platform.dart';
import 'app_stats.dart';
import 'local_database.dart';
import 'rules_host_resolver.dart';

/// Ingests hosts appended by the iOS Share extension into [LocalDatabase].
final class PendingShareIngest {
  PendingShareIngest({
    LocalDatabase? database,
    RulesPlatform? platform,
    RulesHostResolver? resolver,
  })  : _db = database ?? LocalDatabase.instance,
        _platform = platform ?? RulesPlatform(),
        _resolver = resolver ?? RulesHostResolver.instance;

  final LocalDatabase _db;
  final RulesPlatform _platform;
  final RulesHostResolver _resolver;

  Future<int> ingestIfNeeded() async {
    final String groupPath;
    try {
      groupPath = await _resolver.resolvedDirectory(_platform);
    } catch (_) {
      return 0;
    }
    final file = File('$groupPath/$kPendingShareHostsFile');
    if (!await file.exists()) {
      return 0;
    }
    final raw = await file.readAsString();
    List<dynamic> list;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        await file.delete();
        return 0;
      }
      list = decoded;
    } catch (_) {
      await file.delete();
      return 0;
    }
    var added = 0;
    var index = 0;
    for (final Object? item in list) {
      if (item is! String) continue;
      final String host = item.trim().toLowerCase();
      if (host.isEmpty) continue;
      if (await _db.hasDomainHost(host)) {
        index++;
        continue;
      }
      await _db.insertDomain(
        id: '${DateTime.now().microsecondsSinceEpoch}_$index',
        host: host,
        source: 'share_sheet',
      );
      added++;
      index++;
    }
    await file.delete();
    await AppStats.addIngestedHosts(added);
    return added;
  }
}
