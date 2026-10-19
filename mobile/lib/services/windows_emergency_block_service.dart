import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chromium_policy_service.dart';
import 'connection_url_block_pattern_builder.dart';
import 'extension_rules_builder.dart';
import 'firefox_config_service.dart';
import 'mac_system_block_service.dart';
import 'windows_chromium_registry_service.dart';
import 'windows_firewall_block_service.dart';
import 'windows_hidden_process.dart';
import 'windows_system_block_service.dart';
import 'windows_protection_mode_prefs.dart';
import 'windows_browser_bypass_closer_service.dart';

/// Layers that work **without** UAC and without `HKCU\Software\Policies\…`
/// (locked by corporate GPO/EDR on some PCs).
final class EmergencyBlockResult {
  const EmergencyBlockResult({
    required this.pacApplied,
    required this.pacPath,
    required this.hostCount,
    required this.adminBatPath,
    required this.extensionRulesOk,
    required this.extensionHostCount,
    this.regInternetSettingsOk = false,
    this.errors = const <String>[],
  });

  final bool pacApplied;
  final String? pacPath;
  final int hostCount;
  final String? adminBatPath;
  final bool extensionRulesOk;
  final int extensionHostCount;
  final bool regInternetSettingsOk;
  final List<String> errors;

  bool get anyLayerActive =>
      pacApplied || extensionRulesOk || adminBatPath != null;

  String get summary {
    final List<String> lines = <String>[];
    if (pacApplied) {
      lines.add(
        '✅ PAC 프록시 (관리자 없음) — ${hostCount}개 도메인 → 127.0.0.1:9\n'
        '   Chrome/Edge가 시스템 프록시를 쓰면 차단됩니다.',
      );
    }
    if (extensionRulesOk) {
      lines.add('✅ 브라우저 확장 규칙 — ${extensionHostCount}개 도메인 (API 동기화됨)');
    }
    if (adminBatPath != null) {
      lines.add(
        '⚠ hosts·NRPT (시스템 DNS): 바탕화면 BAT 실행 필요\n'
        '   $adminBatPath\n'
        '   우클릭 → 관리자 권한으로 실행 (UAC 「예」) — PowerShell이 막혀도 CMD로 적용',
      );
    }
    if (errors.isNotEmpty) {
      lines.add('참고: ${errors.join(" · ")}');
    }
    if (lines.isEmpty) {
      return '비상 차단 레이어를 설치하지 못했습니다.';
    }
    return lines.join('\n');
  }
}

/// No-admin fallbacks when elevated hosts + HKCU Policies both fail.
final class WindowsEmergencyBlockService {
  WindowsEmergencyBlockService._();
  WindowsEmergencyBlockService.forTesting({
    required bool Function() protectionOff,
    required Future<bool> Function(String) applyPac,
    required Future<void> Function(String) configureFirefox,
  }) : _protectionOffOverride = protectionOff,
       _applyPacOverride = applyPac,
       _configureFirefoxOverride = configureFirefox;
  bool Function()? _protectionOffOverride;
  Future<bool> Function(String)? _applyPacOverride;
  Future<void> Function(String)? _configureFirefoxOverride;
  bool get _protectionOff =>
      _protectionOffOverride?.call() ??
      WindowsProtectionModePrefs.isProtectionExplicitlyOff;
  static const _disabled = EmergencyBlockResult(
    pacApplied: false,
    pacPath: null,
    hostCount: 0,
    adminBatPath: null,
    extensionRulesOk: false,
    extensionHostCount: 0,
  );

  /// Share the owned writer. Failed or interrupted apply must not fall through
  /// to an unjournaled registry write or configure another browser after OFF.
  Future<bool> applyPreparedPac(String path) async {
    if (!Platform.isWindows || _protectionOff) return false;
    final ok =
        await (_applyPacOverride?.call(path) ??
            WindowsChromiumRegistryService.instance.applyPacEverywhere(path));
    if (!ok || _protectionOff) return false;
    final uri = Uri.file(path).toString();
    if (_configureFirefoxOverride != null) {
      await _configureFirefoxOverride!(uri);
    } else {
      await FirefoxConfigService.instance.enablePacInAllProfiles(uri);
    }
    return !_protectionOff;
  }

  static final WindowsEmergencyBlockService instance =
      WindowsEmergencyBlockService._();

  static String programDataDir() {
    final String? pd = Platform.environment['ProgramData'];
    return p.join(pd ?? r'C:\ProgramData', 'SixVPNBlocker');
  }

  /// User-writable PAC dir (ProgramData often denies write without admin).
  static String pacStorageDir() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la != null && la.isNotEmpty) {
      return p.join(la, 'SixVPNBlocker');
    }
    final String? profile = Platform.environment['USERPROFILE'];
    return p.join(profile ?? '', 'AppData', 'Local', 'SixVPNBlocker');
  }

  static String pacPath() => p.join(pacStorageDir(), 'sixvpn_block.pac');

  /// Keeps old ProgramData PAC path valid for stale AutoConfigURL entries.
  static Future<void> _mirrorPacToLegacyPath(String localPac) async {
    try {
      final File src = File(localPac);
      if (!await src.exists()) return;
      final String legacyDir = programDataDir();
      await Directory(legacyDir).create(recursive: true);
      await src.copy(p.join(legacyDir, 'sixvpn_block.pac'));
    } catch (_) {}
  }

  static Future<void> _ensurePacFileReady() async {
    final Directory dir = Directory(pacStorageDir());
    await dir.create(recursive: true);
    final String local = pacPath();
    final File localFile = File(local);
    if (await localFile.exists()) return;
    final String legacy = p.join(programDataDir(), 'sixvpn_block.pac');
    final File legacyFile = File(legacy);
    if (await legacyFile.exists()) {
      await legacyFile.copy(local);
    }
  }

  static String _regExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'reg.exe');
  }

  /// Read-only status (for diagnostics after apply).
  Future<EmergencyBlockResult> readStatus() async {
    if (!Platform.isWindows) {
      return const EmergencyBlockResult(
        pacApplied: false,
        pacPath: null,
        hostCount: 0,
        adminBatPath: null,
        extensionRulesOk: false,
        extensionHostCount: 0,
      );
    }
    final bool pacReg = await _pacRegActive();
    final String? bat = await _desktopBatPath();
    final bool batExists = bat != null && await File(bat).exists();
    int extCount = 0;
    try {
      extCount = (await ExtensionRulesBuilder.buildForBrowserEnforcement())
          .blockedDomains
          .length;
    } catch (_) {}
    return EmergencyBlockResult(
      pacApplied: pacReg,
      pacPath: pacReg ? pacPath() : null,
      hostCount: 0,
      adminBatPath: batExists ? bat : null,
      extensionRulesOk: extCount > 0,
      extensionHostCount: extCount,
      regInternetSettingsOk: pacReg,
    );
  }

  Future<bool> _pacRegActive() async {
    try {
      final ProcessResult pr = await windowsRunHidden(_regExe(), <String>[
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        '/v',
        'AutoConfigURL',
      ]);
      final String out = (pr.stdout ?? '').toString();
      return out.contains('sixvpn_block.pac');
    } catch (_) {
      return false;
    }
  }

  Future<String?> _desktopBatPath() async {
    final String desktop =
        Platform.environment['USERPROFILE'] ?? r'C:\Users\Public';
    final String path = p.join(
      desktop,
      'Desktop',
      '6 VPN Blocker - hosts 적용 (관리자).bat',
    );
    return path;
  }

  /// PAC from active rules — blocks domains + YouTube channel/video URLs in **any**
  /// browser that respects WinINET PAC (Chrome, Edge, Firefox with our user.js).
  Future<EmergencyBlockResult> applyFromRules(
    ExtensionRulesPayload rules,
  ) async {
    if (_protectionOff || !rules.protectionEnabled) return _disabled;
    if (!Platform.isWindows) {
      return const EmergencyBlockResult(
        pacApplied: false,
        pacPath: null,
        hostCount: 0,
        adminBatPath: null,
        extensionRulesOk: false,
        extensionHostCount: 0,
      );
    }
    final List<String> hosts = await MacSystemBlockService.instance
        .enabledHostsExpanded();
    if (_protectionOff) return _disabled;
    final List<String> errors = <String>[];
    bool pacOk = false;
    bool regOk = false;

    try {
      await _ensurePacFileReady();
      if (_protectionOff) return _disabled;
      final String pacBody = _buildPac(hosts: hosts, rules: rules);
      final String pacFile = pacPath();
      await File(pacFile).writeAsString(pacBody, flush: true);
      await _mirrorPacToLegacyPath(pacFile);
      regOk = await applyPreparedPac(pacFile);
      if (_protectionOff) return _disabled;
      pacOk = regOk;
      if (!regOk) {
        errors.add('PAC 레지스트리 등록 실패');
      }
    } catch (e) {
      errors.add('PAC: $e');
    }

    return EmergencyBlockResult(
      pacApplied: pacOk,
      pacPath: pacOk ? pacPath() : null,
      hostCount: hosts.length,
      adminBatPath: null,
      extensionRulesOk: rules.keywords.isNotEmpty,
      extensionHostCount: rules.blockedDomains.length,
      regInternetSettingsOk: regOk,
      errors: errors,
    );
  }

  /// Applies every path that does not require admin.
  Future<EmergencyBlockResult> applyNow() async {
    if (_protectionOff) return _disabled;
    if (!Platform.isWindows) {
      return const EmergencyBlockResult(
        pacApplied: false,
        pacPath: null,
        hostCount: 0,
        adminBatPath: null,
        extensionRulesOk: false,
        extensionHostCount: 0,
      );
    }

    final List<String> hosts = await MacSystemBlockService.instance
        .enabledHostsExpanded();
    if (_protectionOff) return _disabled;
    final List<String> errors = <String>[];
    bool pacOk = false;
    bool regOk = false;
    String? batPath;

    try {
      await _ensurePacFileReady();
    } catch (e) {
      errors.add('PAC 폴더 준비 실패: $e');
    }

    try {
      final ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildForBrowserEnforcement();
      if (_protectionOff || !rules.protectionEnabled) return _disabled;
      final String pacBody = _buildPac(hosts: hosts, rules: rules);
      final String pacFile = pacPath();
      await File(pacFile).writeAsString(pacBody, flush: true);
      await _mirrorPacToLegacyPath(pacFile);
      regOk = await applyPreparedPac(pacFile);
      if (_protectionOff) return _disabled;
      pacOk = regOk;
      if (!regOk) {
        errors.add('인터넷 설정 PAC 등록 실패 (레지스트리 거부)');
      }
    } catch (e) {
      errors.add('PAC 파일 실패: $e');
    }

    try {
      if (!_protectionOff) batPath = await _writeAdminApplyBat(hosts);
    } catch (e) {
      errors.add('관리자 BAT 생성 실패: $e');
    }

    bool extOk = false;
    int extCount = 0;
    try {
      final ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildForBrowserEnforcement();
      extCount = rules.blockedDomains.length;
      extOk = extCount > 0;
    } catch (e) {
      errors.add('확장 규칙 읽기 실패: $e');
    }

    AppLogger.instance.info(
      'emergency block: pac=$pacOk hosts=${hosts.length} ext=$extOk bat=$batPath',
    );

    return EmergencyBlockResult(
      pacApplied: pacOk,
      pacPath: pacOk ? pacPath() : null,
      hostCount: hosts.length,
      adminBatPath: batPath,
      extensionRulesOk: extOk,
      extensionHostCount: extCount,
      regInternetSettingsOk: regOk,
      errors: errors,
    );
  }

  Future<void> removePac() async {
    if (!Platform.isWindows) return;
    Object? failure;
    try {
      await WindowsChromiumRegistryService.instance.clearOwnedPac(
        browsers: true,
      );
    } catch (error) {
      failure = error;
    }
    try {
      await FirefoxConfigService.instance
          .removeManagedNetworkPrefsInAllProfiles();
    } catch (error) {
      failure ??= error;
    }
    try {
      await WindowsBrowserBypassCloserService.instance.restoreOwnedHardening();
    } catch (error) {
      failure ??= error;
    }
    if (failure != null) {
      throw StateError('FocusFense network cleanup incomplete: $failure');
    }
  }

  String _buildPac({
    required List<String> hosts,
    ExtensionRulesPayload? rules,
  }) {
    final StringBuffer hostLines = StringBuffer();
    final Set<String> seenHosts = <String>{};
    for (final String raw in hosts) {
      final String h = MacSystemBlockService.canonicalHost(raw);
      if (h.isEmpty || !seenHosts.add(h)) continue;
      final String esc = _pacEscape(h);
      hostLines.writeln(
        "  if (dnsDomainIs(host, '$esc') || shExpMatch(host, '*.$esc')) return 'PROXY 127.0.0.1:9';",
      );
    }

    final StringBuffer youtubeLines = StringBuffer();
    if (rules != null) {
      // @incident: Aside YouTube overblock — a youtube rule must not turn
      // shared googlevideo/ytimg CDNs into a site-wide playback block.
      youtubeLines.writeln(_youtubePacLines(rules));
      youtubeLines.write(ConnectionUrlBlockPatternBuilder.pacLines(rules));
    }

    return '''
// 6 VPN Blocker — user-level PAC (no admin). Blocks via connection refused.
// Works in Chrome, Edge, Firefox (when proxy.type=2), and most WinINET apps.
function FindProxyForURL(url, host) {
  var u = (url || '').toLowerCase();
  // PAC receives a trailing DNS root dot on some URL forms. Normalize before
  // exact/suffix rules so `blocked.example.` cannot escape the host list.
  host = (host || '').toLowerCase().replace(/\\.\$/, '');
  var isYt = host.indexOf('youtube.com') >= 0 || host.indexOf('youtu.be') >= 0 || shExpMatch(host, '*.youtube.com');
$youtubeLines$hostLines
  return 'DIRECT';
}
''';
  }

  static String _pacEscape(String s) =>
      s.replaceAll('\\', r'\\').replaceAll("'", r"\'");

  static String _youtubePacLines(ExtensionRulesPayload rules) {
    final StringBuffer out = StringBuffer();
    final Set<String> emittedVids = <String>{};
    void emitVideo(String rawVid) {
      final String v = _pacEscape(rawVid.trim().toLowerCase());
      if (v.isEmpty || !emittedVids.add(v)) return;
      out.writeln(
        "  if (isYt && (u.indexOf('$v') >= 0 || shExpMatch(u, '*v=$v*') || shExpMatch(u, '*youtu.be/$v*') || shExpMatch(u, '*/shorts/$v*') || shExpMatch(u, '*/embed/$v*'))) return 'PROXY 127.0.0.1:9';",
      );
    }

    for (final String rawVid in ChromiumPolicyService.keywordYoutubeVideoIds(
      rules,
    )) {
      emitVideo(rawVid);
    }
    for (final String rawVid in rules.blockedYoutubeVideoIds) {
      emitVideo(rawVid);
    }
    for (final String handle in rules.blockedYoutubeHandles) {
      for (final String form in ChromiumPolicyService.youtubeHandlePacForms(
        handle,
      )) {
        final String h = _pacEscape(form);
        out.writeln(
          "  if (isYt && (shExpMatch(u, '*youtube.com/@$h*') || shExpMatch(u, '*youtube.com/c/$h*') || shExpMatch(u, '*/@$h*') || shExpMatch(u, '*/c/$h*'))) return 'PROXY 127.0.0.1:9';",
        );
      }
    }
    for (final String cid in rules.blockedYoutubeChannelIds) {
      final String c = _pacEscape(cid.toLowerCase());
      out.writeln(
        "  if (isYt && shExpMatch(u, '*youtube.com/channel/$c*')) return 'PROXY 127.0.0.1:9';",
      );
    }
    // Path-based blocks (shorts tab, gaming, etc.) — mitmproxy-style URL filter
    // without HTTPS MITM overhead.
    final Set<String> pathKeys = <String>{};
    for (final String k in rules.keywords) {
      final String kl = k.toLowerCase().trim();
      if (kl.isEmpty) continue;
      if (kl == 'shorts' || kl.contains('/shorts')) pathKeys.add('shorts');
      if (kl.contains('gaming') || kl.contains('/gaming'))
        pathKeys.add('gaming');
      if (kl.contains('/feed/')) {
        final RegExpMatch? m = RegExp(r'/feed/([a-z0-9_-]+)').firstMatch(kl);
        if (m != null) pathKeys.add('/feed/${m.group(1)}');
      }
      if (kl.startsWith('/') && kl.length > 2 && kl.contains('youtube')) {
        final int slash = kl.indexOf('/', kl.indexOf('youtube'));
        if (slash > 0) pathKeys.add(kl.substring(slash));
      }
    }
    for (final String path in pathKeys) {
      final String p = _pacEscape(path.toLowerCase());
      out.writeln(
        "  if (isYt && shExpMatch(u, '*$p*')) return 'PROXY 127.0.0.1:9';",
      );
    }
    return out.toString();
  }

  /// Desktop BAT + VBS elevate — **CMD copy only** (no PowerShell in admin path).
  Future<String?> _writeAdminApplyBat(List<String> hosts) async {
    final String dir = programDataDir();
    await Directory(dir).create(recursive: true);
    final String block = await MacSystemBlockService.instance
        .buildManagedHostsRegion(enableSafeSearch: true);
    final String orig =
        await WindowsSystemBlockService.tryReadSystemHostsNormalized() ?? '';
    final String merged = WindowsSystemBlockService.mergeHostsWithManagedRegion(
      orig,
      block,
    );
    final String mergedPath = p.join(dir, 'hosts_merged.txt');
    await File(mergedPath).writeAsString(merged, flush: true);

    final String hostsPath = WindowsSystemBlockService.systemHostsPath();
    final String cmdPath = p.join(dir, 'apply_hosts_admin.cmd');
    final String vbsPath = p.join(dir, 'sixvpn_elevate_hosts.vbs');
    final String logPath = p.join(dir, 'hosts_apply_cmd.log');
    final String fwSection = await WindowsFirewallBlockService.instance
        .buildCmdFirewallSectionFromState();

    final String cmd =
        '''
@echo off
setlocal
echo [6 VPN Blocker] copying merged hosts...
copy /Y "$mergedPath" "$hostsPath" >nul
if errorlevel 1 (
  echo COPY FAILED >> "$logPath"
  exit /b 1
)
"%SystemRoot%\\System32\\ipconfig.exe" /flushdns >nul 2>&1
echo hosts_ok %DATE% %TIME%>> "$logPath"
$fwSection
exit /b 0
''';
    await File(cmdPath).writeAsString(cmd, flush: true);

    final String vbs =
        '''
Set sh = CreateObject("Shell.Application")
sh.ShellExecute "cmd.exe", "/c ""$cmdPath""", "", "runas", 1
''';
    await File(vbsPath).writeAsString(vbs, flush: true);

    final String? batPath = await _desktopBatPath();
    if (batPath == null) return null;
    final String bat =
        '''
@echo off
title 6 VPN Blocker - hosts apply
echo UAC 창에서 [예] — hosts(1) + 방화벽(5) 한 번에 적용
cscript //nologo "$vbsPath"
timeout /t 3 >nul
if exist "$logPath" (
  type "$logPath"
) else (
  echo 로그 없음 — UAC 취소 또는 복사 실패
)
echo.
echo Chrome/Edge를 완전히 종료한 뒤 앱에서 사이트 점검을 다시 실행하세요.
pause
''';
    await File(batPath).writeAsString(bat, flush: true);
    return batPath;
  }
}
