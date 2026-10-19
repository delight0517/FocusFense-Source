import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        ContentType,
        HttpHeaders,
        HttpRequest,
        HttpServer,
        HttpStatus,
        InternetAddress,
        Platform;

import 'package:uuid/uuid.dart';

import 'app_logger.dart';
import 'app_control_actions.dart';
import 'block_activity_log_service.dart';
import 'cursor_agent_snapshot_service.dart';
import 'cursor_one_tap_diagnostic_pack_service.dart';
import 'extension_rules_builder.dart';
import 'youtube_budget_exemption_store.dart';
import 'extension_rules_snapshot_service.dart';
import 'chat_schedule_apply_service.dart';
import 'youtube_video_block_resolver.dart';
import 'local_database.dart';
import 'universal_browser_block_service.dart';
import 'recent_site_events.dart';
import 'usage_bucket_config_service.dart';
import 'usage_quota_enforcer_service.dart';

/// Loopback HTTP endpoint so the bundled browser extension can POST
/// `{ "host": "example.com", "seconds": 15 }` while this app is running.
final class UsageIngestServer {
  UsageIngestServer._()
    : _initialPort = kPort,
      _rulesProvider = null,
      _runtimeEnabled = null;
  UsageIngestServer.forTesting({
    required Future<ExtensionRulesPayload> Function(String?) rulesProvider,
    required bool Function(String?) runtimeEnabled,
  }) : _initialPort = 0,
       _rulesProvider = rulesProvider,
       _runtimeEnabled = runtimeEnabled;
  static final UsageIngestServer instance = UsageIngestServer._();

  static const int kPort = 17361;
  static const int _kPortSpan = 12;
  final int _initialPort;
  final Future<ExtensionRulesPayload> Function(String?)? _rulesProvider;
  final bool Function(String?)? _runtimeEnabled;

  HttpServer? _server;
  int _boundPort = kPort;
  static const Duration _kRulesApiSyncMinGap = Duration(seconds: 25);
  DateTime? _lastRulesApiSyncAt;
  Timer? _rulesApiSyncTimer;

  bool get isRunning => _server != null;

  /// Port actually bound after [start]; extensions default to [kPort].
  int get boundPort => _boundPort;

  Future<void> start() async {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    if (_server != null) return;
    if (_rulesProvider == null) {
      try {
        await AppControlActions.prepare();
      } catch (_) {
        AppLogger.instance.warn('local_control: credential file unavailable');
      }
    }
    Object? lastErr;
    for (int i = 0; i < _kPortSpan; i++) {
      final int port = _initialPort == 0 ? 0 : _initialPort + i;
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _boundPort = _server!.port;
        if (_rulesProvider == null) {
          AppLogger.instance.info(
            'usage_ingest: listening on 127.0.0.1:$_boundPort',
          );
        }
        _server!.listen(_handle);
        return;
      } catch (e) {
        lastErr = e;
        _server = null;
      }
    }
    AppLogger.instance.warn(
      'usage_ingest: bind failed (tried $kPort–${kPort + _kPortSpan - 1}): $lastErr',
    );
  }

  Future<void> stop() async {
    final HttpServer? s = _server;
    _server = null;
    _rulesApiSyncTimer?.cancel();
    _rulesApiSyncTimer = null;
    if (s != null) {
      await s.close(force: true);
      if (_rulesProvider == null) {
        AppLogger.instance.info('usage_ingest: stopped');
      }
    }
  }

  void _scheduleRulesApiSync() {
    if (!Platform.isWindows) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastRulesApiSyncAt;
    if (last == null || now.difference(last) >= _kRulesApiSyncMinGap) {
      _lastRulesApiSyncAt = now;
      UniversalBrowserBlockService.instance.scheduleSync(reason: 'rules_api');
      return;
    }
    if (_rulesApiSyncTimer != null) return;
    final Duration wait = _kRulesApiSyncMinGap - now.difference(last);
    _rulesApiSyncTimer = Timer(wait, () {
      _rulesApiSyncTimer = null;
      _lastRulesApiSyncAt = DateTime.now();
      UniversalBrowserBlockService.instance.scheduleSync(reason: 'rules_api');
    });
  }

  bool _runtimeEnabledForRequest(HttpRequest request) {
    final browserId = ExtensionRulesBuilder.browserIdFromClient(
      requested: request.uri.queryParameters['browser'],
      userAgent: request.headers.value(HttpHeaders.userAgentHeader),
    );
    return _runtimeEnabled?.call(browserId) ??
        ExtensionRulesBuilder.runtimeProtectionEnabled(browserId: browserId);
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path.startsWith('/control/')) {
      await AppControlActions.api.handle(request);
      return;
    }
    final HttpHeaders h = request.response.headers;
    h.add('Access-Control-Allow-Origin', '*');
    h.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    h.add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    // OFF keeps the authenticated control API available, but must not expose
    // schedules, diagnostics, or unauthenticated writes just to clear rules.
    const offReadableRoutes = <String>{
      '/health',
      '/rules',
      '/youtube/check',
      '/youtube/channel-check',
    };
    if (!offReadableRoutes.contains(request.uri.path) &&
        !_runtimeEnabledForRequest(request)) {
      request.response.statusCode = HttpStatus.conflict;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'ok': false,
          'error': 'protection_disabled',
        }),
      );
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/health') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{'ok': true, 'port': _boundPort}),
      );
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/rules') {
      try {
        final String? browserId = ExtensionRulesBuilder.browserIdFromClient(
          requested: request.uri.queryParameters['browser'],
          userAgent: request.headers.value(HttpHeaders.userAgentHeader),
        );
        final ExtensionRulesPayload payload =
            await (_rulesProvider?.call(browserId) ??
                ExtensionRulesBuilder.buildForExtensionRuntime(
                  browserId: browserId,
                ));
        final String? ua = request.headers.value(HttpHeaders.userAgentHeader);
        // The builder never widens channel/video rules into whole-site blocks.
        // Keep a full-domain block when the user explicitly selected that host.
        final ExtensionRulesPayload outPayload = payload;
        if (_rulesProvider == null) {
          BlockActivityLogService.instance.recordRulesFetch(
            keywordCount: outPayload.keywords.length,
            domainCount: outPayload.blockedDomains.length,
            searchQueryCount: outPayload.searchQueries.length,
            userAgent: ua,
          );
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(outPayload.toJson(port: _boundPort)));
        if (_rulesProvider == null) {
          ExtensionRulesSnapshotService.instance.scheduleWriteToChromePayload();
          if (outPayload.protectionEnabled) _scheduleRulesApiSync();
        }
      } catch (e) {
        AppLogger.instance.warn('usage_ingest: /rules failed $e');
        request.response.statusCode = HttpStatus.internalServerError;
      }
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/chat/schedules') {
      try {
        final List<Map<String, Object?>> schedules =
            await ChatScheduleApplyService.instance.schedulesForApi();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'schedules': schedules}),
        );
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'error': '$e'}));
      }
      await request.response.close();
      return;
    }

    if (request.method == 'POST' &&
        request.uri.path == '/chat/schedule/preview') {
      try {
        final Map<String, Object?> body = await _readJsonMap(request);
        final String message = '${body['message'] ?? ''}'.trim();
        final String? resolution = body['resolution'] as String?;
        final preview = await ChatScheduleApplyService.instance.preview(
          message,
          resolution: resolution,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'ok': true,
            'preview': preview.toJson(),
          }),
        );
      } catch (e) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'error': '$e'}));
      }
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/chat/schedule') {
      try {
        final Map<String, Object?> body = await _readJsonMap(request);
        final String message = '${body['message'] ?? ''}'.trim();
        final bool confirm = body['confirm'] == true;
        final String? resolution = body['resolution'] as String?;
        if (!confirm) {
          final preview = await ChatScheduleApplyService.instance.preview(
            message,
            resolution: resolution,
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{
              'ok': true,
              'requiresConfirm': true,
              'preview': preview.toJson(),
            }),
          );
        } else {
          final result = await ChatScheduleApplyService.instance.apply(
            message,
            resolution: resolution,
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result.toJson()));
        }
      } catch (e) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'error': '$e'}));
      }
      await request.response.close();
      return;
    }

    if (request.method == 'GET' &&
        <String>[
          '/youtube/check',
          '/youtube/channel-check',
        ].contains(request.uri.path) &&
        !_runtimeEnabledForRequest(request)) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'blocked': false,
          'protectionEnabled': false,
        }),
      );
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/youtube/check') {
      try {
        final String videoId = (request.uri.queryParameters['v'] ?? '').trim();
        final YoutubeBlockCheckResult result = await YoutubeVideoBlockResolver
            .instance
            .checkVideo(videoId);
        if (result.blocked) {
          BlockActivityLogService.instance.record(
            kind: BlockActivityKind.blockHit,
            message: 'youtube/check blocked ${result.videoId}',
            data: result.toJson(),
          );
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result.toJson()));
      } catch (e) {
        AppLogger.instance.warn('usage_ingest: /youtube/check failed $e');
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{'blocked': false, 'error': '$e'}),
        );
      }
      await request.response.close();
      return;
    }

    if (request.method == 'GET' &&
        request.uri.path == '/youtube/channel-check') {
      try {
        final String path =
            (request.uri.queryParameters['path'] ??
                    request.uri.queryParameters['url'] ??
                    '')
                .trim();
        final RegExpMatch? watchMatch = RegExp(
          r'(?:[?&]v=|youtu\.be/|/shorts/)([\w-]{6,})',
          caseSensitive: false,
        ).firstMatch(path);
        final YoutubeBlockCheckResult result = watchMatch != null
            ? await YoutubeVideoBlockResolver.instance.checkVideo(
                watchMatch.group(1)!,
              )
            : await YoutubeVideoBlockResolver.instance.checkChannel(path);
        if (result.blocked) {
          BlockActivityLogService.instance.record(
            kind: BlockActivityKind.blockHit,
            message: 'youtube/channel-check blocked ${result.channelHandle}',
            data: result.toJson(),
          );
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result.toJson()));
      } catch (e) {
        AppLogger.instance.warn(
          'usage_ingest: /youtube/channel-check failed $e',
        );
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{'blocked': false, 'error': '$e'}),
        );
      }
      await request.response.close();
      return;
    }

    if (request.method == 'GET' &&
        (request.uri.path == '/agent/snapshot' ||
            request.uri.path == '/cursor/snapshot')) {
      try {
        final Map<String, Object?> snap = await CursorAgentSnapshotService
            .instance
            .refresh(reason: 'api');
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(snap));
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'error': '$e'}));
      }
      await request.response.close();
      return;
    }

    if (request.method == 'GET' &&
        (request.uri.path == '/agent/full-pack' ||
            request.uri.path == '/cursor/full-pack')) {
      try {
        final Map<String, Object?> pack =
            await CursorOneTapDiagnosticPackService.instance.runFullPack(
              reason: 'api',
            );
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(pack));
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'error': '$e'}));
      }
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/recent') {
      final List<RecentSiteEvent> events = RecentSiteEvents.instance.snapshot();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'events': events
              .map(
                (RecentSiteEvent e) => <String, Object?>{
                  'host': e.host,
                  'at': e.at.toIso8601String(),
                  'seconds': e.seconds,
                },
              )
              .toList(),
        }),
      );
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/usage/lock-status') {
      try {
        final String host = (request.uri.queryParameters['host'] ?? '')
            .trim()
            .toLowerCase();
        final bool locked =
            host.isNotEmpty &&
            UsageQuotaEnforcerService.instance.isForegroundLocked(host);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{'host': host, 'locked': locked}),
        );
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'error': '$e'}));
      }
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/schedules/list') {
      try {
        final List<Map<String, Object?>> rows = await LocalDatabase.instance
            .schedules();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'ok': true,
            'schedules': rows
                .map(
                  (Map<String, Object?> r) => <String, Object?>{
                    'id': r['id'],
                    'name': r['name'],
                  },
                )
                .toList(),
          }),
        );
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'error': '$e'}));
      }
      await request.response.close();
      return;
    }

    // Lets the browser extension's right-click "차단에 추가" menu write a
    // site/YouTube-channel pattern straight into an existing schedule (or
    // `scheduleId: null` for "always block"), without the user re-typing
    // the URL inside the app.
    if (request.method == 'POST' && request.uri.path == '/add-rule') {
      try {
        final Map<String, Object?> body = await _readJsonMap(request);
        final String type = '${body['type'] ?? ''}'.trim().toLowerCase();
        final String value = '${body['value'] ?? ''}'.trim();
        final Object? rawScheduleId = body['scheduleId'];
        final String? scheduleId = rawScheduleId == null
            ? null
            : '$rawScheduleId'.trim();
        if (value.isEmpty || (type != 'domain' && type != 'keyword')) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': 'bad_request'}),
          );
          await request.response.close();
          return;
        }
        bool added = true;
        if (type == 'domain') {
          if (!await LocalDatabase.instance.hasActiveDomain(value)) {
            await LocalDatabase.instance.insertDomain(
              id: const Uuid().v4(),
              host: value,
              scheduleId: scheduleId,
              source: 'extension',
            );
          } else {
            added = false;
          }
        } else {
          if (!await LocalDatabase.instance.hasActiveKeywordPattern(value)) {
            await LocalDatabase.instance.insertKeyword(
              id: const Uuid().v4(),
              pattern: value,
              scheduleId: scheduleId,
            );
          } else {
            added = false;
          }
        }
        UniversalBrowserBlockService.instance.scheduleSync(
          reason: 'extension_add_rule',
        );
        BlockActivityLogService.instance.record(
          kind: BlockActivityKind.blockHit,
          message: added
              ? 'extension add-rule: $type=$value schedule=$scheduleId'
              : 'extension add-rule (dup, skipped): $type=$value',
          data: <String, Object?>{'type': type, 'value': value},
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'added': added}),
        );
      } catch (e) {
        AppLogger.instance.warn('usage_ingest: /add-rule failed $e');
        request.response.statusCode = HttpStatus.badRequest;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'error': '$e'}));
      }
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/ingest') {
      try {
        final String body = await utf8.decoder.bind(request).join();
        final Object? decoded = jsonDecode(body);
        if (decoded is! Map) throw FormatException('not a map');
        final Map<String, Object?> m = Map<String, Object?>.from(decoded);
        final String host = '${m['host'] ?? ''}'.trim().toLowerCase();
        final int seconds = _asInt(m['seconds']);
        final String phase = '${m['phase'] ?? 'foreground'}'
            .trim()
            .toLowerCase();
        final bool background = phase == 'background' || phase == 'bg';
        if (host.isEmpty || host == 'localhost' || host == '127.0.0.1') {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
        }
        if (seconds < 1 || seconds > 120) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
        }
        final exemptions = YoutubeBudgetExemptionStore.instance;
        if (await exemptions.isDomainExempt(host) ||
            await exemptions.isYoutubeMetadataExempt(
              m['youtubeBudgetMetadata'],
              '${m['documentUrl'] ?? ''}',
            )) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'ok': true,
              'accounted': false,
              'reason': 'youtube_budget_exemption',
            }),
          );
          await request.response.close();
          return;
        }
        if (await UsageQuotaEnforcerService.instance.isGlobalCapExceededNow()) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{
              'ok': false,
              'reason': 'global_daily_cap',
            }),
          );
          await request.response.close();
          return;
        }
        final int periodHours = await UsageBucketConfigService.instance
            .getPeriodHours();
        final String subject = LocalDatabase.usageSubjectForWebHost(host);
        await LocalDatabase.instance.addUsageSeconds(
          subject,
          seconds,
          DateTime.now(),
          periodHours: periodHours,
          background: background,
        );
        await UsageQuotaEnforcerService.instance.onUsageRecorded(
          subject,
          seconds,
        );
        RecentSiteEvents.instance.record(host, seconds: seconds);
        BlockActivityLogService.instance.recordBrowserVisit(
          host,
          seconds: seconds,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'ok': true}));
      } catch (e) {
        AppLogger.instance.warn('usage_ingest: bad body $e');
        request.response.statusCode = HttpStatus.badRequest;
      }
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/block') {
      try {
        final String body = await utf8.decoder.bind(request).join();
        final Object? decoded = jsonDecode(body);
        if (decoded is! Map) throw FormatException('not a map');
        final Map<String, Object?> m = Map<String, Object?>.from(decoded);
        final String rule = '${m['rule'] ?? m['matched'] ?? ''}'.trim();
        final String url = '${m['url'] ?? ''}'.trim();
        final String kind = '${m['kind'] ?? 'navigation'}'.trim();
        final String? browser = m['browser'] as String?;
        if (rule.isNotEmpty) {
          BlockActivityLogService.instance.recordBrowserBlock(
            rule: rule,
            url: url.isEmpty ? '(unknown)' : url,
            kind: kind,
            browser: browser,
          );
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'ok': true}));
      } catch (e) {
        AppLogger.instance.warn('usage_ingest: /block bad body $e');
        request.response.statusCode = HttpStatus.badRequest;
      }
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static Future<Map<String, Object?>> _readJsonMap(HttpRequest request) async {
    final String body = await utf8.decoder.bind(request).join();
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('body must be a JSON map');
    return Map<String, Object?>.from(decoded);
  }
}
