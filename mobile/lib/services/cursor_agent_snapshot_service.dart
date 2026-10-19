import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'automated_browser_handoff_service.dart';
import 'block_activity_log_service.dart';
import 'build_identity_service.dart';
import 'chrome_extension_state_probe.dart';
import 'cursor_agent_fix_log_service.dart';
import 'crash_journal_service.dart';
import 'extension_rules_builder.dart';
import 'usage_ingest_server.dart';
import 'windows_extension_guard_service.dart';
import 'youtube_proactive_guard_service.dart';
import 'youtube_video_block_resolver.dart';

/// Writes `cursor_agent_snapshot.json` — one file Cursor agents read for full PC state.
final class CursorAgentSnapshotService {
  CursorAgentSnapshotService._();
  static final CursorAgentSnapshotService instance =
      CursorAgentSnapshotService._();

  // PERFORMANCE: this snapshot probe can spawn multiple PowerShell/reg.exe
  // children. Keep it event-driven only (manual/orchestrator/post-update)
  // instead of periodic background polling.
  static const Duration kBootDelay = Duration(seconds: 25);
  static const List<String> kDefaultProbeVideoIds = <String>[
    'ebjHn1wY_HA',
    'oYVEqFdjNDs',
    '9zz_j97kDIY',
    'BddZUaoWB_s',
  ];

  bool _refreshing = false;

  String get snapshotPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'cursor_agent_snapshot.json',
      );

  Future<void> start() async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    await CrashJournalService.instance.warmup();
    Future<void>.delayed(kBootDelay, () {
      unawaited(refresh(reason: 'boot', light: true));
    });
  }

  void stop() {}

  Future<Map<String, Object?>> refresh({
    String reason = 'manual',
    bool light = false,
  }) async {
    if (_refreshing) {
      return _readExisting() ?? <String, Object?>{'busy': true};
    }
    _refreshing = true;
    try {
      final Map<String, Object?> snap = await _build(reason, light: light);
      final File out = File(snapshotPath);
      await out.parent.create(recursive: true);
      await out.writeAsString(
        const JsonEncoder.withIndent('  ').convert(snap),
        flush: true,
      );
      AppLogger.instance.info('cursor_agent_snapshot: wrote ($reason)');
      return snap;
    } catch (e, st) {
      AppLogger.instance.warn('cursor_agent_snapshot failed: $e\n$st');
      rethrow;
    } finally {
      _refreshing = false;
    }
  }

  Map<String, Object?>? _readExisting() {
    try {
      final File f = File(snapshotPath);
      if (!f.existsSync()) return null;
      final Object? j = jsonDecode(f.readAsStringSync());
      if (j is Map) return Map<String, Object?>.from(j);
    } catch (_) {}
    return null;
  }

  Future<Map<String, Object?>> _build(String reason, {bool light = false}) async {
    final String build = await BuildIdentityService.instance.summaryLine();
    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();

    final List<String> ytHandles = rules.blockedYoutubeHandles;
    final bool hasBeautifulNerd = rules.keywords.any(
      (String k) => k.contains('뷰티풀') || k.contains('beautiful'),
    );

    final Map<String, Object?> extensionFiles = await _extensionFiles();
    BrowserProcessProbe browsers = const BrowserProcessProbe(
      chromeRunning: false,
      chromeProtected: false,
      chromeUnprotected: false,
      edgeRunning: false,
      edgeProtected: false,
      edgeUnprotected: false,
    );
    if (Platform.isWindows && !light) {
      browsers = await AutomatedBrowserHandoffService.probeBrowsers();
    }

    ExtensionPolicyVerifyResult? policies;
    if (Platform.isWindows && !light) {
      policies = await WindowsExtensionGuardService.verifyAllPolicies();
    }

    ChromeExtensionProbeResult chromePrefs = ChromeExtensionProbeResult(
      hasUnpackedCopy: false,
      hasRegistryManaged: false,
      detail: light ? 'light-skip' : 'n/a',
    );
    if (Platform.isWindows && !light) {
      chromePrefs = await ChromeExtensionStateProbe.probe(browser: 'chrome');
    }

    final List<Map<String, Object?>> youtubeProbes = <Map<String, Object?>>[];
    if (light) {
      youtubeProbes.addAll(_youtubeProbesFromGuardCache());
    } else {
      for (final String vid in kDefaultProbeVideoIds) {
        try {
          final YoutubeBlockCheckResult r =
              await YoutubeVideoBlockResolver.instance.checkVideo(vid);
          youtubeProbes.add(<String, Object?>{
            'videoId': vid,
            'url': 'https://www.youtube.com/watch?v=$vid',
            ...r.toJson(),
          });
        } catch (e) {
          youtubeProbes.add(<String, Object?>{
            'videoId': vid,
            'error': '$e',
          });
        }
      }
    }

    final List<String> agentNotes = <String>[];
    if (!UsageIngestServer.instance.isRunning) {
      agentNotes.add('CRITICAL: rules API not running — start Focus Fense app');
    }
    if (Platform.isWindows) {
      if (!(extensionFiles['chromeProgramDataOk'] as bool? ?? false) &&
          !(extensionFiles['chromeLocalAppDataOk'] as bool? ?? false)) {
        agentNotes.add(
          'CRITICAL: Chrome extension files missing — watchdog should re-export',
        );
      }
      if (browsers.chromeRunning && !browsers.chromeProtected) {
        agentNotes.add(
          'CRITICAL: Chrome running WITHOUT extension — soft-handoff needed',
        );
      }
      if (!(extensionFiles['firefoxProgramDataOk'] as bool? ?? false)) {
        agentNotes.add('WARN: Firefox extension files missing in ProgramData');
      }
      if (chromePrefs.extensionNotPresent) {
        agentNotes.add('WARN: Chrome profile has no extension record');
      }
      if (policies != null && !policies.chromeOk && !policies.chromeLoadExtensionFallbackOk) {
        agentNotes.add('WARN: Chrome policy + launcher both missing');
      }
    }
    for (final Map<String, Object?> probe in youtubeProbes) {
      if (probe['blocked'] == true) {
        agentNotes.add(
          'EXPECT_BLOCK: watch?v=${probe['videoId']} → ${probe['rule'] ?? probe['matched']}',
        );
      } else if (hasBeautifulNerd && probe['videoId'] == 'ebjHn1wY_HA') {
        agentNotes.add(
          'BUG: ebjHn1wY_HA should be blocked (뷰티풀너드 rules present) — check resolver',
        );
      }
    }

    final Map<String, Object?>? youtubeConnectivity =
        await _probeYoutubeConnectivity();
    if (youtubeConnectivity != null) {
      if (youtubeConnectivity['sinkholed'] == true) {
        agentNotes.add(
          'CRITICAL: youtube.com DNS sinkhole (0.0.0.0) — site will not load in any browser. '
          'See youtube_hosts_autofix_last.json / cursor_agent_fix_last.json',
        );
      }
    }

    Map<String, Object?>? fixLogLast;
    Map<String, Object?>? youtubeHostsAutofix;
    try {
      fixLogLast = CursorAgentFixLogService.instance.readLastSync();
      final File yhf = File(p.join(
        CrashJournalService.instance.debugFolderPath,
        'youtube_hosts_autofix_last.json',
      ));
      if (yhf.existsSync()) {
        final Object? j = jsonDecode(yhf.readAsStringSync());
        if (j is Map) youtubeHostsAutofix = Map<String, Object?>.from(j);
      }
    } catch (_) {}

    if (youtubeHostsAutofix != null && youtubeHostsAutofix['ok'] == false) {
      agentNotes.add(
        'FAIL: YouTube hosts autofix — ${youtubeHostsAutofix['verdict'] ?? 'unknown'}',
      );
    }
    if (fixLogLast != null) {
      final Object? latest = fixLogLast['latest'];
      if (latest is Map && latest['ok'] == false) {
        final Object? failed = latest['failedLayers'];
        agentNotes.add(
          'FAIL: ${latest['component']}.${latest['action']} — '
          'failedLayers=$failed',
        );
      }
    }

    Map<String, Object?>? selfHeal;
    Map<String, Object?>? youtubeGuard;
    try {
      final File f = File(p.join(
        CrashJournalService.instance.debugFolderPath,
        'blocking_self_heal_last.json',
      ));
      if (f.existsSync()) {
        final Object? j = jsonDecode(f.readAsStringSync());
        if (j is Map) selfHeal = Map<String, Object?>.from(j);
      }
      final File yf = File(YoutubeProactiveGuardService.instance.reportPath);
      if (yf.existsSync()) {
        final Object? j = jsonDecode(yf.readAsStringSync());
        if (j is Map) youtubeGuard = Map<String, Object?>.from(j);
      }
    } catch (_) {}

    return <String, Object?>{
      'updatedAt': DateTime.now().toIso8601String(),
      'reason': reason,
      'light': light,
      'build': build,
      'cursorReadme': 'mobile/tools/Read-CursorAgentSnapshot.ps1',
      'paths': <String, String>{
        'snapshot': snapshotPath,
        'blockSummary': BlockActivityLogService.instance.summaryPath,
        'blockJsonl': BlockActivityLogService.instance.jsonlPath,
        'fixLogJsonl': CursorAgentFixLogService.instance.jsonlPath,
        'fixLogLast': CursorAgentFixLogService.instance.lastPath,
        'youtubeHostsAutofix': p.join(
          CrashJournalService.instance.debugFolderPath,
          'youtube_hosts_autofix_last.json',
        ),
      },
      'rulesApi': <String, Object?>{
        'running': UsageIngestServer.instance.isRunning,
        'port': UsageIngestServer.instance.boundPort,
        'endpoints': <String>[
          'GET /rules',
          'GET /youtube/check?v=VIDEO_ID',
          'GET /agent/snapshot',
          'GET /agent/full-pack',
        ],
      },
      'activeRules': <String, Object?>{
        'keywords': rules.keywords.length,
        'domains': rules.blockedDomains.length,
        'blockedYoutubeHandles': ytHandles,
        'blockedYoutubeChannelIds': rules.blockedYoutubeChannelIds,
        'blockedYoutubeVideoIds': rules.blockedYoutubeVideoIds,
        'hasBeautifulNerdRule': hasBeautifulNerd,
        'keywordSample': rules.keywords
            .where((String k) => k.contains('youtube') || k.contains('뷰티'))
            .take(12)
            .toList(),
      },
      'extensionFiles': extensionFiles,
      'browsers': <String, Object?>{
        'chromeRunning': browsers.chromeRunning,
        'chromeProtected': browsers.chromeProtected,
        'chromeUnprotected': browsers.chromeUnprotected,
        'edgeRunning': browsers.edgeRunning,
        'edgeProtected': browsers.edgeProtected,
      },
      'chromePrefsProbe': <String, Object?>{
        'extensionNotPresent': chromePrefs.extensionNotPresent,
        'hasRegistryManaged': chromePrefs.hasRegistryManaged,
        'hasUnpackedCopy': chromePrefs.hasUnpackedCopy,
        'detail': chromePrefs.detail,
      },
      if (policies != null)
        'policies': <String, Object?>{
          'chromeOk': policies.chromeOk,
          'firefoxOk': policies.firefoxPolicyOk,
          'chromeHkcuOk': policies.chromeHkcuOk,
          'chromeHklmOk': policies.chromeHklmOk,
          'chromeLoadExtensionFallbackOk': policies.chromeLoadExtensionFallbackOk,
        },
      'youtubeProbes': youtubeProbes,
      if (youtubeConnectivity != null) 'youtubeConnectivity': youtubeConnectivity,
      if (youtubeHostsAutofix != null) 'youtubeHostsAutofix': youtubeHostsAutofix,
      if (fixLogLast != null) 'cursorAgentFixLast': fixLogLast,
      'selfHealLast': selfHeal,
      'youtubeProactiveGuard': youtubeGuard,
      'agentNotes': agentNotes,
    };
  }

  List<Map<String, Object?>> _youtubeProbesFromGuardCache() {
    try {
      final File yf = File(YoutubeProactiveGuardService.instance.reportPath);
      if (!yf.existsSync()) return const <Map<String, Object?>>[];
      final Object? j = jsonDecode(yf.readAsStringSync());
      if (j is! Map) return const <Map<String, Object?>>[];
      final Object? checks = j['ruleChecks'];
      if (checks is! List) return const <Map<String, Object?>>[];
      return checks
          .whereType<Map>()
          .map((Map<dynamic, dynamic> m) => Map<String, Object?>.from(m))
          .toList();
    } catch (_) {
      return const <Map<String, Object?>>[];
    }
  }

  Future<Map<String, Object?>> _probeYoutubeConnectivity() async {
    if (!Platform.isWindows) return const <String, Object?>{'skipped': true};
    try {
      final List<InternetAddress> addrs =
          await InternetAddress.lookup('www.youtube.com');
      final String? ip = addrs.isNotEmpty ? addrs.first.address : null;
      final bool sinkholed = ip == '0.0.0.0' ||
          ip == '127.0.0.1' ||
          (ip != null && ip.startsWith('0.'));
      return <String, Object?>{
        'host': 'www.youtube.com',
        'resolvedIp': ip,
        'sinkholed': sinkholed,
        'reachable': !sinkholed && ip != null,
      };
    } catch (e) {
      return <String, Object?>{
        'host': 'www.youtube.com',
        'sinkholed': true,
        'reachable': false,
        'error': '$e',
      };
    }
  }

  Future<Map<String, Object?>> _extensionFiles() async {
    final String programData = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    final String localApp = Platform.environment['LOCALAPPDATA'] ?? '';
    final String chromePd =
        p.join(programData, 'SixVPNBlocker', 'chrome_blocker', 'manifest.json');
    final String chromeLa =
        p.join(localApp, 'SixVPNBlocker', 'chrome_blocker', 'manifest.json');
    final String ffPd =
        p.join(programData, 'SixVPNBlocker', 'firefox', 'manifest.json');
    return <String, Object?>{
      'chromeProgramData': chromePd,
      'chromeProgramDataOk': await File(chromePd).exists(),
      'chromeLocalAppData': chromeLa,
      'chromeLocalAppDataOk': await File(chromeLa).exists(),
      'firefoxProgramData': ffPd,
      'firefoxProgramDataOk': await File(ffPd).exists(),
    };
  }
}
