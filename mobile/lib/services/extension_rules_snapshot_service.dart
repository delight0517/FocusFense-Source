import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'extension_rules_builder.dart';
import 'usage_ingest_server.dart';

/// Writes `rules_snapshot.json` into the unpacked Chrome extension folder so
/// blocking works even when the app is closed or `/rules` fetch fails.
final class ExtensionRulesSnapshotService {
  ExtensionRulesSnapshotService._();
  static final ExtensionRulesSnapshotService instance =
      ExtensionRulesSnapshotService._();

  static const String kSnapshotFileName = 'rules_snapshot.json';

  Timer? _chromeDebounce;
  bool _chromeWriteRunning = false;
  DateTime? _lastChromeWriteAt;
  static const Duration _kMinWriteGap = Duration(seconds: 8);

  /// Debounced — rapid DB edits collapse into one disk write (boot lag fix).
  void scheduleWriteToChromePayload({String? sourceFolder}) {
    if (!Platform.isWindows) return;
    _chromeDebounce?.cancel();
    _chromeDebounce = Timer(const Duration(milliseconds: 1200), () {
      unawaited(writeToChromePayload(sourceFolder: sourceFolder));
    });
  }

  /// Push current DB rules to `%LOCALAPPDATA%\\SixVPNBlocker\\chrome_blocker`.
  Future<bool> writeToChromePayload({
    String? sourceFolder,
    bool force = false,
  }) async {
    if (!Platform.isWindows) return false;
    final DateTime now = DateTime.now();
    if (_chromeWriteRunning) {
      scheduleWriteToChromePayload(sourceFolder: sourceFolder);
      return false;
    }
    if (!force &&
        _lastChromeWriteAt != null &&
        now.difference(_lastChromeWriteAt!) < _kMinWriteGap) {
      scheduleWriteToChromePayload(sourceFolder: sourceFolder);
      return false;
    }
    _chromeWriteRunning = true;
    try {
      return await _writeToChromePayloadImpl(sourceFolder: sourceFolder);
    } finally {
      _chromeWriteRunning = false;
      _lastChromeWriteAt = DateTime.now();
    }
  }

  Future<bool> _writeToChromePayloadImpl({String? sourceFolder}) async {
    if (!Platform.isWindows) return false;
    try {
      final ExtensionRulesPayload payload =
          await ExtensionRulesBuilder.buildForExtensionRuntime(
            browserId: 'chrome',
          );
      final int port = UsageIngestServer.instance.isRunning
          ? UsageIngestServer.instance.boundPort
          : UsageIngestServer.kPort;

      String folder = ChromeLoadExtensionLauncher.stableChromeExtDir;
      if (sourceFolder != null &&
          sourceFolder.isNotEmpty &&
          await File(p.join(sourceFolder, 'manifest.json')).exists()) {
        folder = sourceFolder;
      } else if (!await File(p.join(folder, 'manifest.json')).exists()) {
        if (!payload.protectionEnabled) return false;
        if (!await ChromeExtensionPayloadService.stablePayloadReady()) {
          return false;
        }
      }

      final Directory dir = Directory(folder);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      if (!await File(p.join(folder, 'manifest.json')).exists()) {
        return false;
      }

      final Map<String, Object?> json = payload.toJson(port: port);
      json['rulesApiPorts'] = List<int>.generate(
        12,
        (int i) => UsageIngestServer.kPort + i,
      );

      final File out = File(p.join(folder, kSnapshotFileName));
      await out.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );

      // Legacy inspect file (options / support).
      final File sync = File(p.join(folder, 'sixvpn_sync.json'));
      await sync.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'hideImages': payload.protectionEnabled,
          'hideSerp': payload.precisionContentFilter,
          'keywords': payload.keywords,
          'blockedDomains': payload.blockedDomains,
          'searchQueries': payload.searchQueries
              .map((e) => e.toJson())
              .toList(),
          'rulesApi': 'http://127.0.0.1:$port/rules',
        }),
        flush: true,
      );

      AppLogger.instance.info(
        'rules_snapshot: ${payload.blockedDomains.length} domains, '
        '${payload.keywords.length} keywords → $folder',
      );
      return true;
    } catch (e, st) {
      AppLogger.instance.error(
        'rules_snapshot write failed',
        error: e,
        stack: st,
      );
      return false;
    }
  }

  /// Same snapshot for Firefox XPI folder — visible in extension options +
  /// offline fallback when `/rules` is down.
  Future<bool> writeToFirefoxPayload({String? sourceFolder}) async {
    if (!Platform.isWindows) return false;
    try {
      final ExtensionRulesPayload payload =
          await ExtensionRulesBuilder.buildForExtensionRuntime(
            browserId: 'firefox',
          );
      final ExtensionRulesPayload firefoxPayload = payload;
      final int port = UsageIngestServer.instance.isRunning
          ? UsageIngestServer.instance.boundPort
          : UsageIngestServer.kPort;

      String folder = p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'SixVPNBlocker',
        'firefox_blocker',
      );
      if (sourceFolder != null &&
          sourceFolder.isNotEmpty &&
          await File(p.join(sourceFolder, 'manifest.json')).exists()) {
        folder = sourceFolder;
      } else if (!await File(p.join(folder, 'manifest.json')).exists()) {
        return false;
      }

      final Map<String, Object?> json = firefoxPayload.toJson(port: port);
      json['rulesApiPorts'] = List<int>.generate(
        12,
        (int i) => UsageIngestServer.kPort + i,
      );

      final File out = File(p.join(folder, kSnapshotFileName));
      await out.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );

      final File sync = File(p.join(folder, 'sixvpn_sync.json'));
      await sync.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'hideImages': firefoxPayload.protectionEnabled,
          'hideSerp': firefoxPayload.precisionContentFilter,
          'keywords': firefoxPayload.keywords,
          'blockedDomains': firefoxPayload.blockedDomains,
          'blockedYoutubeHandles': firefoxPayload.blockedYoutubeHandles,
          'blockedYoutubeChannelIds': firefoxPayload.blockedYoutubeChannelIds,
          'blockedYoutubeVideoIds': firefoxPayload.blockedYoutubeVideoIds,
          'searchQueries': payload.searchQueries
              .map((e) => e.toJson())
              .toList(),
          'rulesApi': 'http://127.0.0.1:$port/rules',
        }),
        flush: true,
      );

      AppLogger.instance.info(
        'firefox rules_snapshot: ${payload.blockedYoutubeHandles.length} handles → $folder',
      );
      return true;
    } catch (e, st) {
      AppLogger.instance.error(
        'firefox rules_snapshot write failed',
        error: e,
        stack: st,
      );
      return false;
    }
  }
}
