import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'autonomous_browser_protection_service.dart';
import 'block_activity_log_service.dart';
import 'block_sync_service.dart';
import 'blocking_ecosystem_scan_service.dart';
import 'blocking_self_heal_agent_service.dart';
import 'tri_browser_self_heal_service.dart';
import 'build_identity_service.dart';
import 'chrome_block_autonomy_service.dart';
import 'chrome_extension_payload_service.dart';
import '../models/post_rebuild_activation_report.dart';
import 'easy_setup_bulletproof_prefs.dart';
import 'extension_rules_builder.dart';
import 'extension_rules_snapshot_service.dart';
import 'post_rebuild_activation_notifier.dart';
import 'rebuild_preferences_service.dart';
import 'silent_bootstrap_context.dart';
import 'browser_live_url_block_gate_service.dart';
import 'chrome_url_block_reload_orchestrator_service.dart';
import 'numeric_apex_hosts_gap_healer_service.dart';
import 'universal_browser_block_service.dart';
import 'usage_ingest_server.dart';
import 'youtube_channel_boot_sync_service.dart';
import 'windows_browser_proxy_policy_service.dart';
import 'windows_emergency_block_service.dart';
import 'extension_keepalive_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_os_integration_service.dart';

/// After install or a new build (+N), runs the full protection pipeline once
/// without UAC or confirmation dialogs.
final class PostRebuildBootstrapService {
  PostRebuildBootstrapService._();
  static final PostRebuildBootstrapService instance =
      PostRebuildBootstrapService._();

  static const String _lastBuildKey = 'post_bootstrap_last_build_v1';
  static const String kPendingFileName = 'post_rebuild_bootstrap_pending.txt';

  static bool _running = false;
  static bool completedThisSession = false;

  bool get isRunning => _running;

  /// Wait until [runIfNeeded] finishes (or [timeout] elapses).
  Future<void> whenIdle({Duration timeout = const Duration(minutes: 5)}) async {
    if (!_running) return;
    final DateTime deadline = DateTime.now().add(timeout);
    while (_running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  static String? _localAppDataDir() =>
      Platform.environment['LOCALAPPDATA'];

  static String get _pendingPath {
    final String la = _localAppDataDir() ?? r'C:\Users\Public';
    return p.join(la, 'SixVPNBlocker', kPendingFileName);
  }

  /// Returns true when a full silent bootstrap ran (boot path may skip duplicates).
  Future<bool> runIfNeeded({bool force = false}) async {
    if (!Platform.isWindows) return false;
    if (_running) return completedThisSession;

    final BuildIdentity build = await BuildIdentityService.instance.current();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? last = prefs.getString(_lastBuildKey);
    final bool pendingOnDisk = await _readPendingFlag();
    final bool newBuild =
        last == null || last.trim() != build.buildNumber.trim();

    if (!force && !newBuild && !pendingOnDisk) {
      return false;
    }

    _running = true;
    SilentBootstrapContext.beginPostRebuild();
    try {
      AppLogger.instance.info(
        'post_rebuild_bootstrap: start build=${build.buildNumber} '
        'last=$last pending=$pendingOnDisk',
      );
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.boot,
        message: '새 빌드 자동 점검 시작 (v${build.version}+${build.buildNumber})',
        debounceKey: 'post_rebuild_bootstrap',
      );

      if (!UsageIngestServer.instance.isRunning) {
        UsageIngestServer.instance.start();
      }

      BlockSyncService.instance.enabled = true;

      final bool heavy =
          await RebuildPreferencesService.instance.heavyPostRebuildBootstrap();

      await WindowsOsIntegrationService.ensureOnBoot(silent: true);

      if (heavy) {
        await EasySetupBulletproofPrefs.instance.setAll(
          hijackShortcuts: true,
          browserWatchdog: true,
          forceEnterprisePolicies: true,
          realtimeBrowserGuard: true,
        );
        await ChromeExtensionPayloadService.ensureStablePayload();
        await ChromeBlockAutonomyService.instance.runOnce(
          reason: 'post_rebuild',
          repair: true,
        );
        await AutonomousBrowserProtectionService.instance
            .ensureAllBrowsersProtected(
          reason: 'post_rebuild',
          force: true,
        );
      }

      await ExtensionRulesSnapshotService.instance.writeToChromePayload();
      await YoutubeChannelBootSyncService.instance.runIfDue(
        reason: 'post_rebuild',
        force: true,
      );
      final UniversalBlockResult universal =
          await UniversalBrowserBlockService.instance.syncNow(
        reason: heavy ? 'post_rebuild' : 'post_rebuild_light',
      );
      if (heavy) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await UniversalBrowserBlockService.instance.syncNow(
          reason: 'post_rebuild_confirm',
        );
      }
      BlockSyncService.instance.requestApply();

      unawaited(
        NumericApexHostsGapHealerService.instance.healIfNeeded(
          reason: 'post_rebuild',
          force: true,
        ),
      );
      unawaited(
        ChromeUrlBlockReloadOrchestratorService.instance.runCycle(
          reason: 'post_rebuild',
          force: true,
        ),
      );
      unawaited(
        BrowserLiveUrlBlockGateService.instance.runLiveTest(
          applyPolicyFirst: true,
          reason: 'post_rebuild',
        ),
      );

      try {
        await ChromeExtensionPayloadService.ensureStablePayload();
        await ExtensionKeepaliveService.tick(reason: 'post_rebuild');
      } catch (_) {/* light bootstrap must not fail on policy */}

      if (heavy) {
        await TriBrowserSelfHealService.instance.runCycle(
          reason: 'post_rebuild',
          userInitiated: true,
          repair: true,
        );
        await BlockingSelfHealAgentService.instance.runCycle(
          reason: 'post_rebuild',
          userInitiated: true,
        );
      }

      await prefs.setString(_lastBuildKey, build.buildNumber.trim());
      await _clearPendingFlag();

      completedThisSession = true;

      final ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildForBrowserEnforcement();
      final bool ytEnforce =
          await WindowsBrowserProxyPolicyService.instance
              .isYoutubeEnforceActive();
      final bool blocks0ucgh = rules.keywords.any(
        (String k) => k.toLowerCase().contains('0ucghclyrrk'),
      );
      final PostRebuildActivationReport report = PostRebuildActivationReport(
        buildLabel: '${build.version}+${build.buildNumber}',
        universalOk: universal.ok,
        universalMessage: heavy
            ? universal.message
            : '가벼운 빌드 후 동기화 완료 (규칙·확장 스냅샷만). '
                '전체 브라우저 재설치는 설정에서 「리빌드 후 무거운 자동 점검」을 켜세요.',
        pacApplied: universal.pacApplied,
        pacPath: WindowsEmergencyBlockService.pacPath(),
        steps: universal.steps,
        youtubeEnforce: ytEnforce,
        bulletproofOn: heavy,
        chromeBlockingOk: heavy,
        keywordCount: rules.keywords.length,
        blocksVideo0ucghClyrrk: blocks0ucgh,
      );
      PostRebuildActivationNotifier.instance.publish(report);
      await _writeStatusFile(report);

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.boot,
        message: '새 빌드 자동 점검 완료 (v${build.version}+${build.buildNumber})',
        debounceKey: 'post_rebuild_bootstrap_done',
      );
      AppLogger.instance.info('post_rebuild_bootstrap: done');
      BlockingEcosystemScanService.instance.invalidateCache();
      // Defer heavy browser probes so first-frame UI stays responsive.
      Future<void>.delayed(const Duration(seconds: 75), () {
        unawaited(
          BlockingEcosystemScanService.instance.scan(postUpdate: true),
        );
      });
      return true;
    } catch (e, st) {
      AppLogger.instance.error('post_rebuild_bootstrap failed', error: e, stack: st);
      return false;
    } finally {
      SilentBootstrapContext.endPostRebuild();
      _running = false;
    }
  }

  Future<bool> _readPendingFlag() async {
    try {
      final File f = File(_pendingPath);
      if (!await f.exists()) return false;
      final String body = (await f.readAsString()).trim();
      if (body.isEmpty) return true;
      final BuildIdentity build =
          await BuildIdentityService.instance.current();
      return body == build.buildNumber.trim() || body.contains('+');
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearPendingFlag() async {
    try {
      final File f = File(_pendingPath);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {/* best-effort */}
  }

  /// Called from rebuild script so the next launch always bootstraps.
  static Future<void> _writeStatusFile(PostRebuildActivationReport report) async {
    try {
      final String la = _localAppDataDir() ?? r'C:\Users\Public';
      final String path = p.join(la, 'SixVPNBlocker', 'last_post_rebuild_status.txt');
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsString(
        <String>[...report.summaryLines(), '', report.universalMessage].join('\n'),
        flush: true,
      );
    } catch (_) {}
  }

  /// Called from rebuild script so the next launch always bootstraps.
  static Future<void> writePendingFlag(String buildLabel) async {
    if (!Platform.isWindows) return;
    try {
      final String la = _localAppDataDir() ?? r'C:\Users\Public';
      final String dir = p.join(la, 'SixVPNBlocker');
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, kPendingFileName))
          .writeAsString(buildLabel.trim(), flush: true);
    } catch (_) {/* best-effort */}
  }
}
