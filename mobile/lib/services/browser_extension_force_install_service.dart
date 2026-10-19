import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/browser_extension_asset_manifest.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'browser_extension_export_service.dart';
import 'chrome_extension_auto_sync_service.dart';
import 'chrome_extension_install_verifier.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_install_discovery_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart';
import 'extension_guard_prefs.dart';
import 'firefox_config_service.dart';
import 'firefox_xpi_packager.dart';
import 'tier_enforcement_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'brave_extension_install_service.dart';
import 'chromium_derivative_extension_service.dart';
import 'windows_firefox_extension_install_service.dart';

/// Tries **every** Chrome / Edge / Firefox extension install path the app has:
/// asset export → HKCU registry/policy → profile XPI → elevated HKLM guard →
/// `--load-extension` launchers → shortcut hijack.
final class BrowserExtensionForceInstallService {
  BrowserExtensionForceInstallService._();
  static final BrowserExtensionForceInstallService instance =
      BrowserExtensionForceInstallService._();

  static const Duration kCooldown = Duration(minutes: 8);
  DateTime? _lastRun;
  bool _running = false;

  Future<BrowserExtensionForceInstallReport> installAll({
    String reason = 'auto',
    bool force = false,
    bool userInitiated = false,
    bool attemptElevated = true,
  }) async {
    if (!Platform.isWindows) {
      return const BrowserExtensionForceInstallReport(
        ok: false,
        skipped: true,
        verdict: 'Windows 전용',
        actions: <String>[],
      );
    }
    final DateTime now = DateTime.now();
    if (!force &&
        _lastRun != null &&
        now.difference(_lastRun!) < kCooldown) {
      return const BrowserExtensionForceInstallReport(
        ok: true,
        skipped: true,
        verdict: '최근 설치 시도됨 — 쿨다운',
        actions: <String>[],
      );
    }
    if (_running) {
      return const BrowserExtensionForceInstallReport(
        ok: false,
        skipped: true,
        verdict: '설치 실행 중',
        actions: <String>[],
      );
    }

    _running = true;
    _lastRun = now;
    final List<String> actions = <String>[];

    try {
      AppLogger.instance.info(
        'browser_ext_force_install: start reason=$reason force=$force',
      );

      // ── 1. Export bundled assets (Chrome + Firefox) ──
      final BrowserExtensionExportResult chromeExport =
          await BrowserExtensionExportService.exportAssets(
        assetPaths: BrowserExtensionAssetManifest.chrome,
        subdirName: BrowserExtensionExportService.kChromeSubdir,
      );
      if (chromeExport.ok) actions.add('export_chrome');

      final BrowserExtensionExportResult firefoxExport =
          await BrowserExtensionExportService.exportAssets(
        assetPaths: BrowserExtensionAssetManifest.firefox,
        subdirName: BrowserExtensionExportService.kFirefoxSubdir,
      );
      if (firefoxExport.ok) actions.add('export_firefox');

      final BraveExtensionApplyResult braveResult =
          await BraveExtensionInstallService.instance.apply(
        reason: 'force_install_$reason',
        force: force,
      );
      if (braveResult.ok) {
        actions.add('brave_ext');
      } else if (!braveResult.skipped) {
        actions.add('brave_ext_partial');
      }

      final List<DerivativeExtensionApplyResult> derivativeResults =
          await ChromiumDerivativeExtensionService.instance.applyAllInstalled(
        reason: 'force_install_$reason',
        force: force,
      );
      for (final DerivativeExtensionApplyResult dr in derivativeResults) {
        actions.add(
          dr.ok ? 'derivative_${dr.browserId}' : 'derivative_${dr.browserId}_partial',
        );
      }

      String? chromeFolder =
          chromeExport.ok ? chromeExport.path : null;
      chromeFolder ??= await ChromeExtensionPayloadService.resolveValidSource();
      final String? firefoxFolder =
          firefoxExport.ok ? firefoxExport.path : null;

      // ── 2. Chrome / Edge: sync + HKCU self-heal ──
      await ChromeExtensionAutoSyncService.instance.syncIfNeeded(
        force: true,
        reason: 'force_install_$reason',
      );
      actions.add('chrome_auto_sync');

      final ExtensionSelfHealResult heal =
          await WindowsExtensionSelfHealService.instance.runSelfHeal(
        attemptElevated: attemptElevated && (userInitiated || force || reason == 'boot'),
        userInitiated: userInitiated || force,
        chromeSourceOverride: chromeFolder,
      );
      actions.add('self_heal:${heal.tier.name}');

      // ── 3. Firefox: XPI + profiles (no admin) ──
      if (firefoxFolder != null) {
        await _mirrorFirefoxToLocalAppData(firefoxFolder);
        actions.add('firefox_localappdata');
        try {
          final File xpi =
              await FirefoxXpiPackager.instance.ensureProgramDataXpi(
            sourceFolder: firefoxFolder,
          );
          actions.add('firefox_xpi');
          final List<String> profiles =
              await WindowsFirefoxExtensionInstallService.instance
                  .installXpiToAllProfiles(xpiFile: xpi);
          if (profiles.isNotEmpty) {
            actions.add('firefox_profiles:${profiles.length}');
          }
          await FirefoxConfigService.instance.disableDoHInAllProfiles();
          actions.add('firefox_doh_off');
        } catch (e) {
          AppLogger.instance.warn('firefox profile install failed', error: e);
          actions.add('firefox_xpi_fail');
        }
      }

      // ── 4. Elevated HKLM guard (Chrome + Edge + Firefox policies) ──
      ExtensionPolicyVerifyResult verify =
          await WindowsExtensionGuardService.verifyAllPolicies(force: true);
      final bool needElevated = !verify.chromeEnforcementReady ||
          !verify.edgeEnforcementReady ||
          !verify.firefoxEnforcementReady ||
          !verify.asideEnforcementReady;

      if (attemptElevated &&
          needElevated &&
          chromeFolder != null &&
          (userInitiated || force || reason == 'boot') &&
          (!await ExtensionGuardPrefs.instance.isElevatedGuardSkipped() ||
              force)) {
        actions.add('elevated_guard_attempt');
        final ExtensionGuardResult guard =
            await WindowsExtensionGuardService.instance.runElevatedGuard(
          chromeExtensionFolder: chromeFolder,
        );
        actions.add('elevated_guard:${guard.ok}');
        if (!guard.ok &&
            (guard.message.contains('UAC') || guard.message.contains('exit 2'))) {
          await ExtensionGuardPrefs.instance.setElevatedGuardSkipped(true);
        }
      }

      // ── 5. Launchers + shortcut hijack + tier3 ──
      if (chromeFolder != null) {
        await ChromeLoadExtensionLauncher.install(extensionFolder: chromeFolder);
        actions.add('load_extension_launchers');
        await ChromeShortcutHijackService.instance.apply(
          extensionFolder: chromeFolder,
          force: true,
        );
        actions.add('shortcut_hijack');
        await TierEnforcementService.instance.installAllTiers(
          extensionFolder: chromeFolder,
          force: force,
        );
        actions.add('tier_enforcement');
        final ChromeUnifyResult unify =
            await ChromeInstallDiscoveryService.instance.unifyInstalls(
          extensionFolder: chromeFolder,
          force: true,
        );
        actions.addAll(unify.actions);
      }

      WindowsExtensionGuardService.invalidateVerifyCache();
      verify = await WindowsExtensionGuardService.verifyAllPolicies(force: true);

      final ChromeInstallVerifyReport chromeVerify =
          await ChromeExtensionInstallVerifier.instance.verifyAndRepair(
        reason: reason,
        force: force,
      );
      actions.add('chrome_verify:${chromeVerify.ok}');
      if (chromeVerify.chromeInstallCount > 1) {
        actions.add('chrome_multi:${chromeVerify.chromeInstallCount}');
      }

      final bool chromeOk =
          chromeVerify.ok || verify.chromeEnforcementReady;
      final bool ok = chromeOk &&
          verify.edgeEnforcementReady &&
          verify.firefoxEnforcementReady;

      final String verdict = ok
          ? 'Chrome · Edge · Firefox 확장 자동 설치 완료'
          : _verdictFor(verify, chromeVerify);

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: verdict,
        data: <String, Object?>{
          'reason': reason,
          'actions': actions,
          'chromeReady': chromeOk,
          'chromeInProfile': chromeVerify.installedInProfile,
          'chromeInstallCount': chromeVerify.chromeInstallCount,
          'edgeReady': verify.edgeEnforcementReady,
          'firefoxReady': verify.firefoxEnforcementReady,
        },
        debounceKey: 'force_install',
      );

      AppLogger.instance.info(
        'browser_ext_force_install: done ok=$ok actions=$actions',
      );

      return BrowserExtensionForceInstallReport(
        ok: ok,
        skipped: false,
        verdict: verdict,
        actions: actions,
        verify: verify,
      );
    } catch (e, st) {
      AppLogger.instance.error('browser_ext_force_install failed', error: e);
      AppLogger.instance.info('$st');
      return BrowserExtensionForceInstallReport(
        ok: false,
        skipped: false,
        verdict: '확장 자동 설치 오류: $e',
        actions: actions,
      );
    } finally {
      _running = false;
    }
  }

  static Future<void> _mirrorFirefoxToLocalAppData(String sourceFolder) async {
    final String dest = p.join(
      Platform.environment['LOCALAPPDATA'] ?? '',
      'SixVPNBlocker',
      'firefox_blocker',
    );
    final Directory src = Directory(sourceFolder);
    if (!await src.exists()) return;
    final Directory out = Directory(dest);
    if (await out.exists()) {
      await out.delete(recursive: true);
    }
    await out.create(recursive: true);
    await for (final FileSystemEntity e in src.list(recursive: true)) {
      if (e is! File) continue;
      final String rel = p.relative(e.path, from: sourceFolder);
      final File target = File(p.join(dest, rel));
      await target.parent.create(recursive: true);
      await e.copy(target.path);
    }
  }

  static String _verdictFor(
    ExtensionPolicyVerifyResult v,
    ChromeInstallVerifyReport chromeVerify,
  ) {
    final List<String> missing = <String>[];
    if (!v.chromeEnforcementReady && !chromeVerify.ok) {
      missing.add('Chrome');
    }
    if (!v.edgeEnforcementReady) missing.add('Edge');
    if (!v.firefoxEnforcementReady) missing.add('Firefox');
    if (missing.isEmpty) return chromeVerify.verdict;
    return '미완료: ${missing.join(' · ')} — ${chromeVerify.verdict}';
  }
}

final class BrowserExtensionForceInstallReport {
  const BrowserExtensionForceInstallReport({
    required this.ok,
    required this.skipped,
    required this.verdict,
    required this.actions,
    this.verify,
  });

  final bool ok;
  final bool skipped;
  final String verdict;
  final List<String> actions;
  final ExtensionPolicyVerifyResult? verify;
}
