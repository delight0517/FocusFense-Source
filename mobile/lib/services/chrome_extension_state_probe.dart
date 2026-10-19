import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_extension_identity.dart';

/// Reads Chrome/Edge profile prefs to detect developer-mode (unpacked) loads.
final class ChromeExtensionStateProbe {
  ChromeExtensionStateProbe._();

  static const String kExtensionId = ChromeExtensionIdentity.extensionId;

  /// `true` when the extension appears loaded as unpacked / dev copy.
  static Future<bool> hasDeveloperModeCopy({String browser = 'chrome'}) async {
    final ChromeExtensionProbeResult r = await probe(browser: browser);
    return r.hasUnpackedCopy;
  }

  static Future<ChromeExtensionProbeResult> probe({
    String browser = 'chrome',
    String? userDataRootForTesting,
  }) async {
    if (!Platform.isWindows) {
      return const ChromeExtensionProbeResult(
        hasUnpackedCopy: false,
        hasRegistryManaged: false,
        detail: 'Windows 전용',
      );
    }
    final String? userData = userDataRootForTesting ?? _userDataRoot(browser);
    if (userData == null) {
      return const ChromeExtensionProbeResult(
        hasUnpackedCopy: false,
        hasRegistryManaged: false,
        detail: '브라우저 프로필 폴더를 찾지 못했습니다.',
      );
    }
    bool unpacked = false;
    bool managed = false;
    bool store = false;
    bool enabled = false;
    bool notPresent = true;
    final Set<String> matchedIds = <String>{};

    // Scan profiles: Chrome-style User Data\Default, or Opera flat Default.
    final List<String> candidates = <String>[];
    final File flatPrefs = File(p.join(userData, 'Preferences'));
    if (await flatPrefs.exists()) {
      candidates.add('');
    } else {
      candidates.add('Default');
      try {
        final Directory ud = Directory(userData);
        await for (final FileSystemEntity e in ud.list()) {
          if (e is Directory) {
            final String name = p.basename(e.path);
            if (name.startsWith('Profile ')) candidates.add(name);
          }
        }
      } catch (_) {}
    }

    for (final String profile in candidates) {
      final String profilePath = profile.isEmpty
          ? userData
          : p.join(userData, profile);
      final ChromeExtensionProbeResult row = await readProfilePreferences(
        Directory(profilePath),
        browser: browser,
      );
      unpacked = unpacked || row.hasUnpackedCopy;
      managed = managed || row.hasRegistryManaged;
      store = store || row.hasStoreCopy;
      enabled = enabled || row.hasEnabledCopy;
      notPresent = notPresent && row.extensionNotPresent;
      matchedIds.addAll(row.matchedExtensionIds);
    }

    final StringBuffer detail = StringBuffer();
    if (unpacked) {
      detail.writeln(
        '「압축 해제됨」개발자 모드 복사본이 감지되었습니다.\n'
        'chrome://extensions 에서 **제거**한 뒤 Chrome을 완전히 종료·재실행하세요.',
      );
    }
    if (store) {
      detail.writeln('스토어 확장 설치 기록이 있습니다. 강제 설치/삭제 잠금 증거는 아닙니다.');
    }
    if (managed && !unpacked) {
      detail.writeln('관리자/레지스트리 설치 형태로 보입니다.');
    }
    if (notPresent) {
      detail.writeln(
        '이 PC의 Chrome 프로필에 확장이 아직 없습니다. '
        '앱이 자동으로 복구를 시도합니다.',
      );
    }
    return ChromeExtensionProbeResult(
      hasUnpackedCopy: unpacked,
      hasRegistryManaged: managed,
      hasStoreCopy: store,
      hasEnabledCopy: enabled,
      matchedExtensionIds: matchedIds.toList(growable: false),
      extensionNotPresent: notPresent,
      detail: detail.toString().trim(),
    );
  }

  static String? _userDataRoot(String browser) {
    final String? local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    if (browser == 'opera' || browser == 'opera_gx') {
      final String? roaming = Platform.environment['APPDATA'];
      if (roaming == null || roaming.isEmpty) return null;
      final String sub = browser == 'opera_gx'
          ? p.join('Opera Software', 'Opera GX Stable')
          : p.join('Opera Software', 'Opera Stable');
      final Directory d = Directory(p.join(roaming, sub));
      return d.existsSync() ? d.path : null;
    }

    final String sub = switch (browser) {
      'edge' => p.join('Microsoft', 'Edge', 'User Data'),
      'aside' => p.join('Aside', 'User Data'),
      'brave' => p.join('BraveSoftware', 'Brave-Browser', 'User Data'),
      'vivaldi' => p.join('Vivaldi', 'User Data'),
      'whale' => p.join('Naver', 'Naver Whale', 'User Data'),
      _ => p.join('Google', 'Chrome', 'User Data'),
    };
    Directory d = Directory(p.join(local, sub));
    if (d.existsSync()) return d.path;
    if (browser == 'whale') {
      d = Directory(p.join(local, 'NAVER', 'Whale', 'User Data'));
      if (d.existsSync()) return d.path;
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _readPrefs(File prefs) async {
    try {
      final String raw = await prefs.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  /// One read-only profile reader shared by Chrome/Edge channel diagnostics.
  static Future<ChromeExtensionProbeResult> readProfilePreferences(
    Directory profileDirectory, {
    String browser = 'chrome',
  }) async {
    final Map<String, dynamic>? ordinary = await _readPrefs(
      File(p.join(profileDirectory.path, 'Preferences')),
    );
    final Map<String, dynamic>? secure = await _readPrefs(
      File(p.join(profileDirectory.path, 'Secure Preferences')),
    );
    return fromPreferenceDocuments(ordinary, secure, browser: browser);
  }

  /// Merge by ID before deriving state: a secure entry replaces the WHOLE
  /// ordinary entry, including disabled/unknown state. Never OR stale copies.
  static ChromeExtensionProbeResult fromPreferenceDocuments(
    Map<String, dynamic>? ordinary,
    Map<String, dynamic>? secure, {
    String browser = 'chrome',
  }) {
    Map<String, dynamic> entries(Map<String, dynamic>? document) {
      final Object? extensions = document?['extensions'];
      final Object? settings = extensions is Map
          ? extensions['settings']
          : null;
      return settings is Map
          ? Map<String, dynamic>.from(settings)
          : <String, dynamic>{};
    }

    // @incident: store-identity-detection — stale Preferences must not override
    // a disabled Secure Preferences entry for the same extension ID.
    final Map<String, dynamic> merged = <String, dynamic>{
      ...entries(ordinary),
      ...entries(secure),
    };
    return fromPreferences(<String, dynamic>{
      'extensions': <String, dynamic>{'settings': merged},
    }, browser: browser);
  }

  /// Pure, browser-scoped record inspection, also used by isolated fixtures.
  /// Installed records, enabled state and policy management are separate facts.
  static ChromeExtensionProbeResult fromPreferences(
    Map<String, dynamic> prefs, {
    String browser = 'chrome',
  }) {
    final Object? extRoot = prefs['extensions'];
    final Object? settings = extRoot is Map ? extRoot['settings'] : null;
    bool unpacked = false;
    bool managed = false;
    bool store = false;
    bool enabled = false;
    final List<String> matched = <String>[];
    if (settings is Map) {
      for (final String id
          in ChromeExtensionIdentity.recognizedExtensionIdsForBrowser(
            browser,
          )) {
        final Object? entry = settings[id];
        if (entry is! Map) continue;
        matched.add(id);
        final Object? location = entry['location'];
        final int? loc = location is num ? location.toInt() : null;
        unpacked = unpacked || loc == 4;
        // Store/internal location 1 is not a managed/force-installed policy.
        managed = managed || <int>{2, 3, 6, 7, 9}.contains(loc);
        store =
            store || (id != ChromeExtensionIdentity.extensionId && loc == 1);
        final Object? reasons = entry['disable_reasons'];
        final bool hasDisableReason = reasons is List
            ? reasons.isNotEmpty
            : reasons is num && reasons != 0;
        // @incident: store-identity-detection — Chromium state 1 is ENABLED,
        // not disabled. Unknown/disabled state must not claim active protection.
        enabled = enabled || (entry['state'] == 1 && !hasDisableReason);
      }
    }
    return ChromeExtensionProbeResult(
      hasUnpackedCopy: unpacked,
      hasRegistryManaged: managed,
      hasStoreCopy: store,
      hasEnabledCopy: enabled,
      matchedExtensionIds: matched,
      extensionNotPresent: matched.isEmpty,
      detail: '읽기 전용 확장 기록 확인',
    );
  }
}

final class ChromeExtensionProbeResult {
  const ChromeExtensionProbeResult({
    required this.hasUnpackedCopy,
    required this.hasRegistryManaged,
    required this.detail,
    this.extensionNotPresent = false,
    this.hasStoreCopy = false,
    this.hasEnabledCopy = false,
    this.matchedExtensionIds = const <String>[],
  });

  final bool hasUnpackedCopy;
  final bool hasRegistryManaged;
  final bool hasStoreCopy;
  final bool hasEnabledCopy;
  final List<String> matchedExtensionIds;

  /// True when no Chrome profile has any record of this extension at all.
  final bool extensionNotPresent;
  final String detail;

  /// Enabled store/external install, not proof of force-install or removal lock.
  bool get properlyInstalled =>
      hasEnabledCopy &&
      (hasStoreCopy || hasRegistryManaged) &&
      !hasUnpackedCopy;
}
