import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_url_blocklist_batch_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_hidden_process.dart';
import 'windows_protection_mode_prefs.dart';
import '../enforcement/layers/browser_policy_layer.dart';

/// Chrome/Edge PAC + WinINET with typed, reversible ownership.
final class WindowsChromiumRegistryService {
  WindowsChromiumRegistryService._();
  WindowsChromiumRegistryService.forTesting({
    required bool Function() protectionOff,
    required Future<ProcessResult> Function(String, List<String>) run,
    String? ownershipJournalPath,
    List<String>? browserPolicyRoots,
    String? internetSettingsRoot,
    String? offMarkerPath,
  }) : _protectionOffOverride = protectionOff,
       _runOverride = run,
       _journalOverride = ownershipJournalPath,
       _rootsOverride = browserPolicyRoots,
       _internetOverride = internetSettingsRoot,
       _offMarkerOverride = offMarkerPath;

  String? _journalOverride, _internetOverride, _offMarkerOverride;
  List<String>? _rootsOverride;
  String get _journal =>
      _journalOverride ?? BrowserPolicyLayer.ownedPacJournalPath;
  List<String> get _roots =>
      _rootsOverride ??
      const [
        r'HKCU:\Software\Policies\Google\Chrome',
        r'HKCU:\Software\Policies\Microsoft\Edge',
      ];
  String get _internet =>
      _internetOverride ??
      r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  String get _offMarker =>
      _offMarkerOverride ??
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
        'SixVPNBlocker',
        'protection_disabled_v1.json',
      );
  static String _quote(String value) => "'${value.replaceAll("'", "''")}'";
  String _ownershipScript(String uri) => BrowserPolicyLayer.ownedPacPowerShell(
    journalPath: _journal,
    offMarkerPath: _offMarker,
    values: [
      {
        'key': _internet,
        'name': 'AutoConfigURL',
        'kind': 'String',
        'value': uri,
      },
      for (final root in _roots) ...[
        {
          'key': root,
          'name': 'ProxyMode',
          'kind': 'String',
          'value': 'pac_script',
        },
        {'key': root, 'name': 'ProxyPacUrl', 'kind': 'String', 'value': uri},
        {
          'key': root,
          'name': 'BuiltInDnsClientEnabled',
          'kind': 'DWord',
          'value': 0,
        },
        {
          'key': root,
          'name': 'DnsOverHttpsMode',
          'kind': 'String',
          'value': 'off',
        },
      ],
    ],
  );
  static String get _powershell => p.join(
    Platform.environment['WINDIR'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );

  bool Function()? _protectionOffOverride;
  Future<ProcessResult> Function(String, List<String>)? _runOverride;
  bool get _protectionOff =>
      _protectionOffOverride?.call() ??
      WindowsProtectionModePrefs.isProtectionExplicitlyOff;
  Future<ProcessResult> _run(String executable, List<String> arguments) =>
      _runOverride?.call(executable, arguments) ??
      windowsRunHidden(executable, arguments);
  static final WindowsChromiumRegistryService instance =
      WindowsChromiumRegistryService._();

  static String _regExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'reg.exe');
  }

  /// Points WinINET + Chrome + Edge at [pacFile] (file:/// URI).
  Future<bool> applyPacEverywhere(String pacFile) async {
    if (!Platform.isWindows || _protectionOff) return false;
    if (!await File(pacFile).exists()) return false;

    final String uri = Uri.file(pacFile).toString();
    if (_protectionOff) return false;
    final script =
        '${_ownershipScript(uri)}\n'
        'if (Invoke-FFPacApply) { Write-Output "pac_ok=3"; exit 0 }; exit 1';
    final result = await _run(_powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
    AppLogger.instance.info('chromium_registry_pac: exit=${result.exitCode}');
    return !_protectionOff &&
        result.exitCode == 0 &&
        '${result.stdout}'.contains('pac_ok=3');
  }

  /// Legacy URL-only cleanup, used only when no typed ownership journal exists.
  /// It cannot reconstruct original settings from older builds.
  static String buildOwnedPacCleanupScript({
    required List<String> ownedUrls,
    required List<String> browserRoots,
    String? internetSettingsRoot,
  }) {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    return r'''
$ErrorActionPreference = 'Stop'
$owned = @(__URLS__)
foreach ($root in @(__ROOTS__)) {
  if (-not (Test-Path -LiteralPath $root)) { continue }
  $settings = Get-ItemProperty -LiteralPath $root
  if ($owned -icontains [string]$settings.ProxyPacUrl) {
    Remove-ItemProperty -LiteralPath $root -Name 'ProxyPacUrl'
    if ($settings.ProxyMode -ceq 'pac_script') {
      Remove-ItemProperty -LiteralPath $root -Name 'ProxyMode'
    }
  }
}
$internet = __INTERNET__
if ($internet -and (Test-Path -LiteralPath $internet)) {
  $settings = Get-ItemProperty -LiteralPath $internet
  if ($owned -icontains [string]$settings.AutoConfigURL) {
    Remove-ItemProperty -LiteralPath $internet -Name 'AutoConfigURL'
  }
}
'''
        .replaceAll('__URLS__', ownedUrls.map(quote).join(','))
        .replaceAll('__ROOTS__', browserRoots.map(quote).join(','))
        .replaceAll('__INTERNET__', quote(internetSettingsRoot ?? ''));
  }

  String buildPacCleanupScript({bool browsers = true, bool winInet = true}) {
    final legacy = buildOwnedPacCleanupScript(
      ownedUrls: <String>[
        Uri.file(WindowsEmergencyBlockService.pacPath()).toString(),
        Uri.file(
          p.join(
            WindowsEmergencyBlockService.programDataDir(),
            'sixvpn_block.pac',
          ),
        ).toString(),
      ],
      browserRoots: browsers ? _roots : const [],
      internetSettingsRoot: winInet ? _internet : null,
    );
    final selected = <String>[if (browsers) ..._roots, if (winInet) _internet];
    // @incident: pac-baseline-rollback — cleanup and apply hold the same lock;
    // legacy URL-only cleanup must not erase a successfully restored baseline.
    final script =
        '${_ownershipScript(Uri.file(WindowsEmergencyBlockService.pacPath()).toString())}\n'
        '\$cleanupLock = Open-FFPacLock\ntry {\n'
        'if (Test-Path -LiteralPath ${_quote(_journal)}) {\n'
        'Restore-FFPac -selectedKeys @(${selected.map(_quote).join(',')}) -LockHeld\n'
        '} else {\n$legacy\n}\n} finally { \$cleanupLock.Dispose() }';
    return script;
  }

  Future<void> clearOwnedPac({
    bool browsers = true,
    bool winInet = true,
  }) async {
    if (!Platform.isWindows) return;
    final result = await _run(_powershell, <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      buildPacCleanupScript(browsers: browsers, winInet: winInet),
    ]);
    if (result.exitCode != 0) {
      throw StateError('FocusFense PAC cleanup failed (${result.exitCode}).');
    }
  }

  /// Chrome/Edge `URLBlocklist` — delegates to one batched PowerShell `-File`
  /// run (was ~2000 sequential reg.exe spawns → minutes of CPU lag).
  Future<int> applyUrlBlocklistViaReg() async {
    if (!Platform.isWindows) return 0;
    final List<String> targets = await WindowsUrlBlocklistBatchService.instance
        .applyActivePatterns();
    return targets.where((String t) => t == 'Chrome' || t == 'Edge').length;
  }

  /// PAC only — URL blocklist is applied once via [WindowsHkcuPolicyService]
  /// / [WindowsUrlBlocklistBatchService] (avoid duplicate 2000-entry writes).
  Future<bool> ensureChromiumEnforcement({String? pacPath}) async {
    final String path = pacPath ?? WindowsEmergencyBlockService.pacPath();
    return applyPacEverywhere(path);
  }

  Future<void> _ensureKey(String keyPath) async {
    if (_protectionOff) return;
    final List<String> parts = keyPath.split(r'\');
    if (parts.length < 2 || parts.first != 'HKCU') return;
    String acc = 'HKCU\\${parts[1]}';
    await _run(_regExe(), <String>['add', acc, '/f']);
    for (int i = 2; i < parts.length; i++) {
      if (_protectionOff) return;
      acc = '$acc\\${parts[i]}';
      await _run(_regExe(), <String>['add', acc, '/f']);
    }
  }

  Future<bool> _regAddString(String key, String name, String value) async {
    if (_protectionOff) return false;
    final ProcessResult pr = await _run(_regExe(), <String>[
      'add',
      key,
      '/v',
      name,
      '/t',
      'REG_SZ',
      '/d',
      value,
      '/f',
    ]);
    if (pr.exitCode != 0) {
      final String err = '${pr.stderr}'.trim();
      if (err.toLowerCase().contains('access is denied') || err.contains('5')) {
        AppLogger.instance.warn(
          'chromium_registry: access denied $key\\$name (corp/MDM Edge lock)',
        );
      }
    }
    return pr.exitCode == 0;
  }

  /// True when HKCU Edge policy values cannot be written (common on managed PCs).
  Future<bool> isEdgeHkcuPolicyLocked() async {
    if (!Platform.isWindows || _protectionOff) return false;
    const String probeKey = r'HKCU\Software\Policies\Microsoft\Edge';
    await _ensureKey(probeKey);
    const String probeName = 'SixVPNBlockerProbe';
    final bool ok = await _regAddString(probeKey, probeName, '1');
    if (ok) {
      await _run(_regExe(), <String>[
        'delete',
        probeKey,
        '/v',
        probeName,
        '/f',
      ]);
    }
    return !ok;
  }

  /// After moving PAC to LocalAppData, rewrite stale ProgramData URIs.
  Future<void> migrateLegacyPacRegistry() async {
    if (!Platform.isWindows || _protectionOff) return;
    try {
      final ProcessResult pr = await _run(_regExe(), <String>[
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        '/v',
        'AutoConfigURL',
      ]);
      final String out = '${pr.stdout}';
      if (!out.contains('ProgramData') || !out.contains('sixvpn_block.pac')) {
        return;
      }
      await applyPacEverywhere(WindowsEmergencyBlockService.pacPath());
    } catch (_) {}
  }
}
