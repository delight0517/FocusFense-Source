import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart';
import 'extension_guard_prefs.dart';
import 'windows_hidden_process.dart';

/// Finds every `chrome.exe` on the PC, picks the newest, and unifies launchers.
final class ChromeInstallDiscoveryService {
  ChromeInstallDiscoveryService._();
  static final ChromeInstallDiscoveryService instance =
      ChromeInstallDiscoveryService._();

  List<DiscoveredChrome>? _cache;
  DateTime? _cacheAt;
  static const Duration _cacheTtl = Duration(minutes: 10);

  /// All known Chrome install locations (deduped).
  static List<String> candidatePaths() {
    final String pf =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final String pf86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    return <String>[
      p.join(pf, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      p.join(pf86, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      p.join(la, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    ];
  }

  Future<List<DiscoveredChrome>> discover({bool force = false}) async {
    if (!Platform.isWindows) return const <DiscoveredChrome>[];
    final DateTime now = DateTime.now();
    if (!force &&
        _cache != null &&
        _cacheAt != null &&
        now.difference(_cacheAt!) < _cacheTtl) {
      return _cache!;
    }

    final Set<String> paths = <String>{};
    for (final String c in candidatePaths()) {
      if (c.isNotEmpty && await File(c).exists()) paths.add(c);
    }

    // Extra installs under Google\Chrome\Application\<version>\chrome.exe
    for (final String base in <String>[
      p.join(Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
          'Google', 'Chrome', 'Application'),
      p.join(Platform.environment['LOCALAPPDATA'] ?? '',
          'Google', 'Chrome', 'Application'),
    ]) {
      final Directory appDir = Directory(base);
      if (!await appDir.exists()) continue;
      await for (final FileSystemEntity e in appDir.list()) {
        if (e is Directory) {
          final File nested = File(p.join(e.path, 'chrome.exe'));
          if (await nested.exists()) paths.add(nested.path);
        }
      }
    }

    final Map<String, String> versions = await _readVersions(paths.toList());
    final List<DiscoveredChrome> out = <DiscoveredChrome>[];
    for (final String path in paths) {
      out.add(
        DiscoveredChrome(
          exePath: path,
          fileVersion: versions[path],
          isUserInstall: path.contains(r'\AppData\Local\'),
        ),
      );
    }
    out.sort((DiscoveredChrome a, DiscoveredChrome b) => b.compareVersion(a));
    _cache = out;
    _cacheAt = now;
    return out;
  }

  Future<DiscoveredChrome?> canonical({bool force = false}) async {
    final List<DiscoveredChrome> all = await discover(force: force);
    if (all.isEmpty) return null;
    // Prefer newest; tie → user-level install (Win+Search often uses it).
    final DiscoveredChrome newest = all.first;
    final List<DiscoveredChrome> tied = all
        .where((DiscoveredChrome c) => c.versionKey == newest.versionKey)
        .toList();
    if (tied.length > 1) {
      for (final DiscoveredChrome c in tied) {
        if (c.isUserInstall) return c;
      }
    }
    return newest;
  }

  /// Point launchers + shortcuts at the canonical Chrome (newest install).
  Future<ChromeUnifyResult> unifyInstalls({
    String? extensionFolder,
    bool force = false,
  }) async {
    if (!Platform.isWindows) {
      return const ChromeUnifyResult(
        ok: false,
        message: 'Windows 전용',
        installs: <DiscoveredChrome>[],
      );
    }

    final List<DiscoveredChrome> installs = await discover(force: force);
    final DiscoveredChrome? canon = await canonical(force: force);
    if (canon == null) {
      return ChromeUnifyResult(
        ok: false,
        message: 'Chrome이 설치되어 있지 않습니다.',
        installs: installs,
      );
    }

    final List<String> actions = <String>['canonical:${canon.exePath}'];
    if (installs.length > 1) {
      actions.add('multi_chrome:${installs.length}');
      AppLogger.instance.info(
        'chrome_unify: ${installs.length} installs → ${canon.exePath} (${canon.fileVersion})',
      );
    }

    String? folder = extensionFolder;
    if (folder == null || !await File(p.join(folder, 'manifest.json')).exists()) {
      folder = await ExtensionGuardPrefs.instance.chromeSourcePath();
    }
    if (folder != null &&
        await File(p.join(folder, 'manifest.json')).exists()) {
      await ChromeLoadExtensionLauncher.install(extensionFolder: folder);
      actions.add('launchers_refresh');
      await ChromeShortcutHijackService.instance.apply(
        extensionFolder: folder,
        force: true,
      );
      actions.add('shortcut_hijack');
    }

    await _writeHkcuAppPathRedirect();
    actions.add('hkcu_app_paths');

    await _persistCanonical(canon.exePath);

    return ChromeUnifyResult(
      ok: true,
      message: installs.length > 1
          ? 'Chrome ${installs.length}개 감지 → v${canon.fileVersion ?? "?"} 통합'
          : 'Chrome v${canon.fileVersion ?? "?"} 확인',
      canonical: canon,
      installs: installs,
      actions: actions,
    );
  }

  static Future<Map<String, String>> _readVersions(List<String> paths) async {
    if (paths.isEmpty) return <String, String>{};
    final StringBuffer ps = StringBuffer(r'$out = @{}');
    for (final String path in paths) {
      final String q = path.replaceAll("'", "''");
      ps.writeln(
        "if (Test-Path -LiteralPath '$q') { "
        "\$out['$q'] = (Get-Item -LiteralPath '$q').VersionInfo.FileVersion }",
      );
    }
    ps.writeln(r'ConvertTo-Json $out -Compress');
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult r = await windowsRunHidden(
        p.join(windir, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          ps.toString(),
        ],
      );
      final String raw = '${r.stdout}'.trim();
      if (raw.isEmpty) return <String, String>{};
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (Object? k, Object? v) =>
              MapEntry('$k', '$v'),
        );
      }
    } catch (_) {}
    return <String, String>{};
  }

  /// Win+Search may consult HKCU App Paths before Start Menu shortcuts.
  static Future<void> _writeHkcuAppPathRedirect() async {
    final String vbs = ChromeLoadExtensionLauncher.chromeVbsPath;
    if (!await File(vbs).exists()) return;
    final String workDir = ChromeLoadExtensionLauncher.sixVpnDir;
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    const String key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe';
    try {
      await windowsRunHidden(reg, <String>[
        'add',
        key,
        '/ve',
        '/d',
        vbs,
        '/f',
      ]);
      await windowsRunHidden(reg, <String>[
        'add',
        key,
        '/v',
        'Path',
        '/t',
        'REG_SZ',
        '/d',
        workDir,
        '/f',
      ]);
    } catch (e) {
      AppLogger.instance.warn('chrome app paths redirect failed', error: e);
    }
  }

  Future<void> _persistCanonical(String exePath) async {
    try {
      final File f = File(
        p.join(ChromeLoadExtensionLauncher.sixVpnDir, 'chrome_canonical.json'),
      );
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode(<String, Object?>{
          'exe': exePath,
          'at': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {}
  }

  static Future<String?> readPersistedCanonical() async {
    try {
      final File f = File(
        p.join(ChromeLoadExtensionLauncher.sixVpnDir, 'chrome_canonical.json'),
      );
      if (!await f.exists()) return null;
      final Object? d = jsonDecode(await f.readAsString());
      if (d is Map && d['exe'] is String) return d['exe'] as String;
    } catch (_) {}
    return null;
  }
}

final class DiscoveredChrome {
  const DiscoveredChrome({
    required this.exePath,
    this.fileVersion,
    this.isUserInstall = false,
  });

  final String exePath;
  final String? fileVersion;
  final bool isUserInstall;

  String get versionKey => fileVersion ?? exePath;

  int compareVersion(DiscoveredChrome other) {
    final List<int> a = _parseVersion(fileVersion);
    final List<int> b = _parseVersion(other.fileVersion);
    for (int i = 0; i < a.length || i < b.length; i++) {
      final int av = i < a.length ? a[i] : 0;
      final int bv = i < b.length ? b[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  static List<int> _parseVersion(String? v) {
    if (v == null || v.isEmpty) return const <int>[0];
    return v
        .split(RegExp(r'[.,]'))
        .map((String s) => int.tryParse(s.trim()) ?? 0)
        .toList();
  }
}

final class ChromeUnifyResult {
  const ChromeUnifyResult({
    required this.ok,
    required this.message,
    required this.installs,
    this.canonical,
    this.actions = const <String>[],
  });

  final bool ok;
  final String message;
  final DiscoveredChrome? canonical;
  final List<DiscoveredChrome> installs;
  final List<String> actions;
}
