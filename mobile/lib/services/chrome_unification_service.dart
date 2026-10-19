import 'dart:io';

import 'app_logger.dart';
import 'chrome_browser_watchdog_service.dart';
import 'chrome_extension_install_verifier.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_install_discovery_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart'
    show ChromeShortcutHijackService, ShortcutHijackResult;
import 'protected_browser_realtime_guard_service.dart';
import 'easy_setup_bulletproof_prefs.dart';
import 'extension_rules_snapshot_service.dart';
import 'tier_enforcement_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_protection_mode_prefs.dart';

/// Windows: extension payload + launchers + policies (personal PC = HKLM via UAC).
final class ChromeUnificationService {
  ChromeUnificationService._();
  static final ChromeUnificationService instance = ChromeUnificationService._();

  /// Boot / easy-setup: repair payload, shortcuts, HKCU, then HKLM if still missing.
  Future<void> ensureUnifiedChrome({
    String? extensionFolder,
    bool applyPolicies = false,
  }) async {
    if (!Platform.isWindows) return;
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;

    try {
      String? folder = extensionFolder;
      if (folder != null &&
          !await ChromeExtensionPayloadService.hasManifest(folder)) {
        folder = null;
      }

      final String? stable =
          await ChromeExtensionPayloadService.ensureStablePayload(
            preferredSource: folder,
          );
      if (stable == null) {
        AppLogger.instance.warn(
          'chrome_unify: could not restore extension payload (manifest missing)',
        );
        return;
      }

      await ChromeLoadExtensionLauncher.install(extensionFolder: stable);
      await ChromeInstallDiscoveryService.instance.unifyInstalls(
        extensionFolder: stable,
        force: applyPolicies,
      );

      if (await EasySetupBulletproofPrefs.instance.hijackShortcuts()) {
        final ShortcutHijackResult hijack = await ChromeShortcutHijackService
            .instance
            .apply(extensionFolder: stable, force: applyPolicies);
        AppLogger.instance.info('chrome_unify hijack: ${hijack.message}');
      }

      if (applyPolicies) {
        await _ensureBrowserPolicies(stable);
      }

      if (await EasySetupBulletproofPrefs.instance.browserWatchdog()) {
        await ChromeBrowserWatchdogService.instance.install();
      } else if (await EasySetupBulletproofPrefs.instance.hijackShortcuts()) {
        await ChromeShortcutHijackService.instance
            .runPersistedScriptIfPresent();
      }

      await ProtectedBrowserRealtimeGuardService.instance.syncScriptOnly();

      final TierEnforcementResult tier = await TierEnforcementService.instance
          .installAllTiers(extensionFolder: stable, force: applyPolicies);
      AppLogger.instance.info('chrome_unify tier: ${tier.message}');
      await ExtensionRulesSnapshotService.instance.writeToChromePayload(
        sourceFolder: stable,
      );

      WindowsExtensionGuardService.invalidateVerifyCache();
      await ChromeExtensionInstallVerifier.instance.verifyAndRepair(
        reason: 'chrome_unify',
        force: applyPolicies,
      );
      AppLogger.instance.info(
        'chrome_unify: payload=$stable policies=$applyPolicies',
      );
    } catch (e) {
      AppLogger.instance.warn('chrome_unify failed', error: e);
    }
  }

  static Future<void> _ensureBrowserPolicies(String chromeStable) async {
    ExtensionPolicyVerifyResult v =
        await WindowsExtensionGuardService.verifyAllPolicies(force: true);
    if (v.protectionOk) return;

    final ExtensionSelfHealResult hkcu = await WindowsExtensionSelfHealService
        .instance
        .runIfNeeded(attemptElevated: false);
    v =
        hkcu.verify ??
        await WindowsExtensionGuardService.verifyAllPolicies(force: true);
    if (v.protectionOk) return;

    AppLogger.instance.info(
      'chrome_unify: HKCU/바로가기 모드 — 자동 UAC 생략 (설정에서 수동 고정 설치 가능)',
    );
  }
}
