import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:six_clean_room/services/brainwire_blocklist_sync_service.dart';

class _Cloud {
  Map<String, dynamic> document = <String, dynamic>{
    '_rev': 0,
    'unrelated': <String, dynamic>{'keep': true},
  };
  int writes = 0;
  bool conflictNextWrite = false;
  bool offline = false;
  Future<void> Function()? beforeNextRead;
  Future<void> Function()? beforeNextWrite;

  late final http.Client client = MockClient((http.Request request) async {
    expect(request.url.path, '/api/cloud-state/focus-fense');
    expect(request.headers['x-cloud-app'], 'focus-fense');
    expect(request.headers['authorization'], 'Bearer test-account');
    if (offline) throw http.ClientException('offline');
    if (request.method == 'GET') {
      final Future<void> Function()? callback = beforeNextRead;
      beforeNextRead = null;
      await callback?.call();
      return http.Response(
        jsonEncode(<String, dynamic>{'state': document}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    expect(request.method, 'PUT');
    final Map<String, dynamic> incoming = (jsonDecode(request.body) as Map)
        .cast<String, dynamic>();
    if (conflictNextWrite) {
      conflictNextWrite = false;
      document['_rev'] = (document['_rev'] as int) + 1;
      document['concurrentField'] = 'preserved';
      return http.Response('{}', 409);
    }
    if (incoming['_rev'] != document['_rev']) return http.Response('{}', 409);
    final callback = beforeNextWrite;
    beforeNextWrite = null;
    await callback?.call();
    writes++;
    document = incoming..['_rev'] = (document['_rev'] as int) + 1;
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'rev': document['_rev']}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

class _Device {
  _Device(this.db, _Cloud cloud, String name) {
    service = BrainwireBlocklistSyncService.forTesting(
      database: db,
      client: cloud.client,
      readToken: () async => connected ? 'test-account' : null,
      clearToken: () async {
        connected = false;
      },
      baselineKey: 'baseline-$name',
      onRulesChanged: () => applies++,
      clock: () => DateTime.fromMillisecondsSinceEpoch(time, isUtc: true),
    );
  }

  final Database db;
  late final BrainwireBlocklistSyncService service;
  bool connected = true;
  int time = 1000;
  int applies = 0;

  Future<void> domain(String id, String host) =>
      db.insert('domains', <String, Object?>{
        'id': id,
        'host': host,
        'schedule_id': 's',
        'created_at': 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<Database> _database() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      singleInstance: false,
      version: 1,
      onCreate: (Database db, int _) async {
        await db.execute(
          'CREATE TABLE schedules (id TEXT PRIMARY KEY, name TEXT NOT NULL, enabled INTEGER DEFAULT 1, created_at INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE schedule_slots (id TEXT PRIMARY KEY, schedule_id TEXT NOT NULL, day INTEGER NOT NULL, start_minute INTEGER NOT NULL, end_minute INTEGER NOT NULL, created_at INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE domains (id TEXT PRIMARY KEY, host TEXT NOT NULL, schedule_id TEXT, created_at INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE keywords (id TEXT PRIMARY KEY, pattern TEXT NOT NULL, schedule_id TEXT, created_at INTEGER NOT NULL)',
        );
        await db.execute(
          "CREATE TABLE search_query_blocks (id TEXT PRIMARY KEY, term TEXT NOT NULL, match TEXT NOT NULL DEFAULT 'contains', enabled INTEGER DEFAULT 1, scope TEXT DEFAULT 'all_browsers', schedule_id TEXT, created_at INTEGER NOT NULL)",
        );
        await db.execute(
          "CREATE TABLE serp_filters (id TEXT PRIMARY KEY, host_suffix TEXT NOT NULL, path_prefix TEXT NOT NULL, remove_selectors_json TEXT NOT NULL DEFAULT '[]', enabled INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)",
        );
        await db.execute(
          'CREATE TABLE blocked_apps (id TEXT PRIMARY KEY, schedule_id TEXT NOT NULL, name TEXT NOT NULL, bundle_id TEXT, created_at INTEGER NOT NULL, deleted_at INTEGER)',
        );
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late _Cloud cloud;
  late _Device a;
  late _Device b;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    cloud = _Cloud();
    a = _Device(await _database(), cloud, 'a');
    b = _Device(await _database(), cloud, 'b');
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
    cloud.client.close();
  });

  test(
    'disconnect during GET cancels upload, download and baseline writes',
    () async {
      await b.domain('remote', 'remote.example');
      await b.service.syncNow();
      await a.domain('local', 'local.example');
      final writes = cloud.writes;
      cloud.beforeNextRead = () => a.service.disconnect();
      await a.service.syncNow();
      expect(cloud.writes, writes);
      expect((await a.db.query('domains')).single['host'], 'local.example');
      expect(a.applies, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('baseline-a'), isNull);
      expect(a.service.status, '연결 해제됨');
      expect(await a.service.isConnected, isFalse);
      await a.service.syncNow();
      expect(cloud.writes, writes);
    },
  );

  test(
    'disconnect while PUT is in flight does not apply returned cloud rules',
    () async {
      await b.domain('remote', 'remote.example');
      await b.service.syncNow();
      await a.domain('local', 'local.example');
      cloud.beforeNextWrite = () => a.service.disconnect();
      await a.service.syncNow();
      // A request already sent can commit remotely; its response cannot reattach.
      expect((await a.db.query('domains')).single['host'], 'local.example');
      expect(a.applies, 0);
      expect(
        (await SharedPreferences.getInstance()).getString('baseline-a'),
        isNull,
      );
      expect(a.service.status, '연결 해제됨');
      expect(await a.service.isConnected, isFalse);
    },
  );

  test('search query rules round-trip edits, disable and deletion', () async {
    await a.db.insert('search_query_blocks', <String, Object?>{
      'id': 'query',
      'term': '섹시',
      'match': 'contains',
      'enabled': 1,
      'scope': 'all_browsers',
      'schedule_id': null,
      'created_at': 1,
    });
    await a.service.syncNow();
    b.time = 2000;
    await b.service.syncNow();
    expect(
      await b.db.query('search_query_blocks'),
      await a.db.query('search_query_blocks'),
    );
    await b.db.update(
      'search_query_blocks',
      {'term': '엉덩이', 'enabled': 0},
      where: 'id = ?',
      whereArgs: ['query'],
    );
    await b.service.syncNow();
    a.time = 3000;
    await a.service.syncNow();
    expect((await a.db.query('search_query_blocks')).single['term'], '엉덩이');
    expect((await a.db.query('search_query_blocks')).single['enabled'], 0);
    await a.db.delete(
      'search_query_blocks',
      where: 'id = ?',
      whereArgs: ['query'],
    );
    await a.service.syncNow();
    b.time = 4000;
    await b.service.syncNow();
    expect(await b.db.query('search_query_blocks'), isEmpty);
    final writes = cloud.writes;
    await a.service.syncNow();
    await b.service.syncNow();
    expect(cloud.writes, writes);
  });

  test(
    'SERP rules round-trip selectors, enable state, edits and deletion',
    () async {
      await a.db.insert('serp_filters', {
        'id': 'serp-rule',
        'host_suffix': 'google.com',
        'path_prefix': '/search',
        'remove_selectors_json': '[".fixture-result"]',
        'enabled': 1,
        'created_at': 1,
      });
      await a.service.syncNow();
      b.time = 2000;
      await b.service.syncNow();
      expect(
        await b.db.query('serp_filters'),
        await a.db.query('serp_filters'),
      );
      await b.db.update(
        'serp_filters',
        {
          'remove_selectors_json': '[".changed-result",".second-result"]',
          'enabled': 0,
        },
        where: 'id = ?',
        whereArgs: ['serp-rule'],
      );
      await b.service.syncNow();
      a.time = 3000;
      await a.service.syncNow();
      final downloaded = (await a.db.query('serp_filters')).single;
      expect(downloaded['enabled'], 0);
      expect(
        downloaded['remove_selectors_json'],
        '[".changed-result",".second-result"]',
      );
      await a.db.delete(
        'serp_filters',
        where: 'id = ?',
        whereArgs: ['serp-rule'],
      );
      await a.service.syncNow();
      b.time = 4000;
      await b.service.syncNow();
      expect(await b.db.query('serp_filters'), isEmpty);
      final writes = cloud.writes;
      await a.service.syncNow();
      await b.service.syncNow();
      expect(
        cloud.writes,
        writes,
        reason: 'Deleted rules must not reappear or churn timestamps',
      );
    },
  );

  test('newer cloud table survives an older client local update', () async {
    cloud.document['focusFenseSyncV1'] = {
      'schemaVersion': 1,
      'tables': {
        'future_rules': {
          'opaque': ['keep', 1],
        },
      },
    };
    await a.domain('d', 'blocked.example');
    await a.service.syncNow();
    expect(cloud.document['focusFenseSyncV1']['tables']['future_rules'], {
      'opaque': ['keep', 1],
    });
    final writes = cloud.writes;
    await a.service.syncNow();
    expect(cloud.writes, writes);
  });

  test(
    'two devices share schedules, slots, websites, keywords and apps in both directions',
    () async {
      await a.db.insert('schedules', <String, Object?>{
        'id': 's',
        'name': 'Focus',
        'enabled': 1,
        'created_at': 1,
      });
      await a.db.insert('schedule_slots', <String, Object?>{
        'id': 'slot',
        'schedule_id': 's',
        'day': 1,
        'start_minute': 540,
        'end_minute': 600,
        'created_at': 1,
      });
      await a.domain('d', 'blocked.example');
      await a.db.insert('keywords', <String, Object?>{
        'id': 'k',
        'pattern': 'casino',
        'schedule_id': 's',
        'created_at': 1,
      });
      await a.db.insert('blocked_apps', <String, Object?>{
        'id': 'app',
        'schedule_id': 's',
        'name': 'test-game.exe',
        'bundle_id': null,
        'created_at': 1,
        'deleted_at': null,
      });
      await a.service.syncNow();
      b.time = 2000;
      await b.service.syncNow();
      for (final String table in <String>[
        'schedules',
        'schedule_slots',
        'domains',
        'keywords',
        'blocked_apps',
      ]) {
        expect(await b.db.query(table), await a.db.query(table), reason: table);
      }
      expect(b.applies, 1);
      b.time = 3000;
      await b.domain('d', 'updated.example');
      await b.db.update('schedule_slots', <String, Object?>{'end_minute': 660});
      await b.service.syncNow();
      a.time = 4000;
      await a.service.syncNow();
      expect((await a.db.query('domains')).single['host'], 'updated.example');
      expect((await a.db.query('schedule_slots')).single['end_minute'], 660);
      expect(cloud.document['unrelated'], <String, dynamic>{'keep': true});
      final int writes = cloud.writes;
      await a.service.syncNow();
      await b.service.syncNow();
      expect(
        cloud.writes,
        writes,
        reason: 'Unchanged state must not upload again',
      );
    },
  );

  test(
    'deleted records remain deleted across repeated syncs and a fresh device',
    () async {
      await a.domain('d', 'remove.example');
      await a.service.syncNow();
      await b.service.syncNow();
      a.time = 2000;
      await a.db.delete('domains');
      await a.service.syncNow();
      await b.service.syncNow();
      expect(await b.db.query('domains'), isEmpty);
      final int writes = cloud.writes;
      b.time = 3000;
      await b.service.syncNow();
      a.time = 4000;
      await a.service.syncNow();
      expect(
        cloud.writes,
        writes,
        reason: 'Tombstones must not gain new timestamps or change signatures',
      );
      final _Device c = _Device(await _database(), cloud, 'c');
      try {
        await c.service.syncNow();
        await c.service.syncNow();
        expect(await c.db.query('domains'), isEmpty);
        expect(cloud.writes, writes);
      } finally {
        await c.db.close();
      }
    },
  );

  test(
    'edits and deletions during HTTP are kept and uploaded on the next sync',
    () async {
      await a.domain('edit', 'old.example');
      await a.domain('delete', 'old-delete.example');
      await a.service.syncNow();
      await b.service.syncNow();
      b.time = 2000;
      await b.domain('edit', 'remote.example');
      await b.service.syncNow();
      cloud.beforeNextRead = () async {
        await a.domain('edit', 'local-new.example');
        await a.db.delete(
          'domains',
          where: 'id = ?',
          whereArgs: <Object>['delete'],
        );
      };
      a.time = 3000;
      await expectLater(a.service.syncNow(), throwsStateError);
      expect((await a.db.query('domains')).single['host'], 'local-new.example');
      a.time = 4000;
      await a.service.syncNow();
      await b.service.syncNow();
      expect((await b.db.query('domains')).single['host'], 'local-new.example');
    },
  );

  test('a concurrent schedule change defers every downloaded table', () async {
    await a.db.insert('schedules', <String, Object?>{
      'id': 's',
      'name': 'Focus',
      'enabled': 1,
      'created_at': 1,
    });
    await a.service.syncNow();
    await b.service.syncNow();
    b.time = 2000;
    await b.db.insert('schedule_slots', <String, Object?>{
      'id': 'new-slot',
      'schedule_id': 's',
      'day': 1,
      'start_minute': 540,
      'end_minute': 600,
      'created_at': 1,
    });
    await b.service.syncNow();
    cloud.beforeNextRead = () async {
      await a.db.update('schedules', <String, Object?>{'enabled': 0});
    };
    await expectLater(a.service.syncNow(), throwsStateError);
    expect(await a.db.query('schedule_slots'), isEmpty);
    expect((await a.db.query('schedules')).single['enabled'], 0);
    a.time = 4000;
    await a.service.syncNow();
    expect(await a.db.query('schedule_slots'), hasLength(1));
    expect((await a.db.query('schedules')).single['enabled'], 0);
  });

  test('deletion wins when an offline edit has the same timestamp', () async {
    await a.domain('d', 'old.example');
    await a.service.syncNow();
    await b.service.syncNow();
    a.time = b.time = 2000;
    await a.db.delete('domains');
    await b.domain('d', 'offline-edit.example');
    await b.service.syncNow();
    await a.service.syncNow();
    await b.service.syncNow();
    expect(await a.db.query('domains'), isEmpty);
    expect(await b.db.query('domains'), isEmpty);
    final int writes = cloud.writes;
    await a.service.syncNow();
    await b.service.syncNow();
    expect(cloud.writes, writes);
  });

  test(
    'a revision conflict refetches and preserves other cloud fields',
    () async {
      await a.domain('d', 'blocked.example');
      cloud.conflictNextWrite = true;
      await a.service.syncNow();
      expect(cloud.document['concurrentField'], 'preserved');
      expect(cloud.writes, 1);
      await b.service.syncNow();
      expect((await b.db.query('domains')).single['host'], 'blocked.example');
    },
  );

  test(
    'a bad remote rule rolls back all downloaded tables and retains the baseline',
    () async {
      await a.db.insert('schedules', <String, Object?>{
        'id': 's',
        'name': 'Focus',
        'created_at': 1,
      });
      await a.domain('d', 'valid.example');
      await a.service.syncNow();
      final dynamic tables = cloud.document['focusFenseSyncV1']['tables'];
      tables['domains']['d']['row']['host'] = null;
      await expectLater(b.service.syncNow(), throwsA(isA<DatabaseException>()));
      expect(await b.db.query('schedules'), isEmpty);
      expect(await b.db.query('domains'), isEmpty);
      expect(b.applies, 0);
      expect(
        (await SharedPreferences.getInstance()).getString('baseline-b'),
        isNull,
      );
    },
  );

  test(
    'offline sync reports an error and releases the busy state for retry',
    () async {
      await a.domain('d', 'blocked.example');
      cloud.offline = true;
      await expectLater(
        a.service.syncNow(),
        throwsA(isA<http.ClientException>()),
      );
      expect(a.service.status, contains('동기화 오류'));
      cloud.offline = false;
      await a.service.syncNow();
      expect(cloud.writes, 1);
    },
  );
}
