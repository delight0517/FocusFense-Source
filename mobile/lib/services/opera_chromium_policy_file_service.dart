import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import '../utils/numeric_suffix_evasion.dart';
import 'chrome_extension_identity.dart';
import 'chromium_policy_service.dart';

/// Opera / Opera GX often block creating `HKCU\...\Opera Software\...` keys
/// (ACCESS_DENIED on some PCs). Chromium-based Opera also reads enterprise
/// policy from the profile `policies\managed\policies.json` folder.
final class OperaChromiumPolicyFileService {
  OperaChromiumPolicyFileService._();
  static final OperaChromiumPolicyFileService instance =
      OperaChromiumPolicyFileService._();

  static const int _kMaxEntries = 1000;

  static const List<({String id, String profileFolder})> _kTargets =
      <({String id, String profileFolder})>[
    (id: 'opera', profileFolder: 'Opera Stable'),
    (id: 'opera_gx', profileFolder: 'Opera GX Stable'),
  ];

  static String? _managedPolicyFile(String profileFolder) {
    final String appData = Platform.environment['APPDATA'] ?? '';
    if (appData.isEmpty) return null;
    return p.join(
      appData,
      'Opera Software',
      profileFolder,
      'policies',
      'managed',
      'policies.json',
    );
  }

  /// Returns profile policy path when the JSON file exists and has URLBlocklist.
  static String? managedPolicyPathForBrowser(String browserId) {
    for (final ({String id, String profileFolder}) t in _kTargets) {
      if (t.id == browserId) return _managedPolicyFile(t.profileFolder);
    }
    return null;
  }

  /// Writes URLBlocklist (+ DNS/incognito knobs) for each installed Opera profile.
  Future<List<String>> applyFromActivePatterns() async {
    if (!Platform.isWindows) return <String>[];
    final List<String> patterns =
        await ChromiumPolicyService.activeBlocklistPatternsForChromium();
    return applyPatterns(patterns);
  }

  Future<List<String>> applyPatterns(List<String> patterns) async {
    if (!Platform.isWindows || patterns.isEmpty) return <String>[];
    final List<String> slice = patterns.length > _kMaxEntries
        ? patterns.sublist(0, _kMaxEntries)
        : patterns;

    final String localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    if (localAppData.isEmpty) return <String>[];
    final String updatePath = p.join(
      localAppData,
      'SixVPNBlocker',
      'chrome_blocker',
      'updates.xml',
    );
    if (!await File(updatePath).exists()) {
      AppLogger.instance.warn(
        'opera_policy_file: extension update manifest missing at $updatePath',
      );
      return <String>[];
    }

    final Map<String, Object?> body = <String, Object?>{
      'URLBlocklist': slice,
      'BuiltInDnsClientEnabled': false,
      'DnsOverHttpsMode': 'off',
      'IncognitoModeAvailability': 1,
    };
    final String extensionId = ChromeExtensionIdentity.extensionId;
    final Uri updateUri = Uri.file(updatePath, windows: true);

    final List<String> written = <String>[];
    for (final ({String id, String profileFolder}) t in _kTargets) {
      final String? dest = _managedPolicyFile(t.profileFolder);
      if (dest == null) continue;
      final String profileRoot = p.dirname(p.dirname(p.dirname(dest)));
      if (!await Directory(profileRoot).exists()) continue;
      try {
        final File policyFile = File(dest);
        final File backupFile = File('$dest.focusfense-backup');
        if (await policyFile.exists() && !await backupFile.exists()) {
          await backupFile.writeAsBytes(await policyFile.readAsBytes(), flush: true);
        }
        if (await policyFile.exists()) {
          final Object? decoded = jsonDecode(await policyFile.readAsString());
          if (decoded is Map) {
            body.addAll(decoded.map<String, Object?>(
              (Object? key, Object? value) => MapEntry<String, Object?>(
                key.toString(),
                value,
              ),
            ));
          }
        }
        body['URLBlocklist'] = slice;
        body['BuiltInDnsClientEnabled'] = false;
        body['DnsOverHttpsMode'] = 'off';
        body['IncognitoModeAvailability'] = 1;
        final Object? rawSettings = body['ExtensionSettings'];
        final Map<String, Object?> settings = rawSettings is Map
            ? rawSettings.map<String, Object?>(
                (Object? key, Object? value) => MapEntry<String, Object?>(
                  key.toString(),
                  value,
                ),
              )
            : <String, Object?>{};
        settings[extensionId] = <String, Object>{
          'installation_mode': 'force_installed',
          'toolbar_pin': 'force_pinned',
          'update_url': updateUri.toString(),
          'override_update_url': true,
        };
        body['ExtensionSettings'] = settings;
        final String json = const JsonEncoder.withIndent('  ').convert(body);
        await Directory(p.dirname(dest)).create(recursive: true);
        await File('$dest.focusfense-patterns.json').writeAsString(
          jsonEncode(slice),
          flush: true,
          encoding: utf8,
        );
        await File(dest).writeAsString('$json\n', flush: true, encoding: utf8);
        written.add(t.id);
        AppLogger.instance.info(
          'opera_policy_file: wrote ${slice.length} patterns + force-install '
          'extension $extensionId -> $dest',
        );
      } catch (e) {
        AppLogger.instance.warn(
          'opera_policy_file: failed $dest — $e',
        );
      }
    }
    return written;
  }

  /// Restore each profile's policy file captured before FocusFense first
  /// applied policies. This makes the file-based Opera fallback reversible.
  Future<List<String>> restoreBackups() async {
    if (!Platform.isWindows) return <String>[];
    final List<String> restored = <String>[];
    final Set<String> activePatterns = (await ChromiumPolicyService
            .activeBlocklistPatternsForChromium())
        .map((String value) => value.trim().toLowerCase())
        .where((String value) => value.isNotEmpty)
        .toSet();
    for (final ({String id, String profileFolder}) t in _kTargets) {
      final String? dest = _managedPolicyFile(t.profileFolder);
      if (dest == null) continue;
      final File backup = File('$dest.focusfense-backup');
      if (!await backup.exists()) continue;
      try {
        final File receipt = File('$dest.focusfense-patterns.json');
        Set<String> focusPatterns = activePatterns;
        if (await receipt.exists()) {
          final Object? receiptJson =
              jsonDecode(await receipt.readAsString(encoding: utf8));
          if (receiptJson is List) {
            focusPatterns = receiptJson
                .whereType<String>()
                .map((String value) => value.trim().toLowerCase())
                .where((String value) => value.isNotEmpty)
                .toSet();
          }
        }
        final Object? decoded =
            jsonDecode(await backup.readAsString(encoding: utf8));
        if (decoded is! Map) {
          AppLogger.instance.warn(
            'opera_policy_file: backup is not a JSON object: ${backup.path}',
          );
          continue;
        }
        final Map<String, Object?> body = decoded.map<String, Object?>(
          (Object? key, Object? value) =>
              MapEntry<String, Object?>(key.toString(), value),
        );
        final Object? rawBlocklist = body['URLBlocklist'];
        if (rawBlocklist is List) {
          final List<Object?> preserved = rawBlocklist
              .where(
                (Object? value) =>
                    value is! String ||
                    !focusPatterns.contains(value.trim().toLowerCase()),
              )
              .toList();
          if (preserved.isEmpty) {
            body.remove('URLBlocklist');
          } else {
            body['URLBlocklist'] = preserved;
          }
        }
        final Object? rawSettings = body['ExtensionSettings'];
        if (rawSettings is Map) {
          final Map<String, Object?> settings = rawSettings
              .map<String, Object?>(
                (Object? key, Object? value) =>
                    MapEntry<String, Object?>(key.toString(), value),
              );
          settings.remove(ChromeExtensionIdentity.extensionId);
          if (settings.isEmpty) {
            body.remove('ExtensionSettings');
          } else {
            body['ExtensionSettings'] = settings;
          }
        }
        await Directory(p.dirname(dest)).create(recursive: true);
        await File(dest).writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(body)}\n',
          flush: true,
          encoding: utf8,
        );
        await backup.delete();
        if (await receipt.exists()) await receipt.delete();
        restored.add(t.id);
      } catch (e) {
        AppLogger.instance.warn('opera_policy_file: restore failed $dest — $e');
      }
    }
    return restored;
  }

  /// Probe file policy — used when HKCU registry URLBlocklist is missing.
  static Future<({bool ok, int count, String? path})> probeFilePolicy(
    String browserId, {
    List<String> expectedPatterns = const <String>[],
  }) async {
    final ({
      bool ok,
      int count,
      String? path,
      bool sampleMatch,
      bool numericApexOk,
    }) detailed = await probeFilePolicyDetailed(
      browserId,
      expectedPatterns: expectedPatterns,
    );
    return (ok: detailed.ok, count: detailed.count, path: detailed.path);
  }

  /// Full probe for health grading — mirrors registry sample/numeric checks.
  static Future<
      ({
        bool ok,
        int count,
        String? path,
        bool sampleMatch,
        bool numericApexOk,
      })> probeFilePolicyDetailed(
    String browserId, {
    List<String> expectedPatterns = const <String>[],
  }) async {
    final String? path = managedPolicyPathForBrowser(browserId);
    if (path == null || !await File(path).exists()) {
      return (
        ok: false,
        count: 0,
        path: path,
        sampleMatch: false,
        numericApexOk: false,
      );
    }
    try {
      final Object? decoded = jsonDecode(await File(path).readAsString());
      if (decoded is! Map) {
        return (
          ok: false,
          count: 0,
          path: path,
          sampleMatch: false,
          numericApexOk: false,
        );
      }
      final Object? list = decoded['URLBlocklist'];
      if (list is! List) {
        return (
          ok: false,
          count: 0,
          path: path,
          sampleMatch: false,
          numericApexOk: false,
        );
      }
      final List<String> patterns = list
          .whereType<String>()
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      final int n = patterns.length;
      final String joined = patterns.join('\n').toLowerCase();
      final List<String> numericProbes = expectedPatterns
          .where(NumericSuffixEvasion.isConcreteNumericApexBlocklistPattern)
          .take(12)
          .toList();
      final bool numericApexOk = numericProbes.isEmpty ||
          _numericProbesSatisfied(joined, numericProbes);
      bool sampleMatch = n >= 20;
      if (!sampleMatch && expectedPatterns.isNotEmpty) {
        final int checkN = expectedPatterns.length < 12
            ? expectedPatterns.length
            : 12;
        for (int i = 0; i < checkN; i++) {
          if (joined.contains(expectedPatterns[i].toLowerCase())) {
            sampleMatch = true;
            break;
          }
        }
      }
      if (!sampleMatch && n >= 3) {
        const List<String> sentinels = <String>[
          'mingky01.live',
          'pornhub.com',
          'youtube.com',
        ];
        sampleMatch = sentinels.any(joined.contains);
      }
      return (
        ok: n > 0,
        count: n,
        path: path,
        sampleMatch: sampleMatch,
        numericApexOk: numericApexOk,
      );
    } catch (_) {
      return (
        ok: false,
        count: 0,
        path: path,
        sampleMatch: false,
        numericApexOk: false,
      );
    }
  }

  static bool _numericProbesSatisfied(
    String joinedLower,
    List<String> numericProbes,
  ) {
    if (numericProbes.isEmpty) return true;
    final int matched =
        numericProbes.where((String p) => joinedLower.contains(p.toLowerCase())).length;
    final int need = numericProbes.length <= 4
        ? numericProbes.length
        : (numericProbes.length / 2).ceil();
    return matched >= need;
  }
}
