import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../constants/app_constants.dart';
import '../platform/rules_platform.dart';
import 'rules_host_resolver.dart';

/// 유료 계정 없이 **공유 시트**가 한 일을 흉내 냅니다: `pending_share_hosts.json`에 호스트를 붙입니다.
final class SimulatedShareActions {
  SimulatedShareActions({
    RulesHostResolver? resolver,
    RulesPlatform? platform,
  })  : _resolver = resolver ?? RulesHostResolver.instance,
        _platform = platform ?? RulesPlatform();

  final RulesHostResolver _resolver;
  final RulesPlatform _platform;

  Future<void> appendHost(String rawHost) async {
    var host = rawHost.trim().toLowerCase();
    if (host.isEmpty) {
      return;
    }
    host = host.replaceFirst(RegExp(r'^https?://'), '');
    host = host.split('/').first;
    if (host.isEmpty) {
      return;
    }

    final dir = await _resolver.resolvedDirectory(_platform);
    final file = File(p.join(dir, kPendingShareHostsFile));
    var list = <String>[];
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          list = decoded.whereType<String>().toList();
        }
      } catch (_) {
        list = <String>[];
      }
    }
    if (!list.contains(host)) {
      list.add(host);
    }
    await file.writeAsString(jsonEncode(list));
  }
}
