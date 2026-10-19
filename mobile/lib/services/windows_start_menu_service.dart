import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_desktop_rebuild_service.dart';
import 'windows_hidden_process.dart';

/// Focus Fense Start Menu shortcuts; stable alias preserves existing Windows integrations.
abstract final class WindowsStartMenuService {
  static const String kSearchExeName = 'FocusFense.exe';
  static const String kInstallSubdir = 'FocusFense';

  static String get _programsDir {
    final String appData = Platform.environment['APPDATA'] ?? '';
    return p.join(appData, 'Microsoft', 'Windows', 'Start Menu', 'Programs');
  }

  static String get _installDir {
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(la, 'Programs', kInstallSubdir);
  }

  static String get installIconPath => p.join(_installDir, 'app_icon.ico');

  /// Copy branded .ico next to exe so shortcuts/taskbar can reference it.
  static Future<void> ensureInstallIcon() async {
    if (!Platform.isWindows) return;
    if (await File(installIconPath).exists()) return;
    final String? mobileRoot =
        await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
    if (mobileRoot == null) return;
    final List<String> sources = <String>[
      p.join(mobileRoot, 'windows', 'runner', 'resources', 'app_icon.ico'),
      p.join(mobileRoot, 'assets', 'app_icon.ico'),
    ];
    for (final String src in sources) {
      final File f = File(src);
      if (await f.exists()) {
        await Directory(_installDir).create(recursive: true);
        await f.copy(installIconPath);
        return;
      }
    }
  }

  static Future<String> _resolveIconLocation(String exe) async {
    final File ico = File(installIconPath);
    if (await ico.exists()) return ico.path;
    return '$exe,0';
  }

  /// Prefer searchable exe alias; fall back to Flutter runner name.
  static Future<String?> resolveLaunchExe() async {
    if (!Platform.isWindows) return null;
    final String alias = p.join(_installDir, kSearchExeName);
    if (await File(alias).exists()) return alias;
    final String primary = p.join(_installDir, 'FocusFense.exe');
    if (await File(primary).exists()) return primary;
    final String running = Platform.resolvedExecutable;
    if (running.toLowerCase().endsWith('.exe') && await File(running).exists()) {
      return running;
    }
    return null;
  }

  /// The branded executable is the only app launcher in the install folder.
  static Future<bool> ensureSearchExeAlias() async {
    if (!Platform.isWindows) return false;
    return File(p.join(_installDir, 'FocusFense.exe')).exists();
  }

  /// Idempotent: multiple `.lnk` names + subfolder for Start / Win+Search.
  static Future<StartMenuInstallResult> ensureSearchShortcuts() async {
    if (!Platform.isWindows) {
      return const StartMenuInstallResult(ok: false, message: 'Windows only');
    }
    await ensureSearchExeAlias();
    await ensureInstallIcon();
    final String? exe = await resolveLaunchExe();
    if (exe == null) {
      return const StartMenuInstallResult(
        ok: false,
        message: '실행 파일을 찾지 못했습니다.',
      );
    }
    final String workDir = p.dirname(exe);
    final String iconLoc = await _resolveIconLocation(exe);
    final String folder = p.join(_programsDir, 'Focus Fense');
    await Directory(folder).create(recursive: true);

    final List<String> targets = <String>[
      p.join(_programsDir, 'Focus Fense.lnk'),
      p.join(_programsDir, 'Focus Fense (Windows).lnk'),
      p.join(folder, 'Focus Fense.lnk'),
    ];

    int created = 0;
    for (final String lnk in targets) {
      if (await _createShortcut(
        lnkPath: lnk,
        exe: exe,
        workDir: workDir,
        iconLocation: iconLoc,
        description: 'Focus Fense — 차단 및 스케줄 관리',
      )) {
        created++;
      }
    }

    return StartMenuInstallResult(
      ok: created > 0,
      message: created > 0
          ? '시작 메뉴 바로가기 $created개 (검색: Focus Fense)'
          : '시작 메뉴 바로가기 생성 실패',
      shortcutCount: created,
      exePath: exe,
    );
  }

  static Future<bool> _createShortcut({
    required String lnkPath,
    required String exe,
    required String workDir,
    required String iconLocation,
    required String description,
  }) async {
    try {
      final Directory parent = Directory(p.dirname(lnkPath));
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      String psq(String s) => s.replaceAll("'", "''");
      final String cmd =
          "\$ws = New-Object -ComObject WScript.Shell; "
          "\$s = \$ws.CreateShortcut('${psq(lnkPath)}'); "
          "\$s.TargetPath = '${psq(exe)}'; "
          "\$s.WorkingDirectory = '${psq(workDir)}'; "
          "\$s.IconLocation = '${psq(iconLocation)}'; "
          "\$s.Description = '${psq(description)}'; "
          '\$s.WindowStyle = 1; '
          '\$s.Save()';
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult res = await windowsRunHidden(
        p.join(windir, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-Command',
          cmd,
        ],
      );
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

final class StartMenuInstallResult {
  const StartMenuInstallResult({
    required this.ok,
    required this.message,
    this.shortcutCount = 0,
    this.exePath,
  });

  final bool ok;
  final String message;
  final int shortcutCount;
  final String? exePath;
}
