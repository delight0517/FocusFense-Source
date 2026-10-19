import 'dart:io';

import 'package:path/path.dart' as p;

import 'autostart_result.dart';

/// Mac-only "always on" autostart service.
///
/// Installs a user LaunchAgent (`~/Library/LaunchAgents/...plist`) so that the
/// app:
///   * runs at user login (`RunAtLoad`),
///   * is automatically relaunched if the user (or anyone) force-quits it,
///     because `KeepAlive` is enabled.
///
/// User LaunchAgents do NOT need admin password — they live in the user's
/// own ~/Library, and `launchctl` runs as the user.
///
/// Honest limits:
///   * macOS will still allow the user to disable the agent with
///     `launchctl bootout` from Terminal. We make it harder via the app's
///     own PIN lock (disable button greyed-out while locked), but Apple does
///     not let a third-party app block process termination.
///   * Updating the app binary path — if the user moves the .app, the agent
///     keeps pointing at the old location. The "Install / Reinstall" action
///     always re-writes with the current path.
final class MacAutostartService {
  MacAutostartService._();
  static final MacAutostartService instance = MacAutostartService._();

  static const String kLabel = 'com.sixcleanroom.sixCleanRoom.autostart';

  bool get isSupported => Platform.isMacOS;

  String get _plistPath {
    final String home = Platform.environment['HOME'] ?? '';
    return p.join(home, 'Library', 'LaunchAgents', '$kLabel.plist');
  }

  Future<String?> _resolveAppExecutablePath() async {
    // Use the bundle .app's main executable, not the dylib next to it.
    final String script = Platform.script.toFilePath();
    Directory current = Directory(script).parent;
    for (int i = 0; i < 8 && current.parent.path != current.path; i++) {
      if (current.path.endsWith('.app')) {
        final String exe = p.join(current.path, 'Contents', 'MacOS', '6 VPN Blocker');
        if (await File(exe).exists()) return exe;
        // fallback: any binary in MacOS/
        final Directory macos = Directory(p.join(current.path, 'Contents', 'MacOS'));
        if (await macos.exists()) {
          final List<FileSystemEntity> items = await macos.list().toList();
          for (final FileSystemEntity e in items) {
            if (e is File) return e.path;
          }
        }
      }
      current = current.parent;
    }
    return null;
  }

  Future<bool> isInstalled() async {
    if (!isSupported) return false;
    return File(_plistPath).existsSync();
  }

  Future<AutostartResult> install({bool keepAlive = true}) async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'macOS only');
    }
    final String? exe = await _resolveAppExecutablePath();
    if (exe == null) {
      return const AutostartResult(
          ok: false, message: '실행 파일 경로를 찾을 수 없습니다.');
    }
    final File plist = File(_plistPath);
    await plist.parent.create(recursive: true);
    final String body = _renderPlist(exe, keepAlive: keepAlive);
    await plist.writeAsString(body);

    // Re-load: bootout first (ignore failure), then bootstrap.
    final String uid = await _getUid();
    await Process.run('launchctl', <String>['bootout', 'gui/$uid/$kLabel']);
    final ProcessResult res = await Process.run(
      'launchctl',
      <String>['bootstrap', 'gui/$uid', plist.path],
    );
    if (res.exitCode != 0) {
      // Fallback to older syntax (still works on older macOS).
      final ProcessResult load = await Process.run('launchctl', <String>['load', plist.path]);
      if (load.exitCode != 0) {
        return AutostartResult(
            ok: false,
            message:
                '플리스트는 저장됐지만 launchctl 로드 실패: ${res.stderr ?? load.stderr}');
      }
    }
    return const AutostartResult(
        ok: true, message: '자동 시작 + 자동 재실행 활성');
  }

  Future<AutostartResult> uninstall() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'macOS only');
    }
    final String uid = await _getUid();
    await Process.run('launchctl', <String>['bootout', 'gui/$uid/$kLabel']);
    await Process.run('launchctl', <String>['unload', _plistPath]);
    final File f = File(_plistPath);
    if (await f.exists()) {
      await f.delete();
    }
    return const AutostartResult(ok: true, message: '자동 시작 해제됨');
  }

  Future<String> _getUid() async {
    final ProcessResult res = await Process.run('id', <String>['-u']);
    return (res.stdout?.toString() ?? '501').trim();
  }

  String _renderPlist(String exePath, {required bool keepAlive}) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$kLabel</string>
  <key>ProgramArguments</key>
  <array>
    <string>${_escape(exePath)}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <${keepAlive ? "true" : "false"}/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>${_escape(_logPath('out'))}</string>
  <key>StandardErrorPath</key>
  <string>${_escape(_logPath('err'))}</string>
</dict>
</plist>
''';
  }

  String _logPath(String suffix) {
    final String home = Platform.environment['HOME'] ?? '';
    return p.join(home, 'Library', 'Logs', '6VPNBlocker_autostart_$suffix.log');
  }

  String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
