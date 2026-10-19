import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/browser_extension_asset_manifest.dart';
import 'app_logger.dart';
import 'browser_extension_export_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'extension_guard_prefs.dart';
import 'firefox_xpi_packager.dart';
import 'universal_browser_block_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_firefox_extension_install_service.dart';
import 'windows_policy_acl_unlock_service.dart';

/// Re-applies Chrome/Edge/Firefox enterprise extension policies when registry
/// keys are tampered with (debounced UAC, 90s poll while app runs).
final class WindowsExtensionPolicyWatchdog {
  WindowsExtensionPolicyWatchdog._();
  static final WindowsExtensionPolicyWatchdog instance =
      WindowsExtensionPolicyWatchdog._();

  // Tighter cadence — the user complaint was that the plugin could be
  // deleted from Chrome's UI. With a 2-min/5-min schedule the gap between
  // "user clicks Remove" and "watchdog re-applies force-install policy"
  // is too long for the next Chrome launch to find the policy intact.
  // PERFORMANCE BUDGET (CLAUDE.md): probes that spawn >2 child processes
  // must fire ≥5 minutes. This watchdog's tick runs verifyAllPolicies +
  // _detectMissingLayers + sometimes the full UniversalBrowserBlockService.
  // syncNow — easily 10+ reg.exe + powershell.exe spawns per tick. At the
  // old 60s cadence this drove ~0.5 CPU/sec sustained and also caused
  // race conditions where overlapping syncNow runs from watchdog + boot +
  // requestApply truncated the URLBlocklist mid-write (24 entries instead
  // of 1000). 5min is the safety net; real-time apply still happens via
  // BlockSyncService.requestApply when the user edits rules.
  static const Duration kPollInterval = Duration(minutes: 5);
  // @incident: heal_storm_hkcu_thrashing — 3-min floor prevents re-heal
  // storms/HKCU thrashing if forcelist keeps flapping.
  static const Duration kHealCooldown = Duration(minutes: 3);
  static const Duration kStartupDelay = Duration(seconds: 60);

  Timer? _timer;
  bool _tickRunning = false;
  bool _allowElevation = true;
  DateTime? _lastHealAttempt;

  bool get isSupported => Platform.isWindows;

  void start({bool allowElevation = true}) {
    _allowElevation = allowElevation;
    if (!isSupported) return;
    _timer?.cancel();
    _timer = Timer.periodic(kPollInterval, (_) {
      unawaited(tick());
    });
    Future<void>.delayed(kStartupDelay, () {
      if (_timer != null) unawaited(tick());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// True when the extension files are actually on disk (not just policy OK).
  static Future<bool> _extensionFilesPresent() async {
    // Check both known deployment locations.
    final List<String> candidates = <String>[
      p.join(
        Platform.environment['ProgramData'] ?? r'C:\ProgramData',
        'SixVPNBlocker',
        'chrome_blocker',
      ),
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'SixVPNBlocker',
        'chrome_blocker',
      ),
    ];
    for (final String dir in candidates) {
      if (await File(p.join(dir, 'manifest.json')).exists()) return true;
    }
    // Also check saved pref path.
    final String? saved = await ExtensionGuardPrefs.instance.chromeSourcePath();
    if (saved != null && await File(p.join(saved, 'manifest.json')).exists()) {
      return true;
    }
    // Check --load-extension launcher shortcut still works.
    final String launcherDir = ChromeLoadExtensionLauncher.sixVpnDir;
    final File launcher = File(p.join(launcherDir, 'launch_chrome.bat'));
    return launcher.existsSync();
  }

  Future<void> tick() async {
    if (!isSupported || _tickRunning) return;
    if (ExtensionGuardPrefs.instance.areManagedBrowsersExplicitlyDisabled) {
      return;
    }
    if (!await ExtensionGuardPrefs.instance.isWatchdogEnabled()) return;

    _tickRunning = true;
    try {
      // Always re-export assets first so we always have a source folder.
      String? source = await ExtensionGuardPrefs.instance.chromeSourcePath();
      final bool filesPresent = await _extensionFilesPresent();

      if (!filesPresent) {
        // Extension files missing (e.g. app was uninstalled/reinstalled) —
        // force re-export from bundled assets regardless of policy state.
        AppLogger.instance.warn(
          'watchdog: extension files missing — forcing re-export & heal',
        );
        final BrowserExtensionExportResult export =
            await BrowserExtensionExportService.exportAssets(
              assetPaths: BrowserExtensionAssetManifest.chrome,
              subdirName: BrowserExtensionExportService.kChromeSubdir,
            );
        if (export.ok) {
          await ExtensionGuardPrefs.instance.setChromeSourcePath(export.path);
          source = export.path;
        }
        // Skip cooldown — files missing is always an emergency.
        _lastHealAttempt = null;
      } else if (source == null || source.isEmpty) {
        final BrowserExtensionExportResult export =
            await BrowserExtensionExportService.exportAssets(
              assetPaths: BrowserExtensionAssetManifest.chrome,
              subdirName: BrowserExtensionExportService.kChromeSubdir,
            );
        if (export.ok) {
          await ExtensionGuardPrefs.instance.setChromeSourcePath(export.path);
          source = export.path;
        }
      }

      // Watchdog ticks every 60 s — invalidate the verify cache so we
      // actually see registry tampering (user manually deleting policy keys
      // or extension) instead of trusting a stale "OK" snapshot.
      WindowsExtensionGuardService.invalidateVerifyCache();
      final ExtensionPolicyVerifyResult v =
          await WindowsExtensionGuardService.verifyAllPolicies(force: true);

      // Per-layer audit + apply. Each browser is independent — if Edge's
      // forcelist is missing but Chrome's is fine, we apply ONLY the Edge
      // piece instead of running the full self-heal pipeline. This is what
      // "앱에서 적용되지 않은 부분은 자체적으로 점검·적용" maps to.
      final List<String> missing = _detectMissingLayers(v, filesPresent);
      if (missing.isEmpty) return;

      // Detect ACL lockdown — if the HKCU policy key is read-only for the
      // current user, our reg.exe writes have been silently failing and the
      // URLBlocklist / ExtensionInstallForcelist stay empty. Fire the
      // one-shot UAC unlock so subsequent watchdog ticks can actually write.
      final bool aclWritable = await WindowsPolicyAclUnlockService.instance
          .hkcuPoliciesWritable();
      if (!aclWritable && _allowElevation) {
        AppLogger.instance.warn(
          'watchdog: HKCU policy keys are ACL-locked — '
          'every reg write is silently failing. Triggering UAC unlock.',
        );
        await WindowsPolicyAclUnlockService.instance
            .runElevatedUnlockIfNeeded();
      }

      // Firefox profile XPI is a no-UAC sideload — re-apply it inline as
      // soon as we detect it missing, without waiting for the heavy
      // self-heal cooldown.
      if (missing.contains('firefox_policy')) {
        await _reapplyFirefoxProfileXpi();
      }

      // The URLBlocklist policy is what catches the user's per-video /
      // per-channel YouTube blocks AT THE BROWSER, even without the
      // extension loaded. It's written by UniversalBrowserBlockService —
      // re-trigger it whenever ANY policy piece is missing or whenever we
      // can't read URLBlocklist for the current set of patterns.
      if (missing.isNotEmpty) {
        unawaited(
          UniversalBrowserBlockService.instance.syncNow(reason: 'watchdog'),
        );
      }

      if (missing.isEmpty) return;

      final DateTime now = DateTime.now();
      if (_lastHealAttempt != null &&
          now.difference(_lastHealAttempt!) < kHealCooldown) {
        // @incident: hkcu_locked_last_resort — HKCU-only re-apply is
        // intentionally exempt from the main cooldown; it's the last-resort
        // guarantee when the ACL is locked and must not be rate-limited the
        // same way.
        // Even inside the cooldown, do the cheap HKCU re-write — that's the
        // un-deletable guarantee. Skip only the heavyweight full self-heal.
        if (source != null) {
          unawaited(
            WindowsExtensionSelfHealService.instance.reapplyHkcuOnly(
              sourceFolder: source,
            ),
          );
        }
        return;
      }
      _lastHealAttempt = now;

      AppLogger.instance.info(
        'watchdog: self-heal triggered — missing=${missing.join(",")} '
        '(policyOk=${v.protectionOk} filesPresent=$filesPresent)',
      );
      await WindowsExtensionSelfHealService.instance.runSelfHeal(
        attemptElevated: false,
        userInitiated: false,
        chromeSourceOverride: source,
      );
    } finally {
      _tickRunning = false;
    }
  }

  /// No-UAC Firefox re-apply: rebuild XPI from disk source, then sideload it
  /// into every Firefox profile's `extensions` folder. Idempotent.
  static Future<void> _reapplyFirefoxProfileXpi() async {
    try {
      final String? source = await ExtensionGuardPrefs.instance
          .chromeSourcePath();
      final String? parent = source != null ? p.dirname(source) : null;
      final String firefoxFolder = parent != null
          ? p.join(parent, 'firefox_blocker')
          : '';
      if (firefoxFolder.isEmpty ||
          !await File(p.join(firefoxFolder, 'manifest.json')).exists()) {
        // No usable Firefox source on disk — let the heavy self-heal
        // (called by tick) export from bundled assets.
        return;
      }
      final File xpi = await FirefoxXpiPackager.instance.ensureProgramDataXpi(
        sourceFolder: firefoxFolder,
      );
      final List<String> profiles = await WindowsFirefoxExtensionInstallService
          .instance
          .installXpiToAllProfiles(xpiFile: xpi);
      AppLogger.instance.info(
        'watchdog: firefox profile XPI re-applied → ${profiles.length} profiles',
      );
    } catch (e) {
      AppLogger.instance.warn('watchdog: firefox re-apply failed: $e');
    }
  }

  /// Returns a human-readable list of layers the app expected to apply but
  /// can no longer detect (so the user / logs see exactly what was missing).
  static List<String> _detectMissingLayers(
    ExtensionPolicyVerifyResult v,
    bool filesPresent,
  ) {
    final List<String> missing = <String>[];
    if (!filesPresent) missing.add('files');
    final bool chromeWanted = !ExtensionGuardPrefs.instance
        .isBrowserExplicitlyDisabled('chrome');
    final bool edgeWanted = !ExtensionGuardPrefs.instance
        .isBrowserExplicitlyDisabled('edge');
    if (chromeWanted &&
        !v.chromeHkcuOk &&
        !v.chromeHklmOk &&
        !v.chromeUserInstallOk) {
      missing.add('chrome_policy');
    }
    if (edgeWanted && !v.edgeHkcuOk && !v.edgeHklmOk && !v.edgeUserInstallOk) {
      missing.add('edge_policy');
    }
    if (!ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('firefox') &&
        !v.firefoxPolicyOk) {
      missing.add('firefox_policy');
    }
    if (chromeWanted && !v.chromeForcelistOk && !v.chromeHkcuForcelistOk) {
      missing.add('chrome_forcelist');
    }
    if (edgeWanted && !v.edgeForcelistOk && !v.edgeHkcuForcelistOk) {
      missing.add('edge_forcelist');
    }
    return missing;
  }
}
