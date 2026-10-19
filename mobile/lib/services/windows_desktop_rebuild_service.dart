import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/windows_rebuild_status.dart';
import 'windows_hidden_process.dart';

const String _kWindowsDevMobileRoot = 'windows_dev_mobile_root';

/// Rebuild script must be a real file (not 0-byte / truncated copy).
const int kMinRebuildScriptBytes = 1500;

/// Saved folder: the Flutter **`mobile`** directory (contains `pubspec.yaml`).
abstract final class WindowsDesktopRebuildPrefs {
  static Future<String?> getMobileRoot() async =>
      (await SharedPreferences.getInstance()).getString(_kWindowsDevMobileRoot);

  static Future<void> setMobileRoot(String? value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? v = value?.trim();
    if (v == null || v.isEmpty) {
      await prefs.remove(_kWindowsDevMobileRoot);
      final String? marker = WindowsDesktopRebuildService.localMarkerPath();
      if (marker != null) {
        try {
          final File f = File(marker);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    } else {
      await prefs.setString(_kWindowsDevMobileRoot, v);
      await WindowsDesktopRebuildService.writeMarker(v);
    }
  }
}

/// In-app trigger for `tools/Rebuild-6VPN-Windows.ps1` (Windows only).
///
/// Discovers `mobile/` via marker file, prefs, exe walk, common paths, and
/// shallow search. Installed `%LOCALAPPDATA%\Programs\...` exe alone cannot
/// compile — a full source tree is required.
abstract final class WindowsDesktopRebuildService {
  static String? localMarkerPath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    return p.join(la, 'SixVPNBlocker', 'rebuild_mobile_root.txt');
  }

  static String? rebuildStatusPath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    return p.join(la, 'SixVPNBlocker', 'rebuild_status.json');
  }

  /// Path of the rolling console log captured by `Start-Transcript` inside
  /// the rebuild script. The monitor tails this so the in-app overlay can
  /// show live build progress (otherwise the UI is stuck on the initial
  /// "starting" message until the script writes its next status JSON).
  static String? rebuildConsoleLogPath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    final String pointer = p.join(la, 'SixVPNBlocker', 'rebuild_console_active.txt');
    try {
      final File pf = File(pointer);
      if (pf.existsSync()) {
        final String t = pf.readAsStringSync().trim();
        if (t.isNotEmpty && File(t).existsSync()) return t;
      }
    } catch (_) {}
    return p.join(la, 'SixVPNBlocker', 'rebuild_console.log');
  }

  /// Reads the last [maxLines] non-empty lines from the rebuild console log.
  /// Stripped of `**********` Start-Transcript banner lines so the UI shows
  /// real build output, not transcript decoration.
  static Future<List<String>> readConsoleLogTail({int maxLines = 28}) async {
    final String? path = rebuildConsoleLogPath();
    if (path == null) return const <String>[];
    try {
      final File f = File(path);
      if (!await f.exists()) return const <String>[];
      // Read at most the tail 256KB — long `flutter build` output.
      final int len = await f.length();
      final int from = len > 256 * 1024 ? len - 256 * 1024 : 0;
      final RandomAccessFile raf = await f.open();
      try {
        await raf.setPosition(from);
        final List<int> bytes = await raf.read(len - from);
        final String text = String.fromCharCodes(bytes);
        final List<String> all = text
            .split(RegExp(r'\r?\n'))
            .where((String s) {
              final String t = s.trim();
              if (t.isEmpty) return false;
              // Skip Start-Transcript decoration so the tail is real output.
              if (t.startsWith('**********')) return false;
              if (t.startsWith('Windows PowerShell transcript')) return false;
              if (t.startsWith('Start time:')) return false;
              if (t.startsWith('Username:')) return false;
              if (t.startsWith('RunAs User:')) return false;
              if (t.startsWith('Configuration Name:')) return false;
              if (t.startsWith('Machine:')) return false;
              if (t.startsWith('Host Application:')) return false;
              if (t.startsWith('Process ID:')) return false;
              if (t.startsWith('PSVersion:')) return false;
              if (t.startsWith('PSEdition:')) return false;
              if (t.startsWith('PSCompatibleVersions:')) return false;
              if (t.startsWith('BuildVersion:')) return false;
              if (t.startsWith('CLRVersion:')) return false;
              if (t.startsWith('WSManStackVersion:')) return false;
              if (t.startsWith('PSRemotingProtocolVersion:')) return false;
              if (t.startsWith('SerializationVersion:')) return false;
              if (t.startsWith('PSHostVersion:')) return false;
              if (t.startsWith('Transcript started')) return false;
              if (t.startsWith('Transcript stopped')) return false;
              return true;
            })
            .toList();
        if (all.length <= maxLines) return all;
        return all.sublist(all.length - maxLines);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return const <String>[];
    }
  }

  static String? _externalLauncherLogPath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    return p.join(la, 'SixVPNBlocker', 'external_launcher.log');
  }

  /// Short tail from [Start-External-6VPN-Rebuild.ps1] (proves external spawn).
  static Future<List<String>> readExternalLauncherLogTail({int maxLines = 6}) async {
    final String? path = _externalLauncherLogPath();
    if (path == null) return const <String>[];
    try {
      final File f = File(path);
      if (!await f.exists()) return const <String>[];
      final String text = await f.readAsString();
      final List<String> lines = text
          .split(RegExp(r'\r?\n'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      if (lines.length <= maxLines) return lines;
      return lines.sublist(lines.length - maxLines);
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<int?> readExternalRebuildPid() async {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la == null) return null;
    try {
      final File f = File(p.join(la, 'SixVPNBlocker', 'rebuild_external.pid'));
      if (!await f.exists()) return null;
      return int.tryParse((await f.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  /// Best-effort liveness check for the external rebuild process. Used by the
  /// in-app updater self-heal watchdog: if output stalls AND this PID is gone,
  /// the build truly died (AV-killed PowerShell, crash) and the overlay can
  /// recover instead of hanging. Any failure returns `true` (assume alive) so
  /// a flaky check never aborts a real build.
  static Future<bool> isProcessAlive(int pid) async {
    if (!Platform.isWindows || pid <= 0) return true;
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult r = await windowsRunHidden(
        p.join(windir, 'System32', 'tasklist.exe'),
        <String>['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
      );
      final String out = '${r.stdout}'.trim();
      // tasklist prints the row only when the PID exists; otherwise it emits
      // "INFO: No tasks are running...". Match the PID inside the CSV row.
      return out.contains('"$pid"') || out.contains(',$pid,');
    } catch (_) {
      return true;
    }
  }

  /// Written before spawning PowerShell so the overlay never sits on a blank
  /// status file when AV blocks the child process.
  static Future<void> writeLauncherStatus({
    required String message,
    double progress = 0.03,
    bool requestAppExit = false,
    String phase = 'starting',
  }) async {
    final String? path = rebuildStatusPath();
    if (path == null) return;
    try {
      final Directory dir = Directory(p.dirname(path));
      if (!await dir.exists()) await dir.create(recursive: true);
      final Map<String, Object?> obj = <String, Object?>{
        'phase': phase,
        'message': message,
        'progress': progress,
        'requestAppExit': requestAppExit,
        'exitCode': -999,
        'exePath': '',
        'updatedAt': DateTime.now().toIso8601String(),
      };
      final String json = jsonEncode(obj);
      final File f = File(path);
      await f.writeAsBytes(
        utf8.encode(json),
        flush: true,
        mode: FileMode.writeOnly,
      );
    } catch (_) {/* best-effort */}
  }

  static Future<void> clearRebuildStatus() async {
    final String? path = rebuildStatusPath();
    if (path == null) return;
    try {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static String? _externalPidPath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    return p.join(la, 'SixVPNBlocker', 'rebuild_external.pid');
  }

  static String? _rebuildSessionPath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return null;
    return p.join(la, 'SixVPNBlocker', 'rebuild_session.json');
  }

  /// Clears stale PID/status/log tail so a new in-app rebuild cannot inherit
  /// the previous run's "Rebuild complete" line and instantly `exit(0)` the UI.
  static Future<DateTime> prepareNewInAppRebuildSession() async {
    final DateTime startedAt = DateTime.now();
    await clearRebuildStatus();
    await clearExternalRebuildPid();

    final String? sessionPath = _rebuildSessionPath();
    if (sessionPath != null) {
      try {
        final Directory dir = Directory(p.dirname(sessionPath));
        if (!await dir.exists()) await dir.create(recursive: true);
        await File(sessionPath).writeAsString(
          jsonEncode(<String, Object?>{
            'startedAt': startedAt.toIso8601String(),
            'source': 'in_app',
          }),
          flush: true,
        );
      } catch (_) {/* best-effort */}
    }

    // Do NOT write rebuild_console.log here — the external script owns that
    // file. Pre-truncating while the monitor tails it caused delete/append
    // races and hid the real build log behind a frozen session header.

    return startedAt;
  }

  static Future<void> clearExternalRebuildPid() async {
    final String? path = _externalPidPath();
    if (path == null) return;
    try {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<void> clearRebuildSession() async {
    final String? path = _rebuildSessionPath();
    if (path == null) return;
    try {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Clears stale PID/status/session when the external builder is gone but the
  /// console log already shows a successful rebuild (common after relaunch).
  static Future<void> clearStaleRebuildArtifactsIfComplete() async {
    final List<String> tail = await readConsoleLogTail(maxLines: 50);
    if (!consoleTailIndicatesSuccess(tail)) return;
    final int? pid = await readExternalRebuildPid();
    if (pid != null && await isProcessAlive(pid)) return;
    await clearRebuildStatus();
    await clearExternalRebuildPid();
    await clearRebuildSession();
  }

  /// Drops [rebuild_external.lock] when its PID is gone so the next in-app
  /// rebuild is not refused after a crashed hidden PowerShell.
  static Future<void> clearStaleExternalRebuildLock() async {
    if (!Platform.isWindows) return;
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la == null || la.isEmpty) return;
    final String lockPath = p.join(la, 'SixVPNBlocker', 'rebuild_external.lock');
    try {
      final File lock = File(lockPath);
      if (!await lock.exists()) return;
      final String raw = (await lock.readAsString()).trim();
      final int? pid = int.tryParse(raw);
      if (pid == null) {
        await lock.delete();
        return;
      }
      if (!await isProcessAlive(pid)) {
        await lock.delete();
      }
    } catch (_) {/* best-effort */}
  }

  static Future<DateTime?> readRebuildSessionStartedAt() async {
    final String? path = _rebuildSessionPath();
    if (path == null) return null;
    try {
      final File f = File(path);
      if (!await f.exists()) return null;
      final Object? decoded = jsonDecode(stripJsonBom(await f.readAsString()));
      if (decoded is! Map<String, dynamic>) return null;
      final String? raw = decoded['startedAt'] as String?;
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// True when [status] was written after this in-app session began.
  static bool statusBelongsToSession(
    WindowsRebuildStatus? status,
    DateTime? sessionStartedAt,
  ) {
    if (status == null || sessionStartedAt == null) return true;
    final String? at = status.updatedAt;
    if (at == null || at.isEmpty) return true;
    try {
      final DateTime t = DateTime.parse(at);
      return !t.isBefore(sessionStartedAt.subtract(const Duration(seconds: 3)));
    } catch (_) {
      return true;
    }
  }

  /// Console completion is only valid once this session's boot marker appears.
  static bool consoleTailIndicatesSuccessForSession(
    List<String> tail, {
    required DateTime? sessionStartedAt,
  }) {
    if (tail.isEmpty || sessionStartedAt == null) return false;
    if (!_tailBelongsToSession(tail, sessionStartedAt)) return false;
    return consoleTailIndicatesSuccess(tail);
  }

  static bool consoleTailIndicatesFailureForSession(
    List<String> tail, {
    required DateTime? sessionStartedAt,
  }) {
    if (tail.isEmpty || sessionStartedAt == null) return false;
    if (!_tailBelongsToSession(tail, sessionStartedAt)) return false;
    return consoleTailIndicatesFailure(tail);
  }

  static bool _tailBelongsToSession(List<String> tail, DateTime sessionStartedAt) {
    for (final String line in tail) {
      if (line.contains('in-app rebuild session') ||
          line.contains('Rebuild-6VPN-Windows.ps1 started') ||
          line.contains('=== 6 VPN Blocker rebuild v')) {
        return true;
      }
    }
    // Fallback: any line timestamped after session start in the ISO header.
    final String iso = sessionStartedAt.toIso8601String();
    final String shortIso = iso.substring(0, 19);
    return tail.any(
      (String line) => line.contains(iso) || line.contains(shortIso),
    );
  }

  /// Strips UTF-8 BOM PowerShell 5.1 `Set-Content -Encoding UTF8` may add.
  static String stripJsonBom(String raw) {
    if (raw.isEmpty) return raw;
    if (raw.codeUnitAt(0) == 0xFEFF) return raw.substring(1);
    if (raw.startsWith('\uFEFF')) return raw.substring(1);
    return raw;
  }

  /// Fallback when [readRebuildStatus] fails — infer coarse phase from the
  /// tailed console log so progress/message are not frozen for minutes.
  static WindowsRebuildStatus? inferStatusFromConsoleTail(List<String> tail) {
    if (tail.isEmpty) return null;
    final String blob = tail.join('\n').toLowerCase();

    if (blob.contains('rebuild complete') &&
        (blob.contains('exit 0') || blob.contains('all post-build'))) {
      return const WindowsRebuildStatus(
        phase: 'done',
        message: '업데이트 완료',
        progress: 1,
        exitCode: 0,
      );
    }
    if (blob.contains('rebuild failed')) {
      return const WindowsRebuildStatus(
        phase: 'failed',
        message: '빌드/설치 실패 — 로그를 확인하세요.',
        progress: 0,
        exitCode: 1,
      );
    }
    if (blob.contains('relaunch ok') ||
        blob.contains('relaunching app:')) {
      return const WindowsRebuildStatus(
        phase: 'relaunching',
        message: '⑥ 새 창 열기 — 방금 설치한 exe 실행 (약 2~5초)',
        progress: 0.96,
      );
    }
    if (blob.contains('[step] build ok') ||
        blob.contains('install/copy phase') ||
        blob.contains('copying release to per-user install')) {
      return const WindowsRebuildStatus(
        phase: 'installing',
        message: '⑤ 설치 — 새 exe 복사 (약 10~20초)',
        progress: 0.85,
      );
    }
    if (blob.contains('flutter build windows') ||
        blob.contains('building windows application')) {
      return const WindowsRebuildStatus(
        phase: 'building',
        message: '④ 빌드 — flutter build windows (약 2~4분)',
        progress: 0.55,
      );
    }
    if (blob.contains('flutter pub get') ||
        blob.contains('got dependencies')) {
      return const WindowsRebuildStatus(
        phase: 'pub_get',
        message: '② 패키지 — flutter pub get (약 30초~1분)',
        progress: 0.22,
      );
    }
    return null;
  }

  static bool consoleTailIndicatesSuccess(List<String> tail) {
    if (tail.isEmpty) return false;
    final String blob = tail.join('\n');
    return blob.contains('Rebuild complete') &&
        (blob.contains('exit 0') || blob.contains('all post-build steps finished'));
  }

  static bool consoleTailIndicatesFailure(List<String> tail) {
    if (tail.isEmpty) return false;
    return tail.join('\n').contains('Rebuild FAILED');
  }

  static Future<WindowsRebuildStatus?> readRebuildStatus() async {
    final String? path = rebuildStatusPath();
    if (path == null) return null;
    try {
      final File f = File(path);
      if (!await f.exists()) return null;
      final String raw = stripJsonBom(await f.readAsString());
      if (raw.trim().isEmpty) return null;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return WindowsRebuildStatus.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isValidMobileRoot(String root) async {
    final String r = root.trim();
    if (r.isEmpty) return false;
    final File pub = File(p.join(r, 'pubspec.yaml'));
    if (!await pub.exists()) return false;
    final File script = File(p.join(r, 'tools', 'Rebuild-6VPN-Windows.ps1'));
    if (!await script.exists()) return false;
    try {
      final int len = await script.length();
      if (len < kMinRebuildScriptBytes) return false;
    } catch (_) {
      return false;
    }
    return true;
  }

  static Future<void> writeMarker(String mobileRoot) async {
    if (!Platform.isWindows) return;
    final String r = mobileRoot.trim();
    if (!await isValidMobileRoot(r)) return;
    final String? path = localMarkerPath();
    if (path == null) return;
    try {
      final Directory dir = Directory(p.dirname(path));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await File(path).writeAsString(r, flush: true);
    } catch (_) {/* best-effort */}
  }

  static Future<String?> readMarker() async {
    final String? path = localMarkerPath();
    if (path == null) return null;
    try {
      final File f = File(path);
      if (!await f.exists()) return null;
      final String t = (await f.readAsString()).trim();
      if (t.isEmpty) return null;
      if (await isValidMobileRoot(t)) return t;
      try {
        await f.delete();
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  /// Walks up from [Platform.resolvedExecutable] looking for `mobile/`.
  static Future<String?> tryInferMobileRoot() async {
    if (!Platform.isWindows) return null;
    Directory d = Directory(p.dirname(Platform.resolvedExecutable));
    for (int i = 0; i < 16; i++) {
      if (await isValidMobileRoot(d.path)) return d.path;
      final Directory parent = d.parent;
      if (parent.path == d.path) break;
      d = parent;
    }
    return null;
  }

  static Future<String?> _fromEnv() async {
    final String? v = Platform.environment['SIXVPN_MOBILE_ROOT']?.trim();
    if (v == null || v.isEmpty) return null;
    if (await isValidMobileRoot(v)) return v;
    return null;
  }

  static Future<String?> _commonLayouts() async {
    final String? user = Platform.environment['USERPROFILE'];
    if (user == null || user.isEmpty) return null;
    final List<String> candidates = <String>[
      p.join(user, 'Desktop', 'app dev', '6VPN_Image_Blocker', 'mobile'),
      p.join(user, 'Desktop', '6VPN_Image_Blocker', 'mobile'),
      p.join(user, 'Documents', '6VPN_Image_Blocker', 'mobile'),
      p.join(user, 'source', 'repos', '6VPN_Image_Blocker', 'mobile'),
    ];
    final Directory appDev = Directory(p.join(user, 'Desktop', 'app dev'));
    if (await appDev.exists()) {
      try {
        await for (final FileSystemEntity e in appDev.list(followLinks: false)) {
          if (e is Directory) {
            candidates.add(p.join(e.path, 'mobile'));
          }
        }
      } catch (_) {}
    }
    final Directory desk = Directory(p.join(user, 'Desktop'));
    if (await desk.exists()) {
      try {
        await for (final FileSystemEntity e in desk.list(followLinks: false)) {
          if (e is! Directory) continue;
          final String name = p.basename(e.path).toLowerCase();
          if (name.contains('vpn') || name.contains('blocker')) {
            candidates.add(p.join(e.path, 'mobile'));
          }
        }
      } catch (_) {}
    }
    for (final String c in candidates) {
      if (await isValidMobileRoot(c)) return c;
    }
    return null;
  }

  /// Shallow search for `tools/Rebuild-6VPN-Windows.ps1` under Desktop/Documents.
  static Future<String?> _shallowScriptSearch({int maxDepth = 5}) async {
    final String? user = Platform.environment['USERPROFILE'];
    if (user == null) return null;
    final List<String> roots = <String>[
      p.join(user, 'Desktop'),
      p.join(user, 'Documents'),
    ];
    const String scriptName = 'Rebuild-6VPN-Windows.ps1';

    Future<String?> walk(Directory dir, int depth) async {
      if (depth > maxDepth) return null;
      try {
        await for (final FileSystemEntity e in dir.list(followLinks: false)) {
          if (e is File && p.basename(e.path) == scriptName) {
            final String toolsDir = p.dirname(e.path);
            if (p.basename(toolsDir).toLowerCase() != 'tools') continue;
            final String mobile = p.dirname(toolsDir);
            if (await isValidMobileRoot(mobile)) return mobile;
          }
          if (e is Directory) {
            final String? found = await walk(e, depth + 1);
            if (found != null) return found;
          }
        }
      } catch (_) {}
      return null;
    }

    for (final String root in roots) {
      final Directory d = Directory(root);
      if (!await d.exists()) continue;
      final String? found = await walk(d, 0);
      if (found != null) return found;
    }
    return null;
  }

  /// Tries every strategy; optionally writes marker + prefs when found.
  static Future<String?> discoverMobileRoot({bool persist = true}) async {
    if (!Platform.isWindows) return null;

    final String? env = await _fromEnv();
    if (env != null) {
      if (persist) await _persistFound(env);
      return env;
    }

    final String? marker = await readMarker();
    if (marker != null) {
      if (persist) await _persistFound(marker);
      return marker;
    }

    final String? saved = await WindowsDesktopRebuildPrefs.getMobileRoot();
    if (saved != null && saved.isNotEmpty && await isValidMobileRoot(saved)) {
      if (persist) await _persistFound(saved);
      return saved;
    }
    if (saved != null && saved.isNotEmpty) {
      await WindowsDesktopRebuildPrefs.setMobileRoot(null);
    }

    final String? inferred = await tryInferMobileRoot();
    if (inferred != null) {
      if (persist) await _persistFound(inferred);
      return inferred;
    }

    final String? common = await _commonLayouts();
    if (common != null) {
      if (persist) await _persistFound(common);
      return common;
    }

    final String? shallow = await _shallowScriptSearch();
    if (shallow != null) {
      if (persist) await _persistFound(shallow);
      return shallow;
    }

    return null;
  }

  static Future<void> _persistFound(String root) async {
    await writeMarker(root);
    final String? saved = await WindowsDesktopRebuildPrefs.getMobileRoot();
    if (saved == null || saved.isEmpty || saved != root) {
      await WindowsDesktopRebuildPrefs.setMobileRoot(root);
    }
  }

  static Future<String?> effectiveMobileRoot() async {
    return discoverMobileRoot(persist: true);
  }

  /// Parses `mobile/pubspec.yaml` and returns `version: 1.0.0+61` as
  /// `(version: "1.0.0", buildNumber: "61")`. Used by the top-bar update
  /// banner to compare the running build with the most recent source.
  ///
  /// Returns `null` when no source is discoverable or the file is malformed.
  /// We do NOT depend on the `yaml` package — this regex is enough for the
  /// pubspec line and avoids pulling in transitive dependencies.
  static Future<SourceVersion?> readSourceVersion() async {
    final String? root = await discoverMobileRoot(persist: false);
    if (root == null) return null;
    try {
      final File pubspec = File(p.join(root, 'pubspec.yaml'));
      if (!await pubspec.exists()) return null;
      final String text = await pubspec.readAsString();
      final RegExp re = RegExp(r'^\s*version\s*:\s*([^\s#]+)', multiLine: true);
      final RegExpMatch? m = re.firstMatch(text);
      if (m == null) return null;
      final String raw = m.group(1)!.trim();
      final int plus = raw.indexOf('+');
      final String version = plus < 0 ? raw : raw.substring(0, plus);
      final String build = plus < 0 ? '' : raw.substring(plus + 1);
      return SourceVersion(
        version: version,
        buildNumber: build,
        mobileRoot: root,
      );
    } catch (_) {
      return null;
    }
  }

  /// Human-readable status for Settings UI.
  static Future<RebuildRootStatus> status() async {
    final String? root = await discoverMobileRoot(persist: false);
    if (root == null) {
      return const RebuildRootStatus(
        found: false,
        message: '소스 폴더를 찾지 못했습니다. 아래에서 mobile 경로를 지정하거나 터미널 가이드를 사용하세요.',
      );
    }
    final File script = File(p.join(root, 'tools', 'Rebuild-6VPN-Windows.ps1'));
    final int bytes = await script.length();
    return RebuildRootStatus(
      found: true,
      mobileRoot: root,
      rebuildScriptBytes: bytes,
      message: '자동 탐지됨 · Rebuild 스크립트 ${(bytes / 1024).toStringAsFixed(1)} KB',
    );
  }

  /// True when the **external** rebuild process has produced independent
  /// evidence it actually started — never trusts `rebuild_status.json`'s
  /// progress/message, because [launchRebuildPipeline] itself writes that
  /// file (progress 0.06) right before this check runs. That made the old
  /// version of this function always return `true` immediately even when
  /// `CreateProcess` succeeded but the spawned PowerShell was killed by
  /// security software before running a single line — the UI then sat on
  /// "빌드 출력을 기다리는 중" for the full 90s self-heal stall timeout with
  /// no early warning. Only signals a separate process could have written
  /// count here: `external_launcher.log` (first line written by
  /// `Start-External-6VPN-Rebuild.ps1` itself), the rebuild console log
  /// growing/showing its boot marker, or a recorded external PID that's
  /// actually alive.
  static Future<bool> verifyRebuildPipelineStarted({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final List<String> launcherTail = await readExternalLauncherLogTail();
      if (launcherTail.isNotEmpty) return true;

      final List<String> tail = await readConsoleLogTail(maxLines: 12);
      if (tail.any(
        (String line) =>
            line.contains('Rebuild-6VPN-Windows.ps1 started') ||
            line.contains('=== 6 VPN Blocker rebuild v'),
      )) {
        return true;
      }
      final String? logPath = rebuildConsoleLogPath();
      if (logPath != null) {
        try {
          final File f = File(logPath);
          if (await f.exists() && await f.length() > 120) return true;
        } catch (_) {}
      }
      final int? pid = await readExternalRebuildPid();
      if (pid != null && await isProcessAlive(pid)) return true;

      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  static String _psExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  /// Starts rebuild in a **separate external PowerShell** (not a child of the
  /// Flutter process). The app only tails log files — never blocks on build.
  ///
  /// [visible] spawns a normal (non-hidden, non-detached) console window
  /// instead of the usual `CREATE_NO_WINDOW`+`DETACHED_PROCESS` combo. Use
  /// this as a one-time fallback retry when [verifyRebuildPipelineStarted]
  /// reports the hidden attempt never produced any evidence of running —
  /// some security software specifically flags "hidden, detached PowerShell
  /// spawned by another app" as suspicious and kills it before it executes a
  /// single line, with nothing logged anywhere to explain why. A visible
  /// window is one build action the user explicitly asked for, not a
  /// background probe, so a brief console flash here is an acceptable
  /// trade-off for actually completing the build.
  static Future<String> launchRebuildPipeline(
    String mobileRoot, {
    bool fromApp = false,
    bool visible = false,
  }) async {
    if (!await isValidMobileRoot(mobileRoot)) {
      final String? rediscovered = await discoverMobileRoot(persist: true);
      if (rediscovered == null) {
        throw StateError(
          '유효한 mobile 소스가 없습니다. pubspec.yaml 과 '
          'tools\\Rebuild-6VPN-Windows.ps1 ($kMinRebuildScriptBytes바이트 이상)이 필요합니다.',
        );
      }
      mobileRoot = rediscovered;
    }

    final String starter = p.join(
      mobileRoot,
      'tools',
      'Start-External-6VPN-Rebuild.ps1',
    );
    if (!await File(starter).exists()) {
      throw StateError(
        '외부 빌드 스크립트가 없습니다: tools\\Start-External-6VPN-Rebuild.ps1',
      );
    }

    await writeMarker(mobileRoot);
    await clearStaleExternalRebuildLock();
    if (fromApp) {
      await writeLauncherStatus(
        message: visible
            ? '외부 PowerShell 빌드 재시도 중… (창이 잠깐 보일 수 있어요)'
            : '외부 PowerShell 빌드 시작 중… (앱 안에서는 로그만 표시)',
        progress: 0.04,
      );
    }

    // Launch Start-External directly — avoids fragile VBS quoting and
    // guarantees paths with spaces stay one argument. Hidden by default
    // (CREATE_NO_WINDOW); the [visible] fallback drops -WindowStyle Hidden
    // and uses a plain Process.start so a real console window appears.
    final List<String> args = <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      if (!visible) ...<String>['-WindowStyle', 'Hidden'],
      '-File',
      starter,
      '-MobileRoot',
      mobileRoot,
    ];
    if (fromApp) args.add('-FromApp');

    if (visible) {
      await Process.start(
        _psExe(),
        args,
        workingDirectory: mobileRoot,
        mode: ProcessStartMode.detached,
      );
    } else {
      await windowsStartDetachedHidden(
        _psExe(),
        args,
        workingDirectory: mobileRoot,
      );
    }

    if (fromApp) {
      await writeLauncherStatus(
        message: '외부 빌드 시작 — 아래 로그가 갱신됩니다. 패키지·빌드가 끝날 때까지 앱을 유지합니다.',
        progress: 0.06,
      );
    }

    return 'external';
  }
}

final class RebuildRootStatus {
  const RebuildRootStatus({
    required this.found,
    required this.message,
    this.mobileRoot,
    this.rebuildScriptBytes,
  });

  final bool found;
  final String message;
  final String? mobileRoot;
  final int? rebuildScriptBytes;
}

/// Version read out of `mobile/pubspec.yaml` (the build target if the user
/// triggers a rebuild now).
final class SourceVersion {
  const SourceVersion({
    required this.version,
    required this.buildNumber,
    required this.mobileRoot,
  });

  final String version;
  final String buildNumber;
  final String mobileRoot;

  /// `1.0.0+61` style label.
  String get display =>
      buildNumber.isEmpty ? version : '$version+$buildNumber';

  /// Compare against the running app's identity. Returns `true` when the
  /// running build is the **same** as the source (no update available).
  /// Build number takes precedence — that's what we bump.
  bool matchesRunning({required String runningVersion, required String runningBuildNumber}) {
    if (buildNumber.isNotEmpty && runningBuildNumber.isNotEmpty) {
      return buildNumber.trim() == runningBuildNumber.trim();
    }
    return version.trim() == runningVersion.trim();
  }
}
