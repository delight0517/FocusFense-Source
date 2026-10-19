import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_hidden_process.dart';

/// Reads Chrome / Edge "Secure DNS" prefs so we can explain hosts bypass.
final class ChromeDnsProbeService {
  ChromeDnsProbeService._();
  static final ChromeDnsProbeService instance = ChromeDnsProbeService._();

  Future<List<BrowserDnsProfileStatus>> probeInstalledBrowsers() async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return const <BrowserDnsProfileStatus>[];
    }
    final List<BrowserDnsProfileStatus> out = <BrowserDnsProfileStatus>[];
    final String? local = Platform.environment['LOCALAPPDATA'];
    final String? home = Platform.environment['HOME'];
    if (Platform.isWindows && local != null) {
      out.add(await _probeChromiumRoot(
        label: 'Chrome',
        userDataRoot: p.join(local, 'Google', 'Chrome', 'User Data'),
      ));
      out.add(await _probeChromiumRoot(
        label: 'Edge',
        userDataRoot: p.join(local, 'Microsoft', 'Edge', 'User Data'),
      ));
    }
    if (Platform.isMacOS && home != null) {
      out.add(await _probeChromiumRoot(
        label: 'Chrome',
        userDataRoot: p.join(home, 'Library', 'Application Support', 'Google', 'Chrome'),
      ));
      out.add(await _probeChromiumRoot(
        label: 'Edge',
        userDataRoot: p.join(home, 'Library', 'Application Support', 'Microsoft Edge'),
      ));
    }
    return out.where((BrowserDnsProfileStatus s) => s.found).toList();
  }

  Future<BrowserDnsProfileStatus> _probeChromiumRoot({
    required String label,
    required String userDataRoot,
  }) async {
    final Directory root = Directory(userDataRoot);
    if (!await root.exists()) {
      return BrowserDnsProfileStatus(
        browser: label,
        profileName: '',
        found: false,
        secureDnsLikelyOn: false,
        detail: '설치/프로필 없음',
      );
    }
    final File prefs = File(p.join(userDataRoot, 'Default', 'Preferences'));
    if (!await prefs.exists()) {
      return BrowserDnsProfileStatus(
        browser: label,
        profileName: 'Default',
        found: true,
        secureDnsLikelyOn: false,
        detail: 'Preferences 없음 — 기본 DNS 사용 추정',
      );
    }
    try {
      final String raw = await prefs.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return BrowserDnsProfileStatus(
          browser: label,
          profileName: 'Default',
          found: true,
          secureDnsLikelyOn: false,
          detail: 'Preferences 파싱 실패',
        );
      }
      final _SecureDnsParse parsed = _parseSecureDns(decoded);
      return BrowserDnsProfileStatus(
        browser: label,
        profileName: 'Default',
        found: true,
        secureDnsLikelyOn: parsed.likelyOn,
        detail: parsed.detail,
        mode: parsed.mode,
      );
    } catch (e) {
      return BrowserDnsProfileStatus(
        browser: label,
        profileName: 'Default',
        found: true,
        secureDnsLikelyOn: false,
        detail: '읽기 오류: $e',
      );
    }
  }

  static _SecureDnsParse _parseSecureDns(Map<String, dynamic> root) {
    final Object? doh = root['dns_over_https'];
    if (doh is Map<String, dynamic>) {
      final String mode = (doh['mode'] as String? ?? '').toLowerCase();
      if (mode == 'secure') {
        return const _SecureDnsParse(
          likelyOn: true,
          mode: 'secure',
          detail: '보안 DNS = Secure (Cloudflare/Google 등) — hosts 우회',
        );
      }
      if (mode == 'automatic') {
        return const _SecureDnsParse(
          likelyOn: true,
          mode: 'automatic',
          detail: '보안 DNS = 자동 — 일부 환경에서 hosts 우회',
        );
      }
      if (mode == 'off') {
        return const _SecureDnsParse(
          likelyOn: false,
          mode: 'off',
          detail: '보안 DNS = 끔 — OS hosts 사용',
        );
      }
    }
    final Object? secure = root['secure_dns'];
    if (secure is Map<String, dynamic>) {
      final Object? modeRaw = secure['mode'];
      final int mode = modeRaw is int ? modeRaw : int.tryParse('$modeRaw') ?? -1;
      if (mode == 2) {
        return const _SecureDnsParse(
          likelyOn: true,
          mode: 'secure',
          detail: 'secure_dns.mode=2 (Secure) — hosts 우회',
        );
      }
      if (mode == 1) {
        return const _SecureDnsParse(
          likelyOn: true,
          mode: 'automatic',
          detail: 'secure_dns.mode=1 (자동)',
        );
      }
      if (mode == 0) {
        return const _SecureDnsParse(
          likelyOn: false,
          mode: 'off',
          detail: 'secure_dns.mode=0 — OS hosts 사용',
        );
      }
    }
    return const _SecureDnsParse(
      likelyOn: false,
      mode: 'default',
      detail: '보안 DNS 설정 없음 — OS hosts 사용 (권장)',
    );
  }

  /// Opens Chrome net-internals DNS page (user taps Clear host cache).
  Future<bool> openChromeDnsHostCache({String browser = 'Chrome'}) async {
    return openUrl('chrome://net-internals/#dns', browser: browser);
  }

  /// Opens Chromium security settings (user turns Secure DNS off).
  Future<bool> openSecureDnsSettings({String browser = 'Chrome'}) async {
    final String url = browser == 'Edge'
        ? 'edge://settings/privacy'
        : 'chrome://settings/security';
    if (Platform.isWindows) {
      final List<String> candidates = browser == 'Edge'
          ? <String>[
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
            ]
          : <String>[
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
      for (final String exe in candidates) {
        if (exe.isEmpty || !await File(exe).exists()) continue;
        try {
          await windowsStartDetachedHidden(exe, <String>[url]);
          return true;
        } catch (_) {}
      }
      try {
        final String cmd = p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'cmd.exe',
        );
        await windowsStartDetachedHidden(
          cmd,
          <String>['/c', 'start', '', url],
        );
        return true;
      } catch (_) {
        return false;
      }
    }
    if (Platform.isMacOS) {
      final String app = browser == 'Edge' ? 'Microsoft Edge' : 'Google Chrome';
      try {
        await Process.run('open', <String>['-a', app, url]);
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// Opens a URL in Chrome/Edge (or system default on Windows).
  Future<bool> openUrl(String url, {String browser = 'Chrome'}) async {
    if (Platform.isWindows) {
      final List<String> candidates = browser == 'Edge'
          ? <String>[
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
            ]
          : <String>[
              p.join(
                Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
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
      for (final String exe in candidates) {
        if (exe.isEmpty || !await File(exe).exists()) continue;
        try {
          await windowsStartDetachedHidden(exe, <String>[url]);
          return true;
        } catch (_) {}
      }
      try {
        final String cmd = p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'cmd.exe',
        );
        await windowsStartDetachedHidden(
          cmd,
          <String>['/c', 'start', '', url],
        );
        return true;
      } catch (_) {
        return false;
      }
    }
    if (Platform.isMacOS) {
      final String app = browser == 'Edge' ? 'Microsoft Edge' : 'Google Chrome';
      try {
        await Process.run('open', <String>['-a', app, url]);
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }
}

class BrowserDnsProfileStatus {
  const BrowserDnsProfileStatus({
    required this.browser,
    required this.profileName,
    required this.found,
    required this.secureDnsLikelyOn,
    required this.detail,
    this.mode,
  });

  final String browser;
  final String profileName;
  final bool found;
  final bool secureDnsLikelyOn;
  final String detail;
  final String? mode;
}

class _SecureDnsParse {
  const _SecureDnsParse({
    required this.likelyOn,
    required this.mode,
    required this.detail,
  });

  final bool likelyOn;
  final String mode;
  final String detail;
}
