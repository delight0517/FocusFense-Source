import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'windows_hidden_process.dart';

/// Chrome-only **URLAllowlist** so Gmail · Gemini · Google sign-in stay
/// reachable while `<*>` (or URLBlocklist) blocks everything else — including
/// YouTube on browsers that do not have Firefox-grade channel automation.
final class ChromeGmailGeminiAllowlistService {
  ChromeGmailGeminiAllowlistService._();
  static final ChromeGmailGeminiAllowlistService instance =
      ChromeGmailGeminiAllowlistService._();

  static const String _kPrefEnabled = 'chrome_gmail_gemini_only_v1';

  /// Patterns managed by this service — bypass closer must not delete these.
  static const List<String> kManagedAllowPatterns = <String>[
    '*://mail.google.com/*',
    'https://mail.google.com/*',
    '*://gmail.com/*',
    '*://gemini.google.com/*',
    '*://bard.google.com/*',
    '*://accounts.google.com/*',
    'https://accounts.google.com/*',
    '*://accounts.google.com/signin/*',
    '*://accounts.google.com/v3/signin/*',
    '*://signin.google.com/*',
    '*://myaccount.google.com/*',
    '*://ogs.google.com/*',
    '*://www.gstatic.com/*',
    '*://ssl.gstatic.com/*',
    '*://fonts.gstatic.com/*',
    '*://apis.google.com/*',
    '*://content.googleapis.com/*',
    '*://workspace.google.com/*',
  ];

  static const String kChromeRoot = r'HKCU\SOFTWARE\Policies\Google\Chrome';
  static const String _chromeAllowlistKey =
      r'HKCU\SOFTWARE\Policies\Google\Chrome\URLAllowlist';

  /// Block-all sentinel — URLAllowlist above takes precedence for Gmail/Gemini.
  static const String kBlockAllPattern = '<*>';

  bool get isSupported => Platform.isWindows;

  Future<bool> enabled() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_kPrefEnabled) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_kPrefEnabled, value);
  }

  /// Read-only verification that Chrome's approved destinations reached policy.
  Future<bool> isAppliedOnDisk() async {
    if (!isSupported) return false;
    final ProcessResult result = await windowsRunHidden(_regExe(), <String>[
      'query',
      _chromeAllowlistKey,
    ]);
    if (result.exitCode != 0) return false;
    final String output = '${result.stdout}'.toLowerCase();
    return output.contains('mail.google.com') &&
        output.contains('gemini.google.com') &&
        output.contains('accounts.google.com');
  }

  /// Returns true when [valueData] is one of our managed allowlist rows.
  static bool isManagedAllowPattern(String valueData) {
    final String v = valueData.trim().toLowerCase();
    if (v.isEmpty) return false;
    for (final String pat in kManagedAllowPatterns) {
      if (v == pat.toLowerCase()) return true;
    }
    return v.contains('mail.google.com') ||
        v.contains('gemini.google.com') ||
        v.contains('accounts.google.com/signin');
  }

  String _regExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'reg.exe');
  }

  String _powershellExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  /// Writes Chrome **URLAllowlist** only. Full URLBlocklist (megaskorea 등) is
  /// applied by [WindowsUrlBlocklistBatchService] — allowlist wins over blocklist.
  Future<bool> applyNow({bool? enabledOverride}) async {
    if (!isSupported) return false;
    final bool on = enabledOverride ?? await enabled();
    if (!on) {
      await removeNow();
      return true;
    }

    try {
      final ProcessResult pr = await windowsRunHidden(_regExe(), <String>[
        'add',
        kChromeRoot,
        '/f',
      ]);
      if (pr.exitCode != 0) {
        AppLogger.instance.warn('chrome allowlist: root add failed');
      }

      final String blockKey = '$kChromeRoot\\URLBlocklist';
      final bool blockAllOk = await _ensureBlockAll(blockKey);

      final String allowKey = '$kChromeRoot\\URLAllowlist';
      await windowsRunHidden(_regExe(), <String>['delete', allowKey, '/f']);
      await windowsRunHidden(_regExe(), <String>['add', allowKey, '/f']);

      for (int i = 0; i < kManagedAllowPatterns.length; i++) {
        await windowsRunHidden(_regExe(), <String>[
          'add',
          allowKey,
          '/v',
          '${i + 1}',
          '/t',
          'REG_SZ',
          '/d',
          kManagedAllowPatterns[i],
          '/f',
        ]);
      }

      AppLogger.instance.info(
        'chrome allowlist: Gmail/Gemini-only mode ON '
        '(${kManagedAllowPatterns.length} allow rows; URLBlocklist는 HKCU 배치가 유지)',
      );
      if (!blockAllOk) {
        AppLogger.instance.warn('chrome allowlist: URLBlocklist <*> missing');
      }
      return blockAllOk;
    } catch (e, st) {
      AppLogger.instance.error(
        'chrome allowlist apply failed',
        error: e,
        stack: st,
      );
      return false;
    }
  }

  Future<void> removeNow() async {
    if (!isSupported) return;
    try {
      final String allowKey = '$kChromeRoot\\URLAllowlist';
      await windowsRunHidden(_regExe(), <String>['delete', allowKey, '/f']);
      await windowsRunHidden(_regExe(), <String>[
        'delete',
        '$kChromeRoot\\URLBlocklist',
        '/f',
      ]);
      AppLogger.instance.info('chrome allowlist: Gmail/Gemini-only mode OFF');
    } catch (e) {
      AppLogger.instance.warn('chrome allowlist remove failed', error: e);
    }
  }

  Future<bool> _ensureBlockAll(String blockKey) async {
    await windowsRunHidden(_regExe(), <String>['delete', blockKey, '/f']);
    await windowsRunHidden(_regExe(), <String>['add', blockKey, '/f']);
    await windowsRunHidden(_regExe(), <String>[
      'add',
      blockKey,
      '/v',
      '1',
      '/t',
      'REG_SZ',
      '/d',
      kBlockAllPattern,
      '/f',
    ]);
    if (await _hasBlockAll(blockKey)) return true;

    const String ps = r'''
$ErrorActionPreference = 'Stop'
$key = 'HKCU:\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
if (Test-Path -LiteralPath $key) {
  Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -LiteralPath $key -Name '1' -Value '<*>' -Type String -Force
''';
    await windowsRunHidden(_powershellExe(), <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-Command',
      ps,
    ]);
    return _hasBlockAll(blockKey);
  }

  Future<bool> _hasBlockAll(String blockKey) async {
    final ProcessResult pr = await windowsRunHidden(_regExe(), <String>[
      'query',
      blockKey,
      '/v',
      '1',
    ]);
    return pr.exitCode == 0 && '${pr.stdout}'.contains(kBlockAllPattern);
  }
}
