import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;
import 'windows_protection_mode_prefs.dart';
import 'extension_guard_prefs.dart';

/// Firefox bypasses the system DNS resolver when DNS-over-HTTPS (DoH) is on
/// — and DoH ships ON by default in recent Firefox builds. The browser asks
/// Cloudflare/Mozilla directly for the IP of `naver.com`, gets the real
/// answer, and never sees our `0.0.0.0` entry in `/etc/hosts`. So every
/// blocker that relies on hosts-file editing has to disable DoH in Firefox
/// or appear silently broken.
///
/// This service writes two layers of override:
///   * Per-profile `user.js` — owned by the user, no admin required, takes
///     effect at next Firefox launch.
///   * System-wide `policies.json` inside `Firefox.app/Contents/Resources/
///     distribution/` — applied by Firefox enterprise policy engine, locks
///     the setting so the user (or installer) can't undo it from the UI.
///     This file requires admin to write and is installed by the same
///     osascript that updates /etc/hosts in [MacSystemBlockService].
final class FirefoxConfigService {
  FirefoxConfigService._();
  FirefoxConfigService.forTesting({
    required bool Function() protectionOff,
    required Future<List<Directory>> Function() profiles,
    Future<void> Function()? beforeWrite,
  }) : _protectionOffOverride = protectionOff,
       _profilesOverride = profiles,
       _beforeWriteOverride = beforeWrite;
  bool Function()? _protectionOffOverride;
  Future<List<Directory>> Function()? _profilesOverride;
  Future<void> Function()? _beforeWriteOverride;
  Future<void> _profileWrites = Future<void>.value();
  bool get _protectionOff =>
      _protectionOffOverride?.call() ??
      (WindowsProtectionModePrefs.isProtectionExplicitlyOff ||
          ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('firefox'));
  static const managedBegin =
      '// === FocusFense managed network prefs BEGIN ===';
  static const managedEnd = '// === FocusFense managed network prefs END ===';

  // @incident: firefox-profile-overwrite — preserve every byte outside our
  // bounded region, including BOM/non-ASCII data; never rewrite live prefs.js.
  static List<int> mergeManagedNetworkPrefs(
    List<int> original, {
    required bool enabled,
  }) {
    final source = latin1.decode(original);
    final pattern = RegExp(
      r'\r?\n' +
          RegExp.escape(managedBegin) +
          r'\r?\n[\s\S]*?\r?\n' +
          RegExp.escape(managedEnd) +
          r'\r?\n',
    );
    final kept = source.replaceAll(pattern, '');
    if (kept.contains(managedBegin) || kept.contains(managedEnd)) {
      throw StateError(
        'Incomplete FocusFense network region; preserve profile for review',
      );
    }
    if (!enabled) return latin1.encode(kept);
    const prefs = '''user_pref("network.trr.mode", 5);
user_pref("network.trr.uri", "");
user_pref("network.trr.custom_uri", "");
user_pref("network.trr.bootstrapAddress", "");
user_pref("network.dns.disablePrefetchFromHTTPS", true);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.dns.echconfig.enabled", false);
user_pref("network.dns.use_https_rr_as_altsvc", false);
user_pref("network.dns.native_https_query", false);
user_pref("doh-rollout.disable-heuristics", true);
user_pref("doh-rollout.skipHeuristicsCheck", true);
user_pref("doh-rollout.mode", 5);
user_pref("doh-rollout.self-enabled", false);
user_pref("browser.privatebrowsing.autostart", false);''';
    return latin1.encode('$kept\n$managedBegin\n$prefs\n$managedEnd\n');
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<bool> _replaceUserJs(
    File file,
    List<int> before,
    List<int> after,
    bool existed,
    bool enabled,
  ) async {
    final temporary = File(p.join(file.parent.path, '.focusfense-user-js.tmp'));
    if (await FileSystemEntity.isLink(temporary.path)) {
      throw StateError('Linked temporary profile file is not safe to replace');
    }
    try {
      await temporary.writeAsBytes(after, flush: true);
      if (enabled && _protectionOff) return false;
      if (await file.exists() != existed ||
          (existed && !_sameBytes(await file.readAsBytes(), before))) {
        throw StateError('Firefox user.js changed before replacement');
      }
      if (await FileSystemEntity.isLink(file.path)) {
        throw StateError('Firefox user.js became a link');
      }
      if (enabled && _protectionOff) return false;
      if (Platform.isWindows) {
        final from = temporary.path.toNativeUtf16();
        final to = file.path.toNativeUtf16();
        try {
          final flags =
              win.MOVEFILE_WRITE_THROUGH |
              (existed ? win.MOVEFILE_REPLACE_EXISTING : 0);
          if (win.MoveFileEx(from, to, flags) == 0) {
            throw FileSystemException(
              'Firefox profile replacement failed',
              file.path,
              OSError('MoveFileEx', win.GetLastError()),
            );
          }
        } finally {
          calloc.free(from);
          calloc.free(to);
        }
      } else {
        await temporary.rename(file.path);
      }
      return true;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<List<String>> _updateManagedProfiles(bool enabled) async {
    final previous = _profileWrites;
    final released = Completer<void>();
    _profileWrites = released.future;
    try {
      await previous;
      if (!isSupported || (enabled && _protectionOff)) return [];
      final profiles = await profileDirs();
      final touched = <String>[];
      var failures = 0;
      for (final dir in profiles) {
        try {
          if (enabled && _protectionOff) break;
          final file = File(p.join(dir.path, 'user.js'));
          if (await FileSystemEntity.isLink(file.path)) {
            throw StateError('Linked user.js is not an owned profile file');
          }
          final existed = await file.exists();
          final before = existed ? await file.readAsBytes() : <int>[];
          final after = mergeManagedNetworkPrefs(before, enabled: enabled);
          if (_sameBytes(before, after)) {
            if (enabled) touched.add(dir.path);
            continue;
          }
          await _beforeWriteOverride?.call();
          if (enabled && _protectionOff) break;
          // An external editor changed the profile while we were preparing it.
          if (await file.exists() != existed ||
              (existed && !_sameBytes(await file.readAsBytes(), before))) {
            throw StateError('Firefox user.js changed during preparation');
          }
          if (enabled && _protectionOff) break;
          if (!await _replaceUserJs(file, before, after, existed, enabled)) {
            break;
          }
          touched.add(dir.path);
        } catch (_) {
          failures++;
        }
      }
      if (failures > 0) {
        throw StateError(
          'FocusFense could not update $failures Firefox profile(s); originals were preserved where rejected.',
        );
      }
      return touched;
    } finally {
      released.complete();
    }
  }

  Future<List<String>> removeManagedNetworkPrefsInAllProfiles() =>
      _updateManagedProfiles(false);
  static final FirefoxConfigService instance = FirefoxConfigService._();

  /// Enterprise `distribution/policies.json` body — matches the macOS
  /// hosts-install script. Locks DNS-over-HTTPS off (next Firefox launch).
  static const String kDistributionPolicyJson =
      '{"policies":{"DNSOverHTTPS":{"Enabled":false,"Locked":true},'
      '"NetworkPrediction":false}}';

  bool get isSupported => Platform.isMacOS || Platform.isWindows;

  /// Default Firefox profile root (per OS).
  Directory get _firefoxRoot {
    if (Platform.isMacOS) {
      final String home =
          Platform.environment['HOME'] ??
          '/Users/${Platform.environment['USER'] ?? ''}';
      return Directory(
        p.join(home, 'Library', 'Application Support', 'Firefox'),
      );
    }
    if (Platform.isWindows) {
      final String appData = Platform.environment['APPDATA'] ?? '';
      return Directory(p.join(appData, 'Mozilla', 'Firefox'));
    }
    return Directory('');
  }

  /// Lists every profile directory under Firefox/Profiles/. Includes named,
  /// default, and dev profiles. Tolerates "Profile 1" style names with spaces.
  Future<List<Directory>> profileDirs() async {
    if (_profilesOverride != null) return _profilesOverride!();
    if (!isSupported) return <Directory>[];
    final Directory profilesParent = Directory(
      p.join(_firefoxRoot.path, 'Profiles'),
    );
    if (!profilesParent.existsSync()) return <Directory>[];
    final List<FileSystemEntity> entries = await profilesParent.list().toList();
    return entries.whereType<Directory>().toList();
  }

  /// Kept for older callers. Firefox used to be pointed at the local PAC, but
  /// a stale or missing PAC makes normal pages fail with a proxy error.
  Future<List<String>> enablePacInAllProfiles(String pacUri) async {
    return applyNetworkBlockPrefsInAllProfiles();
  }

  /// Adds an owned region to user.js; never edits Firefox's live prefs.js.
  /// Returns the list of profile paths touched.
  Future<List<String>> disableDoHInAllProfiles({String? pacFilePath}) async {
    return applyNetworkBlockPrefsInAllProfiles(pacFilePath: pacFilePath);
  }

  /// DoH override only. WebsiteFilter/extension enforce URL rules independently
  /// of proxy configuration, so unrelated proxy preferences are preserved.
  Future<List<String>> applyNetworkBlockPrefsInAllProfiles({
    String? pacFilePath,
  }) => _updateManagedProfiles(true);

  /// Reads back the relevant TRR prefs from each profile's prefs.js (the
  /// Firefox-managed live store) so we can show the user whether DoH is
  /// truly off right now. A "missing" pref means "default", which for
  /// recent Firefox means DoH may be ON.
  Future<List<FirefoxProfileStatus>> probeProfiles() async {
    final List<FirefoxProfileStatus> out = <FirefoxProfileStatus>[];
    for (final Directory dir in await profileDirs()) {
      final File prefs = File(p.join(dir.path, 'prefs.js'));
      final File userJs = File(p.join(dir.path, 'user.js'));
      bool hasManagedRegion = false;
      if (await userJs.exists()) {
        try {
          final bytes = await userJs.readAsBytes();
          hasManagedRegion = !_sameBytes(
            bytes,
            mergeManagedNetworkPrefs(bytes, enabled: false),
          );
        } catch (_) {}
      }
      String? trrMode;
      if (prefs.existsSync()) {
        try {
          final String contents = await prefs.readAsString();
          final RegExpMatch? m = RegExp(
            r'user_pref\("network\.trr\.mode",\s*(\d+)\)',
          ).firstMatch(contents);
          trrMode = m?.group(1);
        } catch (_) {}
      }
      out.add(
        FirefoxProfileStatus(
          path: dir.path,
          userJsInstalled: hasManagedRegion,
          trrModeInPrefs: trrMode,
        ),
      );
    }
    return out;
  }

  /// Candidate locations where Firefox reads enterprise policies.
  List<String> get systemPolicyPaths {
    if (Platform.isMacOS) {
      return <String>[
        '/Library/Application Support/Mozilla/distribution/policies.json',
        '/Applications/Firefox.app/Contents/Resources/distribution/policies.json',
      ];
    }
    if (Platform.isWindows) {
      return <String>[
        r'C:\Program Files\Mozilla Firefox\distribution\policies.json',
        r'C:\Program Files (x86)\Mozilla Firefox\distribution\policies.json',
      ];
    }
    return <String>[];
  }

  /// Path of whichever candidate currently exists on disk (or the first one
  /// if none exist yet). Kept for callers that just want "where would this
  /// go" — not used for write decisions.
  String? get systemPolicyPath {
    for (final String path in systemPolicyPaths) {
      if (File(path).existsSync()) return path;
    }
    return systemPolicyPaths.isEmpty ? null : systemPolicyPaths.first;
  }

  /// True if our DoH-disable policy is already in place at any candidate.
  bool get systemPolicyInstalled {
    for (final String policyPath in systemPolicyPaths) {
      final File f = File(policyPath);
      if (!f.existsSync()) continue;
      try {
        final String c = f.readAsStringSync();
        if (c.contains('DNSOverHTTPS') && c.contains('"Locked": true')) {
          return true;
        }
      } catch (_) {
        /* try next */
      }
    }
    return false;
  }
}

class FirefoxProfileStatus {
  const FirefoxProfileStatus({
    required this.path,
    required this.userJsInstalled,
    required this.trrModeInPrefs,
  });
  final String path;
  final bool userJsInstalled;
  final String? trrModeInPrefs;

  /// Best-effort guess at whether DoH is effectively off for this profile.
  /// True only when we wrote `user.js` AND (no live trr.mode override OR
  /// the live override is also 5).
  bool get dohLikelyOff {
    if (!userJsInstalled) return false;
    final String? m = trrModeInPrefs;
    if (m == null) return true;
    return m == '5';
  }

  String displayName() => p.basename(path);
}
