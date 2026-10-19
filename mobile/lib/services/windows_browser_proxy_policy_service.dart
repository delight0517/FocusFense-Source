import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_load_extension_launcher.dart';
import 'windows_chromium_registry_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_protection_mode_prefs.dart';
import 'windows_browser_bypass_closer_service.dart';

/// Forces Chrome/Edge to use our PAC (HKCU policy — no UAC).
final class WindowsBrowserProxyPolicyService {
  WindowsBrowserProxyPolicyService._();
  WindowsBrowserProxyPolicyService.forTesting({
    required bool Function() protectionOff,
    required Future<void> Function() migrate,
    required Future<bool> Function(String) apply,
  }) : _protectionOffOverride = protectionOff,
       _migrateOverride = migrate,
       _applyOverride = apply;

  bool Function()? _protectionOffOverride;
  Future<void> Function()? _migrateOverride;
  Future<bool> Function(String)? _applyOverride;
  bool get _protectionOff =>
      _protectionOffOverride?.call() ??
      WindowsProtectionModePrefs.isProtectionExplicitlyOff;
  static final WindowsBrowserProxyPolicyService instance =
      WindowsBrowserProxyPolicyService._();

  static String get _enforceFlag => p.join(
    ChromeLoadExtensionLauncher.sixVpnDir,
    'youtube_enforce_active.flag',
  );

  /// Writes `youtube_enforce_active.flag` for tier3 / realtime guard.
  Future<void> setYoutubeEnforceActive(bool on) async {
    if (!Platform.isWindows || (on && _protectionOff)) return;
    try {
      final Directory dir = Directory(ChromeLoadExtensionLauncher.sixVpnDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final File f = File(_enforceFlag);
      if (on) {
        // OFF may arrive while the directory check/create is awaiting I/O.
        if (_protectionOff) return;
        await f.writeAsString('1', flush: true);
      } else if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<bool> isYoutubeEnforceActive() async {
    try {
      return await File(_enforceFlag).exists();
    } catch (_) {
      return false;
    }
  }

  /// Chrome + Edge MUST use sixvpn_block.pac (not optional “use system proxy”).
  Future<bool> forceChromiumPac({String? pacPath}) async {
    if (!Platform.isWindows || _protectionOff) return false;
    final String path = pacPath ?? WindowsEmergencyBlockService.pacPath();
    if (!await File(path).exists()) return false;

    await (_migrateOverride?.call() ??
        WindowsChromiumRegistryService.instance.migrateLegacyPacRegistry());
    if (_protectionOff) return false;
    // @incident: pac-manual-off — a second PowerShell writer could reapply
    // policies after OFF. Keep all writes in the OFF-aware registry service.
    final applied =
        await (_applyOverride?.call(path) ??
            WindowsChromiumRegistryService.instance.applyPacEverywhere(path));
    return !_protectionOff && applied;
  }

  Future<void> clearChromiumPac() async {
    if (!Platform.isWindows) return;
    await WindowsChromiumRegistryService.instance.clearOwnedPac(winInet: false);
    await WindowsBrowserBypassCloserService.instance.restoreOwnedHardening();
  }
}
