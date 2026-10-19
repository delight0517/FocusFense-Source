import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/chromium_derivative_browsers.dart';
import '../data/browser_extension_asset_manifest.dart';
import 'browser_extension_export_service.dart';
import 'chrome_install_discovery_service.dart';
import 'extension_guard_prefs.dart';
import 'windows_emergency_block_service.dart';
import 'windows_hidden_process.dart';

/// Silent launchers (VBS) + system shortcut integration for Chrome, Edge, Firefox.
abstract final class ChromeLoadExtensionLauncher {
  static String get sixVpnDir {
    final String la =
        Platform.environment['LOCALAPPDATA'] ?? r'C:\Users\Public';
    return p.join(la, 'SixVPNBlocker');
  }

  static String get chromeVbsPath =>
      p.join(sixVpnDir, 'Launch-6VPN-Chrome.vbs');
  static String get edgeVbsPath => p.join(sixVpnDir, 'Launch-6VPN-Edge.vbs');
  static String get firefoxVbsPath =>
      p.join(sixVpnDir, 'Launch-6VPN-Firefox.vbs');
  static String get braveVbsPath => p.join(sixVpnDir, 'Launch-6VPN-Brave.vbs');

  /// Legacy; new shortcuts use [chromeVbsPath] directly.
  static String get chromeBatPath =>
      p.join(sixVpnDir, 'Launch-6VPN-Chrome.bat');
  static String get edgeBatPath => p.join(sixVpnDir, 'Launch-6VPN-Edge.bat');
  static String get firefoxBatPath =>
      p.join(sixVpnDir, 'Launch-6VPN-Firefox.bat');

  static String get stableChromeExtDir => p.join(sixVpnDir, 'chrome_blocker');

  static String get stableBraveExtDir => p.join(sixVpnDir, 'brave_blocker');

  /// Primary launcher path per browser (VBS = no CMD flash, no taskkill).
  static String launcherPathFor(String kind) {
    switch (kind) {
      case 'edge':
        return edgeVbsPath;
      case 'firefox':
        return firefoxVbsPath;
      default:
        return chromeVbsPath;
    }
  }

  // @incident: extension-export-destroys-last-good — never merge unverified
  // source files over the installed payload, or delete its retired fallback.
  static Future<String> mirrorExtensionFolder(String sourceFolder) async {
    if (p.equals(
      p.normalize(p.absolute(sourceFolder)),
      p.normalize(p.absolute(stableChromeExtDir)),
    )) {
      await BrowserExtensionExportService.exportSignedChromiumPackage(
        browserId: 'chrome',
        folder: sourceFolder,
      );
      return sourceFolder;
    }
    // Canonical bundled assets and their matching signed package are the source
    // of truth, including when a legacy Downloads folder was selected.
    return BrowserExtensionExportService.exportVerifiedChromiumPayload(
      browserId: 'chrome',
      assetPaths: BrowserExtensionAssetManifest.chrome,
      targetDir: stableChromeExtDir,
    );
  }

  static Future<bool> hasValidPayload() async {
    if (!Platform.isWindows) return false;
    return File(p.join(stableChromeExtDir, 'manifest.json')).exists();
  }

  static Future<LoadExtensionLauncherResult> install({
    required String extensionFolder,
  }) async {
    if (!Platform.isWindows) {
      return const LoadExtensionLauncherResult(
        ok: false,
        message: 'Windows 전용',
      );
    }
    final Directory dir = Directory(sixVpnDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final String extFolder = await mirrorExtensionFolder(extensionFolder);
    final String? chrome =
        (await ChromeInstallDiscoveryService.instance.canonical())?.exePath;
    final List<String> edgePaths = <String>[
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
    final List<String> firefoxPaths = <String>[
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
    ];

    final String? edge = await _firstExistingExe(edgePaths);
    final String? firefox = await _firstExistingExe(firefoxPaths);
    if (chrome == null && edge == null && firefox == null) {
      return const LoadExtensionLauncherResult(
        ok: false,
        message: 'Chrome/Edge/Firefox 실행 파일을 찾지 못했습니다.',
      );
    }

    final StringBuffer log = StringBuffer();
    if (chrome != null &&
        !ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('chrome')) {
      await _writeChromiumLaunchers(
        vbsPath: chromeVbsPath,
        batPath: chromeBatPath,
        browserExe: chrome,
        extFolder: extFolder,
        label: 'Chrome',
      );
      log.writeln('Chrome 무음 실행기');
    }
    if (edge != null &&
        !ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('edge')) {
      await _writeChromiumLaunchers(
        vbsPath: edgeVbsPath,
        batPath: edgeBatPath,
        browserExe: edge,
        extFolder: extFolder,
        label: 'Edge',
      );
      log.writeln('Edge 무음 실행기');
    }
    if (firefox != null &&
        !ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('firefox')) {
      await _writeFirefoxLaunchers(
        vbsPath: firefoxVbsPath,
        batPath: firefoxBatPath,
        browserExe: firefox,
      );
      log.writeln('Firefox 실행기 (정책 확장)');
    }

    await ExtensionGuardPrefs.instance.setLoadExtensionFallback(true);
    await removeLegacyDesktopShortcuts();
    return LoadExtensionLauncherResult(
      ok: true,
      message: 'Chrome/Edge/Firefox 보호 실행기 준비됨.',
      chromeBat: chrome != null ? chromeVbsPath : null,
      edgeBat: edge != null ? edgeVbsPath : null,
      firefoxBat: firefox != null ? firefoxVbsPath : null,
    );
  }

  static Future<bool> isInstalled() async {
    if (!Platform.isWindows) return false;
    final bool launchers =
        await File(chromeVbsPath).exists() ||
        await File(edgeVbsPath).exists() ||
        await File(firefoxVbsPath).exists();
    return launchers && await hasValidPayload();
  }

  /// Brave 전용 — `--load-extension` + PAC (Chrome과 별도 payload 폴더).
  static Future<LoadExtensionLauncherResult> installBrave({
    required String extensionFolder,
  }) async {
    if (!Platform.isWindows) {
      return const LoadExtensionLauncherResult(
        ok: false,
        message: 'Windows 전용',
      );
    }
    final Directory dir = Directory(sixVpnDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    if (!await File(p.join(extensionFolder, 'manifest.json')).exists()) {
      return const LoadExtensionLauncherResult(
        ok: false,
        message: 'Brave 확장 manifest.json 없음',
      );
    }
    final String extFolder = extensionFolder;
    final String? brave = await _firstExistingExe(<String>[
      p.join(
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
        'BraveSoftware',
        'Brave-Browser',
        'Application',
        'brave.exe',
      ),
      p.join(
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
        'BraveSoftware',
        'Brave-Browser',
        'Application',
        'brave.exe',
      ),
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'BraveSoftware',
        'Brave-Browser',
        'Application',
        'brave.exe',
      ),
    ]);
    if (brave == null) {
      return const LoadExtensionLauncherResult(
        ok: false,
        message: 'brave.exe를 찾지 못했습니다.',
      );
    }
    await _writeChromiumLaunchers(
      vbsPath: braveVbsPath,
      batPath: p.join(sixVpnDir, 'Launch-6VPN-Brave.bat'),
      browserExe: brave,
      extFolder: extFolder,
      label: 'Brave',
    );
    return LoadExtensionLauncherResult(
      ok: true,
      message: 'Brave 보호 실행기 준비됨.',
      chromeBat: braveVbsPath,
    );
  }

  /// Vivaldi · Whale · Opera — `--load-extension` fallback launcher.
  static Future<bool> installDerivative({
    required ChromiumDerivativeBrowserDef def,
    required String extensionFolder,
  }) async {
    if (!Platform.isWindows) return false;
    if (ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled(def.id)) {
      return false;
    }
    if (!await File(p.join(extensionFolder, 'manifest.json')).exists()) {
      return false;
    }
    final Directory dir = Directory(sixVpnDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final String? exe = await _firstExistingExe(def.exeCandidates);
    if (exe == null) return false;
    final String vbs = p.join(sixVpnDir, def.vbsFileName);
    await _writeChromiumLaunchers(
      vbsPath: vbs,
      batPath: p.join(sixVpnDir, def.vbsFileName.replaceAll('.vbs', '.bat')),
      browserExe: exe,
      extFolder: extensionFolder,
      label: def.displayName,
    );
    return true;
  }

  /// Desktop browser shortcuts are no longer created (user request).
  static Future<void> removeLegacyDesktopShortcuts() async {
    if (!Platform.isWindows) return;
    final String? user = Platform.environment['USERPROFILE'];
    if (user == null || user.isEmpty) return;
    final String desktop = p.join(user, 'Desktop');
    const List<String> names = <String>[
      '6 VPN Blocker (Chrome).lnk',
      '6 VPN Blocker (Edge).lnk',
      '6 VPN Blocker (Firefox).lnk',
      '6 VPN Blocker (Windows).lnk',
      '6 VPN Blocker (Windows) - Rebuild.lnk',
      '6 VPN Blocker - Rebuild.bat',
    ];
    for (final String name in names) {
      final File f = File(p.join(desktop, name));
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }

  static Future<bool> _createShortcut({
    required String lnkPath,
    required String target,
    required String workDir,
    required String description,
    String? iconExe,
  }) async {
    try {
      final Directory parent = Directory(p.dirname(lnkPath));
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      String psq(String s) => s.replaceAll("'", "''");
      final String iconLine = iconExe != null
          ? "\$s.IconLocation = '${psq(iconExe)},0'; "
          : '';
      final String cmd =
          "\$ws = New-Object -ComObject WScript.Shell; "
          "\$s = \$ws.CreateShortcut('${psq(lnkPath)}'); "
          "\$s.TargetPath = '${psq(target)}'; "
          "\$s.WorkingDirectory = '${psq(workDir)}'; "
          "\$s.Description = '${psq(description)}'; "
          '$iconLine'
          '\$s.WindowStyle = 1; '
          '\$s.Save()';
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult res = await windowsRunHidden(
        p.join(
          windir,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
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

  /// Opens Firefox with [url] (enterprise policy extension when installed).
  static Future<bool> openUrlInProtectedFirefox(String url) async {
    if (!Platform.isWindows || url.trim().isEmpty) return false;
    final String? firefox = await _firstExistingExe(<String>[
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
    ]);
    if (firefox == null) return false;
    try {
      await Process.start(firefox, <String>[
        url.trim(),
      ], mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens [url] with `--load-extension` (no taskkill — light self-heal probe).
  static Future<bool> openUrlInProtectedChrome(String url) async {
    if (!Platform.isWindows || url.trim().isEmpty) return false;
    if (!await hasValidPayload()) return false;
    final String? chrome =
        (await ChromeInstallDiscoveryService.instance.canonical())?.exePath;
    if (chrome == null) return false;
    final String ext = stableChromeExtDir;
    try {
      await Process.start(chrome, <String>[
        '--disable-extensions-except=$ext',
        '--load-extension=$ext',
        '--disable-quic',
        '--proxy-pac-url=${Uri.file(WindowsEmergencyBlockService.pacPath()).toString()}',
        '--disable-background-networking',
        url.trim(),
      ], mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Direct exe launch — more reliable than wscript VBS on some systems.
  static Future<bool> launchChromeDirect() async {
    if (!Platform.isWindows) return false;
    if (ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('chrome')) {
      return false;
    }
    if (!await hasValidPayload()) return false;
    final String? chrome =
        (await ChromeInstallDiscoveryService.instance.canonical())?.exePath;
    if (chrome == null) return false;
    final String ext = stableChromeExtDir;
    try {
      await Process.start(chrome, <String>[
        '--disable-extensions-except=$ext',
        '--load-extension=$ext',
        '--disable-quic',
        '--proxy-pac-url=${Uri.file(WindowsEmergencyBlockService.pacPath()).toString()}',
        '--disable-background-networking',
        '--new-window',
      ], mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> launchChrome() async {
    final bool direct = await launchChromeDirect();
    if (direct) return true;
    return _launchVbs(chromeVbsPath);
  }

  static Future<bool> launchEdge() => _launchVbs(edgeVbsPath);

  static Future<bool> launchFirefox() => _launchVbs(firefoxVbsPath);

  static Future<bool> _launchVbs(String vbsPath) async {
    if (!Platform.isWindows) return false;
    final Map<String, String> managed = <String, String>{
      chromeVbsPath: 'chrome',
      edgeVbsPath: 'edge',
      firefoxVbsPath: 'firefox',
      for (final ChromiumDerivativeBrowserDef def
          in kChromiumDerivativeBrowsers)
        p.join(sixVpnDir, def.vbsFileName): def.id,
    };
    final String? browser = managed[vbsPath];
    if (browser != null &&
        ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled(browser)) {
      return false;
    }
    final File vbs = File(vbsPath);
    if (!await vbs.exists()) return false;
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      await Process.start(p.join(windir, 'System32', 'wscript.exe'), <String>[
        '//B',
        '//Nologo',
        vbs.path,
      ], mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _firstExistingExe(List<String> paths) async {
    for (final String path in paths) {
      if (path.isNotEmpty && await File(path).exists()) return path;
    }
    return null;
  }

  static String _vbsQuote(String path) => path.replaceAll('"', '""');

  /// Re-writes VBS launchers with current PAC path (after universal block sync).
  static Future<void> refreshChromiumLaunchersFromDisk() async {
    if (!Platform.isWindows) return;
    if (!await hasValidPayload()) return;
    final String ext = stableChromeExtDir;
    final String? chrome =
        (await ChromeInstallDiscoveryService.instance.canonical())?.exePath;
    final List<String> edgePaths = <String>[
      p.join(
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
        'Microsoft',
        'Edge',
        'Application',
        'msedge.exe',
      ),
    ];
    final String? edge = await _firstExistingExe(edgePaths);
    if (chrome != null) {
      await _writeChromiumLaunchers(
        vbsPath: chromeVbsPath,
        batPath: chromeBatPath,
        browserExe: chrome,
        extFolder: ext,
        label: 'Chrome',
      );
    }
    if (edge != null) {
      await _writeChromiumLaunchers(
        vbsPath: edgeVbsPath,
        batPath: edgeBatPath,
        browserExe: edge,
        extFolder: ext,
        label: 'Edge',
      );
    }
  }

  static String _chromiumNetworkFlags() {
    final String pacUri = Uri.file(
      WindowsEmergencyBlockService.pacPath(),
    ).toString();
    final String pacEsc = _vbsQuote(pacUri);
    return ' --disable-quic --proxy-pac-url="$pacEsc"';
  }

  static Future<void> _writeChromiumLaunchers({
    required String vbsPath,
    required String batPath,
    required String browserExe,
    required String extFolder,
    required String label,
  }) async {
    final String netFlags = _chromiumNetworkFlags();
    final String vbs =
        '''
' 6 VPN Blocker — $label (extension + PAC + no QUIC)
Option Explicit
Dim sh, browser, ext, cmd, netFlags
ext = "${_vbsQuote(extFolder)}"
browser = "${_vbsQuote(browserExe)}"
netFlags = "${_vbsQuote(netFlags)}"
Set sh = CreateObject("WScript.Shell")
cmd = """" & browser & """ --disable-extensions-except=""" & ext & """ --load-extension=""" & ext & """" & netFlags
sh.Run cmd, 1, False
''';
    await File(vbsPath).writeAsString(vbs, flush: true);
    final String bat =
        '''
@echo off
REM 6 VPN Blocker — delegates to silent VBS
wscript.exe //B //Nologo "%~dp0${p.basename(vbsPath)}"
''';
    await File(batPath).writeAsString(bat, flush: true);
  }

  static Future<void> _writeFirefoxLaunchers({
    required String vbsPath,
    required String batPath,
    required String browserExe,
  }) async {
    final String vbs =
        '''
' 6 VPN Blocker — Firefox (enterprise policy loads extension)
Option Explicit
Dim sh, browser
browser = "${_vbsQuote(browserExe)}"
Set sh = CreateObject("WScript.Shell")
sh.Run """" & browser & """", 1, False
''';
    await File(vbsPath).writeAsString(vbs, flush: true);
    final String bat =
        '''
@echo off
wscript.exe //B //Nologo "%~dp0${p.basename(vbsPath)}"
''';
    await File(batPath).writeAsString(bat, flush: true);
  }
}

final class LoadExtensionLauncherResult {
  const LoadExtensionLauncherResult({
    required this.ok,
    required this.message,
    this.chromeBat,
    this.edgeBat,
    this.firefoxBat,
  });

  final bool ok;
  final String message;
  final String? chromeBat;
  final String? edgeBat;
  final String? firefoxBat;
}
