import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/local_control_api.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  var calls = 0;
  Completer<Map<String, Object?>>? pending;
  Future<Map<String, dynamic>> call(
    String path, {
    String method = 'GET',
    String? auth = 'Bearer fixture-secret',
    String? origin,
    Object? body,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (auth != null) req.headers.set('authorization', auth);
    if (origin != null) req.headers.set('origin', origin);
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    return {
      'status': res.statusCode,
      'body': jsonDecode(await utf8.decoder.bind(res).join()),
    };
  }

  setUp(() async {
    calls = 0;
    pending = null;
    final api = LocalControlApi(
      token: () async => 'fixture-secret',
      actions: {'test': 'fixture action'},
      schemas: {
        'resources': ['policy'],
      },
      validateArguments: (_, args) {
        if (args.isNotEmpty) throw const FormatException('No arguments');
      },
      readResource: (name, offset, limit) async {
        if (name != 'policy') throw const FormatException('Unknown resource');
        return {'offset': offset, 'limit': limit};
      },
      readStatus: () async => {'enabled': false},
      runAction: (_, _) async {
        calls++;
        return pending?.future ?? Future.value({'ok': true});
      },
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(api.handle);
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    pending?.complete({'ok': true});
    pending = null;
    client.close(force: true);
    await server.close(force: true);
  });
  test(
    'schema and paged state remain authenticated and validate before preview',
    () async {
      expect((await call('/control/schema', auth: null))['status'], 403);
      expect((await call('/control/state/policy', auth: null))['status'], 403);
      expect((await call('/control/schema'))['body']['resources'], ['policy']);
      final state = await call('/control/state/policy?offset=2&limit=5');
      expect(state['body']['resource'], 'policy');
      expect(state['body']['data']['offset'], 2);
      expect((await call('/control/state/policy?limit=501'))['status'], 400);
      expect((await call('/control/state/missing'))['status'], 400);
      expect(
        (await call(
          '/control/run',
          method: 'POST',
          body: {
            'action': 'test',
            'arguments': {'unknown': true},
            'dryRun': true,
          },
        ))['status'],
        400,
      );
      expect(calls, 0);
    },
  );
  test(
    'rejects unauthenticated calls and browser origins, including with valid token',
    () async {
      expect((await call('/control/status', auth: null))['status'], 403);
      expect(
        (await call(
          '/control/status',
          origin: 'https://example.com',
        ))['status'],
        403,
      );
      expect((await call('/control/status'))['status'], 200);
    },
  );
  test('dry run and unknown actions do not invoke the app', () async {
    expect(
      (await call(
        '/control/run',
        method: 'POST',
        body: {'action': 'test', 'dryRun': true},
      ))['status'],
      200,
    );
    expect(
      (await call(
        '/control/run',
        method: 'POST',
        body: {'action': 'missing'},
      ))['status'],
      400,
    );
    expect(calls, 0);
  });
  test(
    'serializes mutations and exposes failure without claiming success',
    () async {
      pending = Completer<Map<String, Object?>>();
      final started = await call(
        '/control/run',
        method: 'POST',
        body: {'action': 'test'},
      );
      expect(started['status'], 202);
      expect(
        (await call(
          '/control/run',
          method: 'POST',
          body: {'action': 'test'},
        ))['status'],
        409,
      );
      pending!.complete({'ok': false});
      pending = null;
      final job = await call('/control/jobs/${started['body']['jobId']}');
      expect(job['body']['job']['state'], 'failed');
      expect(calls, 1);
    },
  );
  test(
    'token is stable across loads and invalid token files are preserved',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'focusfense-control-test',
      );
      try {
        final file = File('${dir.path}/token');
        final first = await LocalControlApi.loadOrCreateToken(file);
        expect(first.length, greaterThanOrEqualTo(32));
        expect(await LocalControlApi.loadOrCreateToken(file), first);
        await file.writeAsString('invalid');
        await expectLater(
          LocalControlApi.loadOrCreateToken(file),
          throwsStateError,
        );
        expect(await file.readAsString(), 'invalid');
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
