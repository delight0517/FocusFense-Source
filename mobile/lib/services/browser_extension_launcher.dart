import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform_process.dart';
import 'windows_hidden_process.dart';
import 'windows_shell_open.dart';

/// Opens browser-internal pages (chrome://, edge://, about:) via the real
/// browser executable — **not** [url_launcher] (Windows Store) and **not**
/// CREATE_NO_WINDOW (Chrome UI would never appear).
final class BrowserExtensionLaunchResult {
  const BrowserExtensionLaunchResult({
    required this.ok,
    required this.message,
    this.browserExe,
  });

  final bool ok;
  final String message;
  final String? browserExe;
}

abstract final class BrowserExtensionLauncher {
  static Future<BrowserExtensionLaunchResult> openChromeExtensions() =>
      _openInBrowser(
        browserLabel: 'Google Chrome',
        url: 'chrome://extensions',
        exeCandidates: _chromeExeCandidates(),
      );

  static Future<BrowserExtensionLaunchResult> openEdgeExtensions() =>
      _openInBrowser(
        browserLabel: 'Microsoft Edge',
        url: 'edge://extensions',
        exeCandidates: _edgeExeCandidates(),
      );

  static Future<BrowserExtensionLaunchResult> openFirefoxDebugging() =>
      _openInBrowser(
        browserLabel: 'Firefox',
        url: 'about:debugging#/runtime/this-firefox',
        exeCandidates: _firefoxExeCandidates(),
      );

  static List<String> _chromeExeCandidates() {
    final List<String> out = <String>[
      p.join(
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
        'Google',
        'Chrome',
        'Application',
        'chrome.exe',
      ),
      p.join(
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
        'Google',
        'Chrome',
        'Application',
        'chrome.exe',
      ),
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'Google',
        'Chrome',
        'Application',
        'chrome.exe',
      ),
    ];
    return out;
  }

  static List<String> _edgeExeCandidates() => <String>[
        p.join(
          Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
          'Microsoft',
          'Edge',
          'Application',
          'msedge.exe',
        ),
        p.join(
          Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
          'Microsoft',
          'Edge',
          'Application',
          'msedge.exe',
        ),
      ];

  static List<String> _firefoxExeCandidates() => <String>[
        p.join(
          Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
          'Mozilla Firefox',
          'firefox.exe',
        ),
        p.join(
          Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
          'Mozilla Firefox',
          'firefox.exe',
        ),
        p.join(
          Platform.environment['LOCALAPPDATA'] ?? '',
          'Mozilla Firefox',
          'firefox.exe',
        ),
      ];

  static Future<String?> _exeFromAppPaths(String exeName) async {
    if (!Platform.isWindows) return null;
    const String key =
        r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths';
    try {
      final ProcessResult pr = await windowsRunHidden(
        p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'reg.exe',
        ),
        <String>['query', '$key\\$exeName', '/ve'],
      );
        final String out = '${pr.stdout}';
        final RegExp re = RegExp(r'REG_\w+\s+REG_\w+\s+(.+)\s*$', multiLine: true);
        final RegExpMatch? m = re.firstMatch(out);
        if (m != null) {
          final String path = m.group(1)!.trim();
          if (path.isNotEmpty && await File(path).exists()) return path;
        }
    } catch (_) {}
    return null;
  }

  static Future<List<String>> _mergeRegistry(
    List<String> candidates,
    String registryExeName,
  ) async {
    final String? reg = await _exeFromAppPaths(registryExeName);
    if (reg == null) return candidates;
    return <String>[reg, ...candidates];
  }

  static Future<BrowserExtensionLaunchResult> _openInBrowser({
    required String browserLabel,
    required String url,
    required List<String> exeCandidates,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return BrowserExtensionLaunchResult(
        ok: false,
        message: '$browserLabel: Windows·macOS에서만 자동 열기를 지원합니다.',
      );
    }

    if (Platform.isMacOS) {
      final String app = browserLabel.contains('Edge')
          ? 'Microsoft Edge'
          : browserLabel.contains('Firefox')
              ? 'Firefox'
              : 'Google Chrome';
      try {
        await Process.run('open', <String>['-a', app, url]);
        return BrowserExtensionLaunchResult(
          ok: true,
          message: '$browserLabel 에서 $url 을(를) 열었습니다.',
        );
      } catch (e) {
        return BrowserExtensionLaunchResult(
          ok: false,
          message: '$browserLabel 실행 실패: $e\n주소창에 $url 을 붙여넣으세요.',
        );
      }
    }

    final String regName = browserLabel.contains('Edge')
        ? 'msedge.exe'
        : browserLabel.contains('Firefox')
            ? 'firefox.exe'
            : 'chrome.exe';
    final List<String> candidates =
        await _mergeRegistry(exeCandidates, regName);

    final List<List<String>> argVariants = <List<String>>[
      <String>['--new-window', url],
      <String>[url],
    ];

    for (final String exe in candidates) {
      if (exe.isEmpty || !await File(exe).exists()) continue;
      for (final List<String> args in argVariants) {
        try {
          if (await WindowsShellOpen.runGuiExecutable(
            exe,
            args,
            workingDirectory: p.dirname(exe),
          )) {
            return BrowserExtensionLaunchResult(
              ok: true,
              message: '$browserLabel 실행됨 → $url',
              browserExe: exe,
            );
          }
        } catch (_) {}
        try {
          await Process.start(
            exe,
            args,
            workingDirectory: p.dirname(exe),
            mode: ProcessStartMode.detached,
          );
          return BrowserExtensionLaunchResult(
            ok: true,
            message: '$browserLabel 실행됨 → $url',
            browserExe: exe,
          );
        } catch (_) {}
      }
    }

    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      await windowsStartDetachedHidden(
        p.join(windir, 'System32', 'cmd.exe'),
        <String>['/c', 'start', '', url],
      );
      return BrowserExtensionLaunchResult(
        ok: true,
        message: '기본 브라우저로 열기 시도: $url',
      );
    } catch (e) {
      return BrowserExtensionLaunchResult(
        ok: false,
        message:
            '$browserLabel 을(를) 찾지 못했습니다.\n'
            '① $browserLabel 을(를) 직접 실행한 뒤\n'
            '② 주소창에 붙여넣기:\n$url',
      );
    }
  }

  /// Opens extension folder in Explorer; highlights [manifest.json] if present.
  static Future<void> revealExtensionFolder(String folderPath) async {
    final String manifest = p.join(folderPath, 'manifest.json');
    if (await File(manifest).exists()) {
      await PlatformProcess.revealFileInFolder(manifest);
    } else {
      await PlatformProcess.openFolder(folderPath);
    }
  }
}
