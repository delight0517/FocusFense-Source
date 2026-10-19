import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

typedef ControlRunner =
    Future<Map<String, Object?>> Function(
      String action,
      Map<String, Object?> arguments,
    );

/// Authenticated, loopback-only automation. Browser origins cannot invoke it.
class LocalControlApi {
  LocalControlApi({
    required this.token,
    required this.actions,
    required this.runAction,
    required this.readStatus,
    this.schemas = const {},
    this.validateArguments,
    this.readResource,
  });

  final Future<String> Function() token;
  final Map<String, String> actions;
  final ControlRunner runAction;
  final Future<Map<String, Object?>> Function() readStatus;
  final Map<String, Object?> schemas;
  final void Function(String, Map<String, Object?>)? validateArguments;
  final Future<Object?> Function(String, int, int)? readResource;
  final Map<String, Map<String, Object?>> _jobs = {};
  bool _busy = false;

  static Future<String> loadOrCreateToken(File file) async {
    if (await file.exists()) {
      final value = (await file.readAsString()).trim();
      if (value.length >= 32) return value;
      throw StateError('Invalid local control token file');
    }
    await file.parent.create(recursive: true);
    final random = Random.secure();
    final value = base64Url.encode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await file.writeAsString(value, flush: true);
    return value;
  }

  static bool _equal(String a, String b) {
    var difference = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> handle(HttpRequest request) async {
    Future<void> reply(int code, Map<String, Object?> body) async {
      request.response.statusCode = code;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    }

    final remote = request.connectionInfo?.remoteAddress;
    String credential;
    try {
      credential = await token();
    } catch (_) {
      await reply(503, {'ok': false, 'error': 'local_control_not_ready'});
      return;
    }
    if (remote?.isLoopback != true ||
        request.headers.value('origin') != null ||
        !_equal(
          request.headers.value(HttpHeaders.authorizationHeader) ?? '',
          'Bearer $credential',
        )) {
      await reply(403, {'ok': false, 'error': 'local_control_auth_required'});
      return;
    }
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/control/actions') {
        await reply(200, {'ok': true, 'actions': actions});
      } else if (request.method == 'GET' && path == '/control/schema') {
        await reply(200, {
          'ok': true,
          'apiVersion': 2,
          'actions': actions,
          ...schemas,
        });
      } else if (request.method == 'GET' &&
          path.startsWith('/control/state/') &&
          readResource != null) {
        final offset = int.parse(request.uri.queryParameters['offset'] ?? '0');
        final limit = int.parse(request.uri.queryParameters['limit'] ?? '100');
        if (offset < 0 || limit < 1 || limit > 500)
          throw const FormatException('Invalid pagination');
        await reply(200, {
          'ok': true,
          'resource': path.substring(15),
          'offset': offset,
          'limit': limit,
          'data': await readResource!(path.substring(15), offset, limit),
        });
      } else if (request.method == 'GET' && path == '/control/status') {
        await reply(200, {'ok': true, ...await readStatus(), 'busy': _busy});
      } else if (request.method == 'GET' && path.startsWith('/control/jobs/')) {
        final job = _jobs[path.substring('/control/jobs/'.length)];
        await reply(
          job == null ? 404 : 200,
          job == null
              ? {'ok': false, 'error': 'job_not_found'}
              : {'ok': true, 'job': job},
        );
      } else if (request.method == 'POST' && path == '/control/run') {
        final bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
          if (bytes.length > 16384)
            throw const FormatException('Request too large');
        }
        final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final action = body['action'] as String? ?? '';
        if (!actions.containsKey(action)) {
          await reply(400, {'ok': false, 'error': 'unknown_action'});
          return;
        }
        final args = Map<String, Object?>.from(body['arguments'] as Map? ?? {});
        validateArguments?.call(action, args);
        if (body['dryRun'] == true) {
          await reply(200, {
            'ok': true,
            'dryRun': true,
            'action': action,
            'description': actions[action],
            'arguments': args,
          });
          return;
        }
        if (_busy) {
          await reply(409, {'ok': false, 'error': 'action_in_progress'});
          return;
        }
        while (_jobs.length >= 20) {
          _jobs.remove(_jobs.keys.first);
        }
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        final job = <String, Object?>{
          'id': id,
          'action': action,
          'state': 'running',
          'startedAt': DateTime.now().toUtc().toIso8601String(),
        };
        _jobs[id] = job;
        _busy = true;
        unawaited(() async {
          try {
            final result = await runAction(action, args);
            job['result'] = result;
            job['state'] = result['ok'] == false ? 'failed' : 'succeeded';
          } catch (_) {
            job['state'] = 'failed';
            job['error'] = 'action_failed_see_app_report';
          } finally {
            job['finishedAt'] = DateTime.now().toUtc().toIso8601String();
            _busy = false;
          }
        }());
        await reply(202, {'ok': true, 'jobId': id});
      } else {
        await reply(404, {'ok': false, 'error': 'control_route_not_found'});
      }
    } catch (_) {
      await reply(400, {'ok': false, 'error': 'invalid_control_request'});
    }
  }
}
