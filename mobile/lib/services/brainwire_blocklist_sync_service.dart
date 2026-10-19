import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'auth_browser_launcher.dart';

import 'local_database.dart';
import 'block_sync_service.dart';

/// Private, app-owned Brainwire BlueCloud sync for schedules and blocking rules.
/// Sync pauses while the app
/// is backgrounded and the OS lifecycle resumes it automatically.
final class BrainwireBlocklistSyncService with WidgetsBindingObserver {
  BrainwireBlocklistSyncService._();

  /// Runs the production sync path against isolated databases and transport.
  BrainwireBlocklistSyncService.forTesting({
    required Database database,
    required http.Client client,
    required Future<String?> Function() readToken,
    required Future<void> Function() clearToken,
    required String baselineKey,
    required void Function() onRulesChanged,
    required DateTime Function() clock,
  }) : _databaseOverride = database,
       _clientOverride = client,
       _readTokenOverride = readToken,
       _clearTokenOverride = clearToken,
       _baselineStorageKey = baselineKey,
       _onRulesChangedOverride = onRulesChanged,
       _clockOverride = clock;

  Database? _databaseOverride;
  http.Client? _clientOverride;
  Future<String?> Function()? _readTokenOverride;
  Future<void> Function()? _clearTokenOverride;
  int _sessionGeneration = 0;
  String _baselineStorageKey = _baselineKey;
  void Function()? _onRulesChangedOverride;
  DateTime Function()? _clockOverride;
  DateTime _now() => _clockOverride?.call() ?? DateTime.now();

  Future<String?> _readToken() =>
      _readTokenOverride?.call() ?? _secure.read(key: _tokenKey);
  static final BrainwireBlocklistSyncService instance =
      BrainwireBlocklistSyncService._();

  static const String _brainwireBase = 'https://brainwire-f2gf.onrender.com';
  static const String _appId = 'focus-fense';
  static const String _cloudAppHeader = 'focus-fense';
  static const String _tokenKey = 'focus_fense_brainwire_jwt_v1';
  static const String _accountKey = 'focus_fense_brainwire_account_v1';
  static const String _baselineKey = 'focus_fense_brainwire_sync_baseline_v1';
  static const String _collection = 'focusFenseSyncV1';
  static const String _googleAuthEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const String _googleTokenEndpoint =
      'https://oauth2.googleapis.com/token';
  static const List<String> _syncTables = <String>[
    'schedules',
    'schedule_slots',
    'domains',
    'keywords',
    'search_query_blocks',
    'serp_filters',
    'blocked_apps',
  ];
  static const List<String> _scopes = <String>['openid', 'email', 'profile'];
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  Timer? _timer;
  bool _resumed = true;
  bool _busy = false;
  String? _status;

  String? get status => _status;

  void startAutoSync() {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
    if (_timer != null) return;
    WidgetsBinding.instance.addObserver(this);
    // One-minute cross-device freshness; each tick makes one GET and performs
    // at most one PUT when merged rules changed, with no child processes.
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (_resumed) _syncInBackground();
    });
    _syncInBackground();
  }

  void _syncInBackground() {
    // Network/auth failures are reported through status. A background timer
    // must not turn a recoverable offline state into an unhandled exception.
    unawaited(syncNow().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) _syncInBackground();
  }

  Future<bool> get isConnected async =>
      (await _readToken())?.isNotEmpty == true;

  Future<void> connectAndSync() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      throw UnsupportedError('BlueCloud 동기화는 현재 데스크톱에서 지원합니다.');
    }
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Uri redirect = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
    );
    final String state = _random(32);
    final String verifier = _random(64);
    final String challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    final Completer<HttpRequest> callback = Completer<HttpRequest>();
    final StreamSubscription<HttpRequest> listener = server.listen((
      HttpRequest request,
    ) {
      if (request.uri.path != '/') {
        request.response.statusCode = HttpStatus.notFound;
        unawaited(request.response.close());
      } else if (!callback.isCompleted) {
        callback.complete(request);
      }
    });
    try {
      final Map<String, dynamic> clientInfo = await _request(
        'GET',
        '/api/auth/google-client-id?platform=desktop',
        authenticate: false,
      );
      final String? clientId = clientInfo['clientId'] as String?;
      final String? clientSecret = clientInfo['clientSecret'] as String?;
      if (clientInfo['configured'] != true ||
          clientId == null ||
          clientId.isEmpty) {
        throw StateError('BlueCloud 데스크톱 Google 로그인이 서버에 설정되지 않았습니다.');
      }
      final Uri auth = Uri.parse(_googleAuthEndpoint).replace(
        queryParameters: <String, String>{
          'client_id': clientId,
          'redirect_uri': redirect.toString(),
          'response_type': 'code',
          'scope': _scopes.join(' '),
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': state,
          'prompt': 'select_account',
        },
      );
      if (!await launchAccountAuthorization(auth)) {
        throw StateError('기본 브라우저를 열 수 없습니다.');
      }
      final HttpRequest request = await callback.future.timeout(
        const Duration(minutes: 5),
      );
      final Map<String, String> query = request.uri.queryParameters;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<html><body>BlueCloud 로그인 완료. 이 창을 닫고 Focus Fense로 돌아오세요.</body></html>',
        );
      await request.response.close();
      if (query['state'] != state) {
        throw StateError('Google OAuth state 검증에 실패했습니다.');
      }
      if (query['error'] != null) {
        throw StateError('Google 로그인 실패: ${query['error']}');
      }
      final String? code = query['code'];
      if (code == null) throw StateError('Google 인증 코드가 없습니다.');
      final Map<String, dynamic> googleToken =
          await _postForm(Uri.parse(_googleTokenEndpoint), <String, String>{
            'client_id': clientId,
            if (clientSecret != null && clientSecret.isNotEmpty)
              'client_secret': clientSecret,
            'code': code,
            'code_verifier': verifier,
            'redirect_uri': redirect.toString(),
            'grant_type': 'authorization_code',
          });
      final String? idToken = googleToken['id_token'] as String?;
      if (idToken == null || idToken.isEmpty) {
        throw StateError('Google ID 토큰을 받지 못했습니다.');
      }
      final Map<String, dynamic> account = await _request(
        'POST',
        '/api/auth/google',
        body: <String, Object?>{'idToken': idToken},
        authenticate: false,
      );
      final String? jwt = account['token'] as String?;
      final Object? user = account['user'];
      final String? username = user is Map ? user['username'] as String? : null;
      if (jwt == null || jwt.isEmpty || username == null || username.isEmpty) {
        throw StateError('BlueCloud 계정 로그인 응답이 올바르지 않습니다.');
      }
      await _secure.write(key: _tokenKey, value: jwt);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accountKey, username);
      _status = 'BlueCloud 계정 연결됨 · $username';
      await syncNow();
    } finally {
      await listener.cancel();
      await server.close(force: true);
    }
  }

  Future<void> disconnect() async {
    // Invalidate in-flight work before awaiting secure storage or preferences.
    _sessionGeneration++;
    if (_clearTokenOverride != null) {
      await _clearTokenOverride!();
    } else {
      await _secure.delete(key: _tokenKey);
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accountKey);
    await prefs.remove(_baselineStorageKey);
    _status = '연결 해제됨';
  }

  Future<void> syncNow() async {
    if (_busy) return;
    _busy = true;
    final int generation = _sessionGeneration;
    try {
      final String? token = await _readToken();
      if (generation != _sessionGeneration || token == null || token.isEmpty) {
        return;
      }
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> baseline = _readBaseline(prefs);
      final Database db =
          _databaseOverride ?? await LocalDatabase.instance.database;
      final Map<String, dynamic> local = <String, dynamic>{};
      await db.transaction((Transaction txn) async {
        for (final String table in _syncTables) {
          local[table] = await _localRecords(txn, table, baseline[table]);
        }
      });
      final Map<String, dynamic> mergedBaseline = <String, dynamic>{};
      final List<Map<String, dynamic>> mergedByTable =
          List<Map<String, dynamic>>.filled(
            _syncTables.length,
            <String, dynamic>{},
          );
      bool uploaded = false;
      for (int attempt = 0; attempt < 2; attempt++) {
        final Map<String, dynamic> response = await _request(
          'GET',
          '/api/cloud-state/$_appId',
          token: token,
        );
        if (generation != _sessionGeneration) return;
        final Map<String, dynamic> document = response['state'] is Map
            ? (response['state'] as Map).cast<String, dynamic>()
            : <String, dynamic>{'_rev': 0};
        final Map<String, dynamic> current = document[_collection] is Map
            ? (document[_collection] as Map).cast<String, dynamic>()
            : <String, dynamic>{};
        final Map<String, dynamic> mergedCollection = <String, dynamic>{
          'schemaVersion': 1,
          'updatedAt': _now().toUtc().toIso8601String(),
          'tables': <String, dynamic>{},
        };
        final Map<String, dynamic> currentTables = current['tables'] is Map
            ? (current['tables'] as Map).cast<String, dynamic>()
            : <String, dynamic>{};
        final Map<String, dynamic> mergedTables =
            mergedCollection['tables'] as Map<String, dynamic>;
        // Preserve collections written by newer clients during mixed-version sync.
        mergedTables.addAll(currentTables);
        for (int index = 0; index < _syncTables.length; index++) {
          final String table = _syncTables[index];
          final Map<String, dynamic> merged = _mergeRecords(
            local[table] as Map<String, dynamic>,
            _remoteRecords(table, currentTables[table]),
          );
          mergedByTable[index] = merged;
          mergedTables[table] = merged;
          mergedBaseline[table] = _makeBaseline(merged);
        }
        final bool changed =
            _stableJson(mergedTables) != _stableJson(currentTables);
        if (!changed) break;
        final Map<String, dynamic> next = <String, dynamic>{
          ...document,
          '_rev': (document['_rev'] as num?)?.toInt() ?? 0,
          _collection: mergedCollection,
        };
        try {
          if (generation != _sessionGeneration) return;
          await _request(
            'PUT',
            '/api/cloud-state/$_appId',
            token: token,
            body: next,
          );
          uploaded = true;
          break;
        } on _BrainwireConflict {
          if (attempt == 1) rethrow;
        }
      }
      if (generation != _sessionGeneration) return;
      bool databaseChanged = false;
      // All tables commit together so an invalid remote row cannot leave a
      // downloaded schedule with only part of its rules or time slots.
      await db.transaction((Transaction txn) async {
        if (generation != _sessionGeneration) {
          throw StateError('Cloud session changed during sync.');
        }
        // Validate the whole snapshot, including parent schedules. Per-row
        // skipping could otherwise download a new slot under a schedule the
        // user deleted while waiting for the HTTP response.
        for (final String table in _syncTables) {
          final List<Map<String, Object?>> rows = await txn.query(table);
          final Map<String, String> current = <String, String>{
            for (final Map<String, Object?> row in rows)
              row['id']! as String: _rowSignature(row),
          };
          final Map<String, String> captured = <String, String>{
            for (final MapEntry<String, dynamic> entry
                in (local[table] as Map<String, dynamic>).entries)
              if ((entry.value as Map)['deleted'] != true)
                entry.key: (entry.value as Map)['signature'] as String,
          };
          if (_stableJson(current) != _stableJson(captured)) {
            throw StateError(
              '동기화 중 로컬 규칙이 변경됐습니다. 변경 내용을 보존했으며 다음 동기화에서 다시 병합합니다.',
            );
          }
        }
        for (int index = 0; index < _syncTables.length; index++) {
          final String table = _syncTables[index];
          databaseChanged =
              await _applyRecords(txn, table, mergedByTable[index]) ||
              databaseChanged;
          if (generation != _sessionGeneration) {
            throw StateError('Cloud session changed during sync.');
          }
        }
      });
      if (generation != _sessionGeneration) return;
      if (databaseChanged) {
        if (_onRulesChangedOverride != null) {
          _onRulesChangedOverride!();
        } else {
          BlockSyncService.instance.requestApply();
        }
      }
      await prefs.setString(_baselineStorageKey, jsonEncode(mergedBaseline));
      final String? account = prefs.getString(_accountKey);
      _status =
          'BlueCloud 양방향 동기화 완료 · ${account ?? '계정'}'
          '${uploaded ? '' : ' · 변경 없음'}';
    } catch (error) {
      if (generation != _sessionGeneration) return;
      _status = '동기화 오류: $error';
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    String? token,
    Map<String, Object?>? body,
    bool authenticate = true,
  }) async {
    final http.Request request = http.Request(
      method,
      Uri.parse('$_brainwireBase$path'),
    );
    request.headers['content-type'] = 'application/json';
    request.headers['x-cloud-app'] = _cloudAppHeader;
    if (authenticate && token != null) {
      request.headers['authorization'] = 'Bearer $token';
    }
    if (body != null) request.body = jsonEncode(body);
    final http.StreamedResponse streamed =
        await (_clientOverride?.send(request) ?? request.send()).timeout(
          const Duration(seconds: 35),
        );
    final String raw = await streamed.stream.bytesToString().timeout(
      const Duration(seconds: 35),
    );
    final dynamic decoded = raw.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw);
    if (streamed.statusCode == 401 && authenticate) {
      throw StateError('BlueCloud 세션이 만료되었습니다. Google 계정을 다시 연결해 주세요.');
    }
    if (streamed.statusCode == 409) {
      throw _BrainwireConflict(
        decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{},
      );
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final String message = decoded is Map && decoded['message'] is String
          ? decoded['message'] as String
          : 'HTTP ${streamed.statusCode}';
      throw StateError('BlueCloud 요청 실패: $message');
    }
    return decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _postForm(
    Uri uri,
    Map<String, String> fields,
  ) async {
    final http.Response response = await http
        .post(uri, body: fields)
        .timeout(const Duration(seconds: 35));
    final dynamic decoded = response.body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Google 인증 코드 교환 실패 (HTTP ${response.statusCode}).');
    }
    return decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _localRecords(
    DatabaseExecutor db,
    String table,
    Object? rawBaseline,
  ) async {
    final Map<String, dynamic> previous = rawBaseline is Map
        ? rawBaseline.cast<String, dynamic>()
        : <String, dynamic>{};
    final List<Map<String, Object?>> rows = await db.query(table);
    final Map<String, dynamic> result = <String, dynamic>{};
    final int now = _now().millisecondsSinceEpoch;
    for (final Map<String, Object?> row in rows) {
      final String? id = row['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final String signature = _rowSignature(row);
      final Map<String, dynamic>? old = previous[id] is Map
          ? (previous[id] as Map).cast<String, dynamic>()
          : null;
      result[id] = <String, dynamic>{
        'row': row,
        'deleted': false,
        'signature': signature,
        'updatedAt': old != null && old['signature'] == signature
            ? (old['updatedAt'] as num?)?.toInt() ?? 0
            : now,
      };
    }
    for (final MapEntry<String, dynamic> entry in previous.entries) {
      if (result.containsKey(entry.key) || entry.value is! Map) continue;
      final Map<String, dynamic> old = (entry.value as Map)
          .cast<String, dynamic>();
      result[entry.key] = <String, dynamic>{
        'deleted': true,
        'signature': 'deleted',
        'updatedAt': old['signature'] == 'deleted'
            ? (old['updatedAt'] as num?)?.toInt() ?? now
            : now,
        if (old['row'] is Map) 'row': old['row'],
      };
    }
    return result;
  }

  Map<String, dynamic> _remoteRecords(String table, Object? raw) {
    final Map<String, dynamic> result = <String, dynamic>{};
    if (raw is! Map) return result;
    for (final MapEntry<dynamic, dynamic> entry in raw.entries) {
      if (entry.value is! Map) continue;
      final Map<String, dynamic> item = (entry.value as Map)
          .cast<String, dynamic>();
      if (item['row'] is Map || item['deleted'] == true) {
        final Map<String, dynamic>? row = item['row'] is Map
            ? (item['row'] as Map).cast<String, dynamic>()
            : null;
        result['${entry.key}'] = <String, dynamic>{
          'row': ?row,
          'deleted': item['deleted'] == true,
          'updatedAt': (item['updatedAt'] as num?)?.toInt() ?? 0,
          // Tombstones may retain the old row for diagnostics. Their identity
          // must still be "deleted", otherwise deletion timestamps churn.
          'signature': item['deleted'] == true || row == null
              ? 'deleted'
              : _rowSignature(row),
        };
        continue;
      }
      // Read the first-generation global-domain collection so users retain
      // existing shared lists during schema migration.
      if (table == 'domains' && item['host'] is String) {
        final String host = _normalize(item['host'] as String);
        if (host.isEmpty) continue;
        final int stamp = (item['updatedAt'] as num?)?.toInt() ?? 0;
        final String id =
            'drive_${sha256.convert(utf8.encode(host)).toString().substring(0, 24)}';
        final Map<String, dynamic> row = <String, dynamic>{
          'id': id,
          'host': host,
          'include_subdomains': item['includeSubdomains'] == false ? 0 : 1,
          'source': 'drive_sync',
          'enabled': item['enabled'] == false ? 0 : 1,
          'action': 'block_document',
          'created_at': stamp,
          'schedule_id': null,
          'deleted_at': item['deleted'] == true ? stamp : null,
          'is_stem': 0,
        };
        result[id] = <String, dynamic>{
          'row': row,
          'deleted': false,
          'updatedAt': stamp,
          'signature': _rowSignature(row),
        };
      }
    }
    return result;
  }

  Map<String, dynamic> _mergeRecords(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    final Map<String, dynamic> merged = <String, dynamic>{...remote};
    for (final MapEntry<String, dynamic> entry in local.entries) {
      final Map<String, dynamic> localItem = (entry.value as Map)
          .cast<String, dynamic>();
      final Map<String, dynamic>? remoteItem = remote[entry.key] is Map
          ? (remote[entry.key] as Map).cast<String, dynamic>()
          : null;
      final int localTime = (localItem['updatedAt'] as num?)?.toInt() ?? 0;
      final int remoteTime = (remoteItem?['updatedAt'] as num?)?.toInt() ?? -1;
      final String localSignature = '${localItem['signature'] ?? ''}';
      final String remoteSignature = '${remoteItem?['signature'] ?? ''}';
      // Equal timestamps can occur when two devices edit the same row before
      // syncing. A stable signature tie-break makes both devices converge on
      // the same row instead of each repeatedly preferring its local copy.
      if (remoteItem == null ||
          localTime > remoteTime ||
          (localTime == remoteTime &&
              ((localItem['deleted'] == true &&
                      remoteItem['deleted'] != true) ||
                  (localItem['deleted'] == remoteItem['deleted'] &&
                      localSignature.compareTo(remoteSignature) >= 0)))) {
        merged[entry.key] = localItem;
      }
    }
    return merged;
  }

  Future<bool> _applyRecords(
    DatabaseExecutor txn,
    String table,
    Map<String, dynamic> records,
  ) async {
    bool changed = false;
    final List<Map<String, Object?>> columns = await txn.rawQuery(
      'PRAGMA table_info($table)',
    );
    final Set<String> allowed = columns
        .map((Map<String, Object?> row) => row['name'] as String)
        .toSet();
    final List<Map<String, Object?>> currentRows = await txn.query(table);
    final Map<String, Map<String, Object?>> current =
        <String, Map<String, Object?>>{
          for (final Map<String, Object?> row in currentRows)
            if (row['id'] is String) row['id']! as String: row,
        };
    for (final MapEntry<String, dynamic> entry in records.entries) {
      if (entry.value is! Map) continue;
      final Map<String, dynamic> item = (entry.value as Map)
          .cast<String, dynamic>();
      final Map<String, Object?>? old = current[entry.key];
      if (item['deleted'] == true) {
        if (old != null) {
          await txn.delete(
            table,
            where: 'id = ?',
            whereArgs: <Object>[entry.key],
          );
          changed = true;
        }
        continue;
      }
      if (item['row'] is! Map) continue;
      final Map<String, Object?> row =
          (item['row'] as Map).cast<String, Object?>().map(
            (String key, Object? value) => MapEntry(key, value),
          )..removeWhere((String key, Object? _) => !allowed.contains(key));
      if (row['id'] != entry.key) continue;
      if (old != null && _rowSignature(old) == _rowSignature(row)) continue;
      await txn.insert(
        table,
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      changed = true;
    }
    return changed;
  }

  Map<String, dynamic> _makeBaseline(Map<String, dynamic> records) {
    return records.map((String id, dynamic value) {
      final Map<String, dynamic> item = (value as Map).cast<String, dynamic>();
      return MapEntry<String, dynamic>(id, <String, dynamic>{
        'signature': item['signature'] ?? 'deleted',
        'updatedAt': (item['updatedAt'] as num?)?.toInt() ?? 0,
        if (item['row'] is Map) 'row': item['row'],
      });
    });
  }

  String _rowSignature(Map<dynamic, dynamic> row) {
    return sha256.convert(utf8.encode(_stableJson(row))).toString();
  }

  String _stableJson(Object? value) => jsonEncode(_stableValue(value));

  Object? _stableValue(Object? value) {
    if (value is Map) {
      final List<String> keys = value.keys.cast<String>().toList()..sort();
      return <String, Object?>{
        for (final String key in keys) key: _stableValue(value[key]),
      };
    }
    if (value is List) return value.map(_stableValue).toList();
    return value;
  }

  Map<String, dynamic> _readBaseline(SharedPreferences prefs) {
    final String? raw = prefs.getString(_baselineStorageKey);
    if (raw == null) return <String, dynamic>{};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String _normalize(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceFirst(RegExp(r'^https?://'), '')
      .split('/')
      .first
      .replaceFirst(RegExp(r'^www\.'), '');
  String _random(int length) {
    final Random random = Random.secure();
    return base64Url
        .encode(List<int>.generate(length, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }
}

final class _BrainwireConflict implements Exception {
  const _BrainwireConflict(this.payload);
  final Map<String, dynamic> payload;
}
