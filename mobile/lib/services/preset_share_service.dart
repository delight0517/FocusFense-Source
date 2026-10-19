import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/preset_share_bundle.dart';
import '../models/quick_block_rule_entries.dart';
import '../models/quick_block_user_bundle.dart';
import 'local_database.dart';
import 'quick_block_prefs_store.dart';
import 'schedule_rule_validation.dart';

/// Result of importing a [PresetShareBundle] into this device.
final class PresetImportResult {
  const PresetImportResult({
    required this.asSchedule,
    required this.name,
    required this.domainsImported,
    required this.keywordsImported,
    required this.appsImported,
    this.scheduleId,
  });

  final bool asSchedule;
  final String name;
  final int domainsImported;
  final int keywordsImported;
  final int appsImported;
  final String? scheduleId;

  int get totalImported => domainsImported + keywordsImported + appsImported;
}

/// "나만의 프리셋" export/import — friend-to-friend sharing with no server.
/// Export produces both a `.json` file (Downloads folder) and a compact
/// base64 "프리셋 코드" copied to the clipboard; a friend can import either.
final class PresetShareService {
  PresetShareService._();
  static final PresetShareService instance = PresetShareService._();

  final LocalDatabase _db = LocalDatabase.instance;

  Future<PresetShareBundle> buildFromSchedule(
    String scheduleId, {
    required bool includeSchedule,
  }) async {
    final Map<String, Object?>? row = await _db.scheduleById(scheduleId);
    final String name = '${row?['name'] ?? '프리셋'}';
    final List<Map<String, Object?>> domainRows = await _db.domainsForSchedule(
      scheduleId,
    );
    final List<Map<String, Object?>> keywordRows = await _db
        .keywordsForSchedule(scheduleId);
    final List<Map<String, Object?>> appRows = await _db.appsForSchedule(
      scheduleId,
    );

    List<int> weekdays = const <int>[];
    int startMinutes = 0;
    int endMinutes = 1440;
    if (includeSchedule) {
      final List<Map<String, Object?>> slotRows = await _db.slotsForSchedule(
        scheduleId,
      );
      if (slotRows.isNotEmpty) {
        weekdays = slotRows
            .map((Map<String, Object?> r) => (r['day'] as int?) ?? -1)
            .where((int d) => d >= 0 && d <= 6)
            .toSet()
            .toList()
          ..sort();
        startMinutes = slotRows
            .map((Map<String, Object?> r) => (r['start_minute'] as int?) ?? 0)
            .reduce(min);
        endMinutes = slotRows
            .map((Map<String, Object?> r) => (r['end_minute'] as int?) ?? 1440)
            .reduce(max);
      } else if (row != null) {
        startMinutes = (row['start_minute'] as int?) ?? 0;
        final int legacyEnd = (row['end_minute'] as int?) ?? 0;
        endMinutes = legacyEnd == 0 ? 1440 : legacyEnd;
        final int daysMask = (row['days_mask'] as int?) ?? 127;
        weekdays = <int>[
          for (int d = 0; d < 7; d++)
            if ((daysMask & (1 << d)) != 0) d,
        ];
      }
    }

    return PresetShareBundle(
      name: name,
      includeSchedule: includeSchedule,
      weekdays: weekdays,
      startMinutes: startMinutes,
      endMinutes: endMinutes,
      domains: domainRows
          .map((Map<String, Object?> r) => '${r['host'] ?? ''}')
          .where((String s) => s.isNotEmpty)
          .toList(),
      keywords: keywordRows
          .map((Map<String, Object?> r) => '${r['pattern'] ?? ''}')
          .where((String s) => s.isNotEmpty)
          .toList(),
      appNames: appRows
          .map((Map<String, Object?> r) => '${r['name'] ?? ''}')
          .where((String s) => s.isNotEmpty)
          .toList(),
    );
  }

  String encodeCode(PresetShareBundle bundle) =>
      base64Encode(utf8.encode(bundle.toJsonString()));

  /// Accepts either a "프리셋 코드" (base64) or raw JSON (from an exported
  /// file pasted directly) — whichever decodes successfully.
  PresetShareBundle? decode(String codeOrJson) {
    final String trimmed = codeOrJson.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('{')) {
      return PresetShareBundle.fromJsonString(trimmed);
    }
    try {
      final String jsonStr = utf8.decode(base64Decode(trimmed));
      final PresetShareBundle? fromCode = PresetShareBundle.fromJsonString(
        jsonStr,
      );
      if (fromCode != null) return fromCode;
    } catch (_) {
      // fall through to raw-JSON attempt below
    }
    return PresetShareBundle.fromJsonString(trimmed);
  }

  Future<String> exportToClipboardCode(PresetShareBundle bundle) async {
    final String code = encodeCode(bundle);
    await Clipboard.setData(ClipboardData(text: code));
    return code;
  }

  /// Writes the preset JSON to the Downloads folder (falls back to the app's
  /// documents directory if Downloads isn't resolvable on this platform).
  Future<String> exportToFile(PresetShareBundle bundle) async {
    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {
      dir = null;
    }
    dir ??= await getApplicationDocumentsDirectory();
    final String safeName = bundle.name
        .replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_')
        .trim();
    final String fileName =
        '6vpn_preset_${safeName.isEmpty ? 'unnamed' : safeName}.json';
    final File file = File(p.join(dir.path, fileName));
    await file.writeAsString(bundle.toJsonString());
    return file.path;
  }

  Future<PresetImportResult> importBundle(PresetShareBundle bundle) async {
    if (!bundle.includeSchedule) {
      return _importAsQuickBlock(bundle);
    }
    return _importAsSchedule(bundle);
  }

  Future<PresetImportResult> _importAsSchedule(
    PresetShareBundle bundle,
  ) async {
    final String scheduleId = _newId('preset_share_sched');
    final List<int> weekdays = bundle.weekdays.isEmpty
        ? const <int>[0, 1, 2, 3, 4, 5, 6]
        : bundle.weekdays;
    final int endMinute = bundle.endMinutes >= 1440 ? 0 : bundle.endMinutes;
    // Disabled by default — same safety convention as ImportService's
    // Cold-Turkey-file import: a shared preset should never silently start
    // blocking before the recipient has looked at it.
    await _db.upsertSchedule(
      id: scheduleId,
      name: bundle.name,
      startMinute: bundle.startMinutes,
      endMinute: endMinute,
      daysMask: _daysMask(weekdays),
      enabled: false,
    );
    for (final int day in weekdays) {
      await _db.insertSlot(
        id: _newId('preset_share_slot'),
        scheduleId: scheduleId,
        day: day,
        startMinute: bundle.startMinutes,
        endMinute: bundle.endMinutes >= 1440 ? 1440 : bundle.endMinutes,
      );
    }

    int domainsImported = 0;
    for (final String host in bundle.domains) {
      if (ScheduleRuleValidation.validateHost(host) != null) continue;
      await _db.insertDomain(
        id: _newId('preset_share_d'),
        host: host,
        scheduleId: scheduleId,
        source: 'preset_share',
        isStem: !host.contains('.'),
      );
      domainsImported++;
    }
    int keywordsImported = 0;
    for (final String kw in bundle.keywords) {
      if (ScheduleRuleValidation.validateKeyword(kw) != null) continue;
      await _db.insertKeyword(
        id: _newId('preset_share_k'),
        pattern: kw,
        scheduleId: scheduleId,
      );
      keywordsImported++;
    }
    int appsImported = 0;
    for (final String name in bundle.appNames) {
      if (ScheduleRuleValidation.validateAppName(name) != null) continue;
      await _db.insertBlockedApp(
        id: _newId('preset_share_a'),
        name: name,
        scheduleId: scheduleId,
      );
      appsImported++;
    }
    return PresetImportResult(
      asSchedule: true,
      name: bundle.name,
      scheduleId: scheduleId,
      domainsImported: domainsImported,
      keywordsImported: keywordsImported,
      appsImported: appsImported,
    );
  }

  Future<PresetImportResult> _importAsQuickBlock(
    PresetShareBundle bundle,
  ) async {
    final QuickBlockUserBundle qb = QuickBlockUserBundle(
      id: _newId('preset_share_qb'),
      label: bundle.name,
      domains: bundle.domains
          .map((String h) => QuickBlockDomainRule(host: h))
          .toList(),
      keywords: bundle.keywords
          .map((String k) => QuickBlockKeywordRule(pattern: k))
          .toList(),
      apps: bundle.appNames
          .map((String n) => QuickBlockAppRule(displayName: n))
          .toList(),
    );
    final List<QuickBlockUserBundle> existing = await QuickBlockPrefsStore
        .instance
        .loadBundles();
    await QuickBlockPrefsStore.instance.saveBundles(<QuickBlockUserBundle>[
      ...existing,
      qb,
    ]);
    return PresetImportResult(
      asSchedule: false,
      name: bundle.name,
      domainsImported: qb.domains.length,
      keywordsImported: qb.keywords.length,
      appsImported: qb.apps.length,
    );
  }

  static int _daysMask(List<int> days) {
    int mask = 0;
    for (final int day in days) {
      if (day >= 0 && day <= 6) mask |= 1 << day;
    }
    return mask;
  }

  static String _newId(String prefix) {
    final int now = DateTime.now().microsecondsSinceEpoch;
    final int rnd = Random().nextInt(1 << 20);
    return '${prefix}_${now}_$rnd';
  }
}
