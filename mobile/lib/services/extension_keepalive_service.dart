import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_extension_version.dart';
import 'extension_guard_prefs.dart';
import 'firefox_config_service.dart';
import 'firefox_xpi_packager.dart';
import 'windows_extension_guard_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_firefox_extension_install_service.dart';

/// Keeps Chrome/Edge/Firefox extension **updated** and **force-installed**
/// while 6 VPN Blocker is running.
abstract final class ExtensionKeepaliveService {
  ExtensionKeepaliveService._();

  static const Duration kStickyInterval = Duration(seconds: 90);

  static Timer? _timer;
  static bool _tickRunning = false;

  static void start() {
    if (!Platform.isWindows) return;
    _timer?.cancel();
    _timer = Timer.periodic(kStickyInterval, (_) {
      unawaited(tick(reason: 'interval'));
    });
    unawaited(tick(reason: 'start'));
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Sync bundled extension → disk, refresh updates.xml, re-apply HKCU policies.
  static Future<void> tick({String reason = 'manual'}) async {
    if (!Platform.isWindows || _tickRunning) return;
    if (!await ExtensionGuardPrefs.instance.isWatchdogEnabled()) return;
    if (ExtensionGuardPrefs.instance.areManagedBrowsersExplicitlyDisabled) {
      return;
    }

    _tickRunning = true;
    try {
      final String? folder =
          await ChromeExtensionPayloadService.ensureStablePayload();
      if (folder == null) {
        AppLogger.instance.warn('extension_keepalive: no payload ($reason)');
        return;
      }

      final bool stale = await ChromeExtensionVersion.installedIsStale();
      await WindowsExtensionSelfHealService.instance.reapplyHkcuOnly(
        sourceFolder: folder,
      );

      final ExtensionPolicyVerifyResult v =
          await WindowsExtensionGuardService.verifyAllPolicies(force: true);
      if (!v.requestedStateSatisfied() || stale) {
        AppLogger.instance.info(
          'extension_keepalive: heal stale=$stale protection=${v.protectionOk} ($reason)',
        );
        await WindowsExtensionSelfHealService.instance.runSelfHeal(
          attemptElevated: false,
          userInitiated: false,
          chromeSourceOverride: folder,
        );
      }

      await _ensureFirefoxExtensionSticky();
    } catch (e, st) {
      AppLogger.instance.warn('extension_keepalive failed: $e\n$st');
    } finally {
      _tickRunning = false;
    }
  }

  /// Re-copy Firefox XPI + HKCU force_installed when any profile is missing it.
  static Future<void> _ensureFirefoxExtensionSticky() async {
    if (ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('firefox')) {
      return;
    }
    try {
      final File xpi = File(FirefoxXpiPackager.programDataXpiPath);
      if (!await xpi.exists()) {
        await WindowsFirefoxExtensionInstallService.instance
            .applyHkcuExtensionPolicy();
        return;
      }
      final List<Directory> profiles = await FirefoxConfigService.instance
          .profileDirs();
      bool missing = profiles.isEmpty;
      for (final Directory prof in profiles) {
        final File dest = File(
          p.join(prof.path, 'extensions', FirefoxXpiPackager.kXpiFileName),
        );
        if (!await dest.exists()) {
          missing = true;
          break;
        }
      }
      if (!missing) return;
      final List<String> touched = await WindowsFirefoxExtensionInstallService
          .instance
          .installXpiToAllProfiles(xpiFile: xpi);
      await WindowsFirefoxExtensionInstallService.applyHkcuExtensionSettingsRegistry(
        xpiUrl: FirefoxXpiPackager.fileUrlForXpi(xpi.path),
      );
      AppLogger.instance.info(
        'extension_keepalive: firefox XPI restored → ${touched.length} profiles',
      );
    } catch (e) {
      AppLogger.instance.warn('extension_keepalive: firefox sticky failed: $e');
    }
  }
}
