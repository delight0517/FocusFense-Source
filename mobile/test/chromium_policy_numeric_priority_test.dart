import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/services/chromium_policy_service.dart';
import 'package:six_clean_room/services/browser_youtube_policy_split.dart';
import 'package:six_clean_room/services/extension_rules_builder.dart';
import 'package:six_clean_room/services/extension_guard_prefs.dart';
import 'package:six_clean_room/services/local_database.dart';
import 'package:six_clean_room/models/rules_meta.dart';
import 'package:sqflite/sqflite.dart';

final class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.basePath);

  final String basePath;

  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;

  @override
  Future<String?> getApplicationSupportPath() async => basePath;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Database db;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('ff-schedule-rules-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(temp.path);
    db = await LocalDatabase.instance.database;
  });
  tearDownAll(() async {
    await db.close();
    PathProviderPlatform.instance = originalPaths;
    await temp.delete(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    for (final String table in <String>[
      'domains',
      'keywords',
      'search_query_blocks',
      'blocked_apps',
      'schedule_slots',
      'schedules',
    ]) {
      await db.delete(table);
    }
    await db.update(
      'settings_kv',
      <String, Object?>{'value_json': jsonEncode(RulesMeta.defaults.toJson())},
      where: 'key = ?',
      whereArgs: <Object>['rules_meta'],
    );
  });

  Future<void> schedule(
    String id, {
    int start = 540,
    int end = 600,
    int days = 1,
    int enabled = 1,
  }) async {
    await db.insert('schedules', <String, Object?>{
      'id': id,
      'name': id,
      'enabled': enabled,
      'start_minute': start,
      'end_minute': end,
      'days_mask': days,
      'created_at': 1,
    });
  }

  Future<void> domain(
    String id,
    String host, {
    String? scheduleId,
    int enabled = 1,
    int? deletedAt,
  }) async {
    await db.insert('domains', <String, Object?>{
      'id': id,
      'host': host,
      'schedule_id': scheduleId,
      'enabled': enabled,
      'created_at': 1,
      'deleted_at': deletedAt,
    });
  }

  final DateTime monday = DateTime(2026, 10, 12, 9, 30);

  test(
    'keyword runtime keeps explicit page action, match and case settings',
    () async {
      for (final action in <String>['redact', 'block_page']) {
        await db.insert('keywords', <String, Object?>{
          'id': action,
          'pattern': action == 'block_page' ? '엉덩이' : '섹시',
          'match_type': 'contains',
          'action': action,
          'case_sensitive': 1,
          'enabled': 1,
          'created_at': 1,
        });
      }
      final payload = await ExtensionRulesBuilder.buildActiveNow(at: monday);
      expect(payload.keywordRules, hasLength(2));
      final page = payload.keywordRules.singleWhere(
        (rule) => rule.action == 'block_page',
      );
      expect(page.pattern, '엉덩이');
      expect(page.match, 'contains');
      expect(page.caseSensitive, true);
      expect(payload.copyWithoutYoutubeApex().keywordRules, hasLength(2));
      final rows = payload.toJson(port: 17361)['keywordRules'] as List;
      expect(rows.any((row) => row['action'] == 'redact'), true);
      expect(rows.any((row) => row['action'] == 'block_page'), true);
    },
  );

  test(
    'runtime OFF preserves configured schedules and rules for re-enable',
    () async {
      await schedule('kept-schedule');
      await domain(
        'kept-domain',
        'kept-fixture.example',
        scheduleId: 'kept-schedule',
      );
      final beforeDomains = await db.query('domains');
      final beforeSchedules = await db.query('schedules');
      final prefs = ExtensionGuardPrefs.forTesting(
        Directory('${temp.path}/runtime-prefs'),
      );
      final off = await ExtensionRulesBuilder.buildForExtensionRuntime(
        at: monday,
        browserId: 'aside',
        preferences: prefs,
        protectionEnabledForTesting: false,
      );
      expect(off.protectionEnabled, false);
      expect(off.blockedDomains, isEmpty);
      expect(await db.query('domains'), beforeDomains);
      expect(await db.query('schedules'), beforeSchedules);
      final on = await ExtensionRulesBuilder.buildForExtensionRuntime(
        at: monday,
        browserId: 'aside',
        preferences: prefs,
        protectionEnabledForTesting: true,
      );
      expect(on.protectionEnabled, true);
      expect(on.blockedDomains, contains('kept-fixture.example'));
    },
  );

  test(
    'channel rules stay scoped while explicit whole-site choices work in every browser',
    () async {
      await domain('site', 'chosen-fixture.example');
      await db.insert('keywords', <String, Object?>{
        'id': 'channel',
        'pattern': 'https://www.youtube.com/@ChosenFixture',
        'created_at': 1,
      });
      for (final String browser in <String>['chrome', 'edge', 'aside']) {
        for (final bool ready in <bool>[true, false]) {
          final List<String> patterns =
              await ChromiumPolicyService.activeBlocklistPatternsForChromiumBrowser(
                browser,
                extensionHandlesYoutube: ready,
                at: monday,
              );
          expect(patterns, contains('chosen-fixture.example'));
          expect(
            patterns.any((String p) => p.contains('@ChosenFixture')),
            isTrue,
          );
          expect(patterns, isNot(contains('youtube.com')));
          expect(patterns, isNot(contains('youtu.be')));
        }
      }
      final List<String> firefox =
          await ChromiumPolicyService.activeBlocklistPatternsForFirefox(
            at: monday,
          );
      expect(
        firefox.any(BrowserYoutubePolicySplit.isYoutubeApexBlockPattern),
        isFalse,
      );
      expect(firefox, contains('*://*.chosen-fixture.example/*'));
      await domain('youtube', 'youtube.com');
      for (final String browser in <String>['chrome', 'edge', 'aside']) {
        expect(
          await ChromiumPolicyService.activeBlocklistPatternsForChromiumBrowser(
            browser,
            extensionHandlesYoutube: true,
            at: monday,
          ),
          contains('youtube.com'),
        );
      }
      expect(
        await ChromiumPolicyService.activeBlocklistPatternsForFirefox(
          at: monday,
        ),
        contains('*://*.youtube.com/*'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Firefox host filters use valid match-pattern syntax without broadening exact hosts',
    () {
      expect(
        ChromiumPolicyService.firefoxMatchPatterns(<String>[
          'example.com',
          '.exact.example',
          '[*.]legacy.example',
          '127.0.0.1',
          '*://*.youtube.com/@ChosenFixture*',
          'example.com',
        ]),
        <String>[
          '*://*.example.com/*',
          '*://exact.example/*',
          '*://*.legacy.example/*',
          '*://127.0.0.1/*',
          '*://*.youtube.com/@ChosenFixture*',
        ],
      );
      expect(
        () => ChromiumPolicyService.firefoxMatchPatterns(<String>[
          'example*.com',
        ]),
        throwsFormatException,
      );
    },
  );

  test(
    'websites, keywords, search terms and apps share schedule boundaries',
    () async {
      await schedule('work');
      await schedule('off', enabled: 0);
      await domain('global', 'always-fixture.example');
      await domain('timed', 'timed-fixture.example', scheduleId: 'work');
      await domain('off', 'disabled-fixture.example', scheduleId: 'off');
      await domain('deleted', 'deleted-fixture.example', deletedAt: 1);
      await domain('rule-off', 'rule-off-fixture.example', enabled: 0);
      await db.insert('keywords', <String, Object?>{
        'id': 'word',
        'pattern': 'fixtureword',
        'schedule_id': 'work',
        'created_at': 1,
      });
      await db.insert('search_query_blocks', <String, Object?>{
        'id': 'query',
        'term': 'fixture query',
        'schedule_id': 'work',
        'created_at': 1,
      });
      await db.insert('blocked_apps', <String, Object?>{
        'id': 'app',
        'name': 'fixture-game.exe',
        'schedule_id': 'work',
        'created_at': 1,
      });
      for (final DateTime time in <DateTime>[
        monday,
        DateTime(2026, 10, 12, 9),
      ]) {
        final ExtensionRulesPayload payload =
            await ExtensionRulesBuilder.buildForBrowserEnforcement(at: time);
        expect(
          payload.blockedDomains,
          containsAll(<String>[
            'always-fixture.example',
            'timed-fixture.example',
          ]),
        );
        expect(payload.keywords, contains('fixtureword'));
        expect(
          payload.searchQueries.map((rule) => rule.term),
          contains('fixture query'),
        );
        expect(
          await LocalDatabase.instance.blockedAppsActiveNow(time),
          contains('fixture-game.exe'),
        );
      }
      for (final DateTime time in <DateTime>[
        DateTime(2026, 10, 12, 8, 59),
        DateTime(2026, 10, 12, 10),
        DateTime(2026, 10, 13, 9, 30),
      ]) {
        final ExtensionRulesPayload payload =
            await ExtensionRulesBuilder.buildForBrowserEnforcement(at: time);
        expect(payload.blockedDomains, contains('always-fixture.example'));
        expect(
          payload.blockedDomains,
          isNot(contains('timed-fixture.example')),
        );
        expect(payload.keywords, isNot(contains('fixtureword')));
        expect(
          payload.searchQueries.map((rule) => rule.term),
          isNot(contains('fixture query')),
        );
        expect(
          await LocalDatabase.instance.blockedAppsActiveNow(time),
          isEmpty,
        );
      }
      final ExtensionRulesPayload payload =
          await ExtensionRulesBuilder.buildForBrowserEnforcement(at: monday);
      for (final String host in <String>[
        'disabled-fixture.example',
        'deleted-fixture.example',
        'rule-off-fixture.example',
      ]) {
        expect(payload.blockedDomains, isNot(contains(host)));
      }
    },
  );

  test(
    'a schedule with slots never falls back to legacy hours on an unscheduled day',
    () async {
      await schedule('slots', start: 0, end: 0, days: 127);
      await domain('timed', 'slot-fixture.example', scheduleId: 'slots');
      await db.insert('schedule_slots', <String, Object?>{
        'id': 'mon',
        'schedule_id': 'slots',
        'day': 0,
        'start_minute': 540,
        'end_minute': 600,
        'created_at': 1,
      });
      expect(
        (await ExtensionRulesBuilder.buildForBrowserEnforcement(
          at: monday,
        )).blockedDomains,
        contains('slot-fixture.example'),
      );
      for (final DateTime time in <DateTime>[
        DateTime(2026, 10, 12, 11),
        DateTime(2026, 10, 13, 9, 30),
      ]) {
        expect(
          (await ExtensionRulesBuilder.buildForBrowserEnforcement(
            at: time,
          )).blockedDomains,
          isNot(contains('slot-fixture.example')),
        );
      }
    },
  );

  test(
    'overnight schedules use the starting weekday for legacy windows and slots',
    () async {
      await schedule('legacy', start: 1320, end: 360, days: 1);
      await domain('legacy', 'legacy-night.example', scheduleId: 'legacy');
      await schedule('slots', start: 0, end: 0, days: 127);
      await domain('slots', 'slot-night.example', scheduleId: 'slots');
      await db.insert('schedule_slots', <String, Object?>{
        'id': 'night',
        'schedule_id': 'slots',
        'day': 2,
        'start_minute': 1320,
        'end_minute': 360,
        'created_at': 1,
      });
      for (final DateTime time in <DateTime>[
        DateTime(2026, 10, 12, 23),
        DateTime(2026, 10, 13, 3),
      ]) {
        expect(
          (await ExtensionRulesBuilder.buildForBrowserEnforcement(
            at: time,
          )).blockedDomains,
          contains('legacy-night.example'),
        );
      }
      for (final DateTime time in <DateTime>[
        DateTime(2026, 10, 12, 3),
        DateTime(2026, 10, 13, 6),
        DateTime(2026, 10, 13, 23),
      ]) {
        expect(
          (await ExtensionRulesBuilder.buildForBrowserEnforcement(
            at: time,
          )).blockedDomains,
          isNot(contains('legacy-night.example')),
        );
      }
      for (final DateTime time in <DateTime>[
        DateTime(2026, 10, 14, 23),
        DateTime(2026, 10, 15, 3),
      ]) {
        expect(
          (await ExtensionRulesBuilder.buildForBrowserEnforcement(
            at: time,
          )).blockedDomains,
          contains('slot-night.example'),
        );
      }
      for (final DateTime time in <DateTime>[
        DateTime(2026, 10, 14, 3),
        DateTime(2026, 10, 15, 6),
        DateTime(2026, 10, 15, 23),
      ]) {
        expect(
          (await ExtensionRulesBuilder.buildForBrowserEnforcement(
            at: time,
          )).blockedDomains,
          isNot(contains('slot-night.example')),
        );
      }
    },
  );

  test(
    'the URL policy cap retains numeric mirror coverage before bulk hosts',
    () async {
      final Batch batch = db.batch();
      for (int index = 0; index < 1100; index++) {
        batch.insert('domains', <String, Object?>{
          'id': 'bulk-$index',
          'host': 'bulk-$index.example',
          'created_at': index,
        });
      }
      await batch.commit(noResult: true);
      await domain('parent', 'mirror-fixture.example');
      await domain('numeric', '16.mirror-fixture.example');
      final List<String> patterns =
          await ChromiumPolicyService.activeBlocklistPatterns(at: monday);
      expect(patterns.length, lessThanOrEqualTo(1000));
      expect(
        patterns,
        containsAll(<String>[
          'mirror-fixture.example',
          '16.mirror-fixture.example',
        ]),
      );
      expect(patterns.toSet().length, patterns.length);
    },
  );

  test(
    'adult categories default on and can be switched off explicitly',
    () async {
      final List<String> defaultPolicy =
          await ChromiumPolicyService.activeBlocklistPatterns(at: monday);
      expect(defaultPolicy, contains('pornhub.com'));
      expect(defaultPolicy.length, lessThanOrEqualTo(1000));
      expect(
        (await ExtensionRulesBuilder.buildForBrowserEnforcement(
          at: monday,
        )).blockedDomains,
        contains('pornhub.com'),
      );
      await db.update(
        'settings_kv',
        <String, Object?>{
          'value_json': jsonEncode(
            RulesMeta.defaults.copyWith(adultSitesBlocked: false).toJson(),
          ),
        },
        where: 'key = ?',
        whereArgs: <Object>['rules_meta'],
      );
      expect(
        (await ExtensionRulesBuilder.buildForBrowserEnforcement(
          at: monday,
        )).blockedDomains,
        isNot(contains('pornhub.com')),
      );
      expect(
        await ChromiumPolicyService.activeBlocklistPatterns(at: monday),
        isNot(contains('pornhub.com')),
      );
    },
  );
}
