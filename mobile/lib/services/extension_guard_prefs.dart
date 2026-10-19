import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// Persists extension guard source path + whether the policy watchdog is active.
final class ExtensionGuardPrefs {
  ExtensionGuardPrefs._();
  static final ExtensionGuardPrefs instance = ExtensionGuardPrefs._();
  ExtensionGuardPrefs.forTesting(Directory stateDirectory)
    : _stateDirectoryOverride = stateDirectory;

  Directory? _stateDirectoryOverride;

  static const List<String> managedBrowserIds = <String>[
    'chrome',
    'edge',
    'firefox',
    'aside',
  ];

  String browserDisabledMarkerPath(String browserId) {
    if (!managedBrowserIds.contains(browserId)) {
      throw ArgumentError.value(browserId, 'browserId');
    }
    final String state =
        _stateDirectoryOverride?.path ??
        path.join(
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
          'SixVPNBlocker',
        );
    return path.join(state, 'extension_disabled_${browserId}_v1.json');
  }

  bool isBrowserExplicitlyDisabled(String browserId) =>
      managedBrowserIds.contains(browserId) &&
      File(browserDisabledMarkerPath(browserId)).existsSync();

  bool get areManagedBrowsersExplicitlyDisabled =>
      managedBrowserIds.every(isBrowserExplicitlyDisabled);

  Future<void> setBrowserEnabled(String browserId, bool enabled) async {
    final File marker = File(browserDisabledMarkerPath(browserId));
    if (enabled) {
      if (await marker.exists()) await marker.delete();
    } else {
      await marker.parent.create(recursive: true);
      await marker.writeAsString(
        jsonEncode(<String, Object?>{
          'browser': browserId,
          'disabled': true,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    }
  }

  static String? browserIdForRegistryRoot(String root) {
    final String normalized = root.replaceAll('/', r'\').toLowerCase();
    final String? browser = normalized.contains(r'google\chrome')
        ? 'chrome'
        : normalized.contains(r'microsoft\edge')
        ? 'edge'
        : normalized.contains(r'mozilla\firefox')
        ? 'firefox'
        : normalized.contains(r'\chromium')
        ? 'aside'
        : null;
    return browser;
  }

  bool isRegistryRootExplicitlyDisabled(String root) {
    final browser = browserIdForRegistryRoot(root);
    return browser != null && isBrowserExplicitlyDisabled(browser);
  }

  static const String _watchdogKey = 'extension_guard_watchdog_v1';
  static const String _chromePathKey = 'extension_guard_chrome_path_v1';
  static const String _loadExtFallbackKey =
      'extension_load_extension_fallback_v1';
  static const String _skipElevatedKey = 'extension_skip_elevated_guard_v1';

  Future<bool> isWatchdogEnabled() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_watchdogKey) ?? false;
  }

  Future<void> setWatchdogEnabled(bool enabled) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_watchdogKey, enabled);
  }

  Future<String?> chromeSourcePath() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String? v = p.getString(_chromePathKey);
    if (v == null || v.trim().isEmpty) return null;
    return v.trim();
  }

  Future<void> setChromeSourcePath(String path) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString(_chromePathKey, path.trim());
  }

  Future<bool> isLoadExtensionFallback() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_loadExtFallbackKey) ?? false;
  }

  Future<void> setLoadExtensionFallback(bool value) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_loadExtFallbackKey, value);
  }

  /// Corporate PC: UAC/HKLM repeatedly fails — skip auto UAC prompts.
  Future<bool> isElevatedGuardSkipped() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_skipElevatedKey) ?? false;
  }

  Future<void> setElevatedGuardSkipped(bool skip) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_skipElevatedKey, skip);
  }
}
