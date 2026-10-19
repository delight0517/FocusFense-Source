import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_block_user_notice_service.dart';
import 'app_logger.dart';
import 'extension_rules_builder.dart';
import 'own_kill_ledger.dart';
import 'windows_hidden_process.dart';
import 'chrome_dns_probe_service.dart';
import 'firefox_config_service.dart';

/// Runs end-to-end probes that match what a user would actually see in a
/// browser: does DNS return 0.0.0.0? Does an HTTP GET fail/timeout? Is the
/// browser process running (which means our pref changes haven't taken
/// effect yet)? Per-browser so we can say "Chrome ✅ / Firefox ❌ — restart".
final class BlockerTestService {
  BlockerTestService._();
  static final BlockerTestService instance = BlockerTestService._();

  static const List<String> kCanaryHosts = <String>[
    'www.naver.com',
    kDiagnosticBlockSentinelHost,
  ];

  Future<BlockerTestReport> run({List<String>? hosts}) async {
    final List<String> targets = hosts ?? kCanaryHosts;
    AppLogger.instance.info('blocker test starting, hosts=$targets');

    final List<BrowserTestResult> browsers = <BrowserTestResult>[];
    browsers.add(await systemResolverTest(targets));
    final List<BrowserDnsProfileStatus> chromium = await ChromeDnsProbeService
        .instance
        .probeInstalledBrowsers();
    if (chromium.isEmpty) {
      browsers.add(
        await chromiumBrowserTest(
          browserLabel: 'Chrome',
          hosts: targets,
          profile: const BrowserDnsProfileStatus(
            browser: 'Chrome',
            profileName: '-',
            found: false,
            secureDnsLikelyOn: false,
            detail: '설치 경로 없음',
          ),
        ),
      );
    } else {
      for (final BrowserDnsProfileStatus b in chromium) {
        browsers.add(
          await chromiumBrowserTest(
            browserLabel: b.browser,
            hosts: targets,
            profile: b,
          ),
        );
      }
    }
    browsers.add(await firefoxTest(targets));

    AppLogger.instance.info(
      'blocker test done: '
      '${browsers.map((BrowserTestResult b) => "${b.label}=${b.summary}").join(", ")}',
    );
    return BlockerTestReport(results: browsers);
  }

  /// Confirms system DNS itself returns 0.0.0.0 for blocked hosts. If this
  /// fails, the OS hosts file likely didn't get the managed block (or DNS
  /// cache hasn't refreshed yet).
  Future<BrowserTestResult> systemResolverTest(List<String> hosts) async {
    final List<HostProbe> probes = <HostProbe>[];
    for (final String h in hosts) {
      probes.add(await _systemDnsProbe(h));
    }
    final bool allBlocked = probes.every((HostProbe p) => p.blocked);
    final String failHint = Platform.isWindows
        ? 'UAC로 hosts 적용 후 잠시 기다리거나 "지금 적용"을 다시 누르세요. '
              'Windows는 DNS 캐시 때문에 바로 안 보일 수 있어요.'
        : '"다시 적용"을 눌러서 시스템 차단을 재적용하세요. 관리자 비밀번호 입력 필요.';
    return BrowserTestResult(
      label: Platform.isWindows ? '시스템 DNS (hosts)' : '시스템 DNS (/etc/hosts)',
      icon: '🖥️',
      isRunning: false,
      probes: probes,
      passed: allBlocked,
      summary: allBlocked ? '모두 0.0.0.0 — 정상' : '일부 통과 — 호스트 파일 미반영',
      hint: allBlocked ? null : failHint,
    );
  }

  /// Per Chromium browser: DNS probes + Secure DNS profile + HTTP curl path.
  Future<BrowserTestResult> chromiumBrowserTest({
    required String browserLabel,
    required List<String> hosts,
    required BrowserDnsProfileStatus profile,
  }) async {
    final bool running = await _isProcessRunning(
      browserLabel.toLowerCase().contains('edge') ? 'msedge' : 'Google Chrome',
    );
    final List<HostProbe> probes = <HostProbe>[];
    for (final String h in hosts) {
      final HostProbe dns = await _systemDnsProbe(h);
      probes.add(
        HostProbe(
          host: h,
          detail: 'DNS: ${dns.blocked ? dns.detail : dns.detail}',
          blocked: dns.blocked,
        ),
      );
    }
    for (final String h in hosts) {
      final HostProbe http = await _curlProbe(h, label: '$browserLabel HTTP');
      probes.add(
        HostProbe(
          host: h,
          detail: 'HTTP: ${http.detail}',
          blocked: http.blocked,
        ),
      );
    }
    final bool dnsOk = probes
        .where((HostProbe p) => p.detail.startsWith('DNS:'))
        .every((HostProbe p) => p.blocked);
    final bool httpOk = probes
        .where((HostProbe p) => p.detail.startsWith('HTTP:'))
        .every((HostProbe p) => p.blocked);
    final bool dohOn = profile.secureDnsLikelyOn;
    final bool passed = dnsOk && httpOk && !dohOn;
    final List<String> hints = <String>[];
    if (dohOn) {
      hints.add(
        '「보안 DNS」 켜짐 — 진단에서 끄거나 「현재 서비스 제공업체」. '
        'UAC 적용 시 policies.json으로 DoH OFF 잠금.',
      );
    }
    if (!dnsOk) {
      hints.add('시스템 DNS가 실제 IP — hosts 줄·싱크홀·「지금 적용」(UAC) 확인');
    }
    if (!httpOk) {
      hints.add('HTTP 통과 — DNS/hosts 미반영 또는 DoH·캐시 우회');
    }
    if (running && (!passed || dohOn)) {
      hints.add('$browserLabel 실행 중 — 종료 후 재시작하면 정책·확장이 잘 붙습니다');
    }
    hints.add('보안 DNS: ${profile.detail}');
    final String icon = browserLabel.toLowerCase().contains('edge')
        ? '🔷'
        : '🟢';
    return BrowserTestResult(
      label: browserLabel,
      icon: icon,
      isRunning: running,
      probes: probes,
      passed: passed,
      summary: passed
          ? 'DNS·HTTP 모두 차단'
          : (!dnsOk
                ? 'DNS 조회 실패(미차단)'
                : (dohOn ? '보안 DNS 우회 가능' : 'HTTP 통과(열림)')),
      hint: hints.join(' · '),
    );
  }

  /// Public wrapper for layered site probe UI.
  Future<HostProbe> systemProbe(String host) => _systemDnsProbe(host);

  /// Public wrapper for layered site probe UI.
  Future<HostProbe> httpProbe(String host) => _curlProbe(host);

  /// Firefox: the hard case. user.js only takes effect on NEXT LAUNCH, so
  /// if the process is running we already know DoH is still active. We also
  /// re-read each profile's prefs.js for the live trr.mode value.
  Future<BrowserTestResult> firefoxTest(List<String> hosts) async {
    final bool running = await _isProcessRunning('firefox');
    final List<FirefoxProfileStatus> profiles = await FirefoxConfigService
        .instance
        .probeProfiles();

    final List<HostProbe> probes = <HostProbe>[];
    for (final String h in hosts) {
      final HostProbe dns = await _systemDnsProbe(h);
      probes.add(
        HostProbe(host: h, detail: 'DNS: ${dns.detail}', blocked: dns.blocked),
      );
    }
    for (final String h in hosts) {
      final HostProbe http = await _curlProbe(h, label: 'Firefox HTTP');
      probes.add(
        HostProbe(
          host: h,
          detail: 'HTTP: ${http.detail}',
          blocked: http.blocked,
        ),
      );
    }

    final bool anyProfileMissingPolicy = profiles.any(
      (FirefoxProfileStatus s) => !s.dohLikelyOff,
    );
    final bool dnsOk = probes
        .where((HostProbe p) => p.detail.startsWith('DNS:'))
        .every((HostProbe p) => p.blocked);
    final bool httpOk = probes
        .where((HostProbe p) => p.detail.startsWith('HTTP:'))
        .every((HostProbe p) => p.blocked);
    final bool passed = dnsOk && httpOk && !anyProfileMissingPolicy && !running;

    final List<String> reasons = <String>[];
    if (running) {
      reasons.add('Firefox가 실행 중 — 종료 후 재시작 필요 (user.js는 다음 실행부터 적용)');
    }
    if (anyProfileMissingPolicy) {
      reasons.add('일부 프로필에서 DoH(trr.mode) 비활성 미확인');
    }
    if (!dnsOk) {
      reasons.add('시스템 DNS가 실제 IP — hosts·싱크홀 적용 필요');
    }
    if (!httpOk) {
      reasons.add('HTTP 통과 — DoH·네트워크 DNS 우회 가능');
    }
    if (profiles.isEmpty) {
      reasons.add('Firefox 프로필을 찾지 못함');
    }

    return BrowserTestResult(
      label: 'Firefox',
      icon: '🦊',
      isRunning: running,
      probes: probes,
      passed: passed,
      summary: passed
          ? 'DNS·HTTP 차단 · DoH OFF · 재시작됨'
          : (!dnsOk ? 'DNS 미차단' : (httpOk ? 'DoH/재시작 필요' : 'HTTP 통과')),
      hint: reasons.isEmpty ? null : reasons.join(' · '),
    );
  }

  Future<HostProbe> _systemDnsProbe(String host) async {
    if (Platform.isWindows) {
      return _windowsResolverProbe(host);
    }
    return _macDscacheProbe(host);
  }

  Future<HostProbe> _windowsResolverProbe(String host) async {
    try {
      final String quotedHost = host.replaceAll("'", "''");
      final String script =
          '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
          r"$ErrorActionPreference='SilentlyContinue'; "
          "Resolve-DnsName -Name '$quotedHost' -Type A | "
          r'Where-Object { $_.IPAddress } | '
          r'ForEach-Object { $_.IPAddress }';
      final ProcessResult r = await windowsRunHidden('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]).timeout(const Duration(seconds: 6));
      final String out = (r.stdout as String? ?? '').trim();
      final List<String> ips = out
          .split(RegExp(r'\s+'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      final bool blocked = ips.any(_isSinkholeAddress);
      if (blocked || ips.isNotEmpty) {
        return HostProbe(
          host: host,
          detail: blocked ? '0.0.0.0/루프백' : ips.take(4).join(', '),
          blocked: blocked,
        );
      }
    } catch (e) {
      AppLogger.instance.warn('windows Resolve-DnsName probe failed: $e');
    }

    try {
      final List<InternetAddress> list = await InternetAddress.lookup(host);
      final List<String> ips = list
          .map((InternetAddress a) => a.address)
          .toList();
      final bool blocked = ips.any(_isSinkholeAddress);
      final String detail = ips.isEmpty
          ? '응답 없음'
          : (blocked ? ips.join(', ') : ips.take(4).join(', '));
      return HostProbe(
        host: host,
        detail: blocked ? '0.0.0.0/루프백' : detail,
        blocked: blocked,
      );
    } catch (e) {
      return HostProbe(host: host, detail: '조회 실패: $e', blocked: false);
    }
  }

  Future<HostProbe> _macDscacheProbe(String host) async {
    try {
      final ProcessResult r = await Process.run('dscacheutil', <String>[
        '-q',
        'host',
        '-a',
        'name',
        host,
      ]);
      final String out = (r.stdout as String? ?? '');
      final bool blocked = out.contains('0.0.0.0');
      return HostProbe(
        host: host,
        detail: blocked ? '0.0.0.0' : '응답 있음',
        blocked: blocked,
      );
    } catch (e) {
      return HostProbe(host: host, detail: '오류: $e', blocked: false);
    }
  }

  bool _isSinkholeAddress(String address) =>
      address == '0.0.0.0' ||
      address == '127.0.0.1' ||
      address == '::' ||
      address == '::1';

  /// Uses curl with a tight timeout. If hosts file routes the host to
  /// 0.0.0.0, the connection refuses immediately — that's our "blocked"
  /// signal. A 200/3xx response means it slipped through.
  Future<HostProbe> _curlProbe(String host, {String label = ''}) async {
    final String nullSink = Platform.isWindows ? 'NUL' : '/dev/null';
    try {
      final Future<ProcessResult> run = Platform.isWindows
          ? windowsRunHidden('curl', <String>[
              '-sI',
              '--max-time',
              '3',
              '-o',
              nullSink,
              '-w',
              '%{http_code}|%{remote_ip}',
              'http://$host',
            ])
          : Process.run('curl', <String>[
              '-sI',
              '--max-time',
              '3',
              '-o',
              nullSink,
              '-w',
              '%{http_code}|%{remote_ip}',
              'http://$host',
            ]);
      final ProcessResult r = await run;
      final String out = (r.stdout as String? ?? '').trim();
      final List<String> parts = out.split('|');
      final String code = parts.isNotEmpty ? parts[0] : '';
      final String remoteIp = parts.length > 1 ? parts[1] : '';
      final int exit = r.exitCode;
      // curl exits non-zero AND http_code is 000 when the connection failed
      // (which is what we want — DNS gave 0.0.0.0, nothing to connect to).
      final bool blocked = exit != 0 || code == '000' || remoteIp == '0.0.0.0';
      final String detail = blocked
          ? 'HTTP $code (연결 실패 — 차단)'
          : 'HTTP $code from $remoteIp (통과)';
      return HostProbe(host: host, detail: detail, blocked: blocked);
    } catch (e) {
      return HostProbe(host: host, detail: '오류: $e', blocked: false);
    }
  }

  Future<bool> _isProcessRunning(String namePart) async {
    if (Platform.isWindows) {
      final String lower = namePart.toLowerCase();
      final String image = lower.contains('chrome')
          ? 'chrome.exe'
          : lower.contains('firefox')
          ? 'firefox.exe'
          : namePart.endsWith('.exe')
          ? namePart
          : '$namePart.exe';
      try {
        final ProcessResult r = await windowsRunHidden(
          p.join(
            Platform.environment['WINDIR'] ?? r'C:\Windows',
            'System32',
            'tasklist.exe',
          ),
          <String>['/FI', 'IMAGENAME eq $image', '/NH'],
        );
        final String out = (r.stdout as String? ?? '').trim().toLowerCase();
        if (out.isEmpty) return false;
        if (out.contains('정보:') && out.contains('일치')) return false;
        if (out.contains('no tasks')) return false;
        return out.contains(image.toLowerCase());
      } catch (_) {
        return false;
      }
    }
    try {
      final ProcessResult r = await Process.run('pgrep', <String>[
        '-i',
        '-f',
        namePart,
      ]);
      return r.exitCode == 0 && (r.stdout as String? ?? '').trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Asks Firefox to quit gracefully (macOS AppleScript) or taskkill (Windows).
  /// user.js / policies only apply on next launch.
  Future<bool> quitFirefox() async {
    AppLogger.instance.info('quitFirefox() called');
    if (Platform.isWindows) {
      const String reason = 'Firefox 차단 정책 적용 테스트 — 종료 후 재기동';
      try {
        OwnKillLedger.instance.stampImage(
          imageName: 'firefox.exe',
          reason: reason,
          reasonKey: 'blocker_test_firefox',
        );
        await Process.run('taskkill', <String>['/IM', 'firefox.exe', '/T']);
        AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
          browserOrAppDisplayName: 'Firefox',
          reasonKo: reason,
          debounceKey: 'blocker_test_firefox',
        );
      } catch (_) {
        /* best-effort */
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      final bool still = await _isProcessRunning('firefox');
      AppLogger.instance.info(
        'quitFirefox (Windows) done, stillRunning=$still',
      );
      return !still;
    }
    try {
      await Process.run('osascript', <String>[
        '-e',
        'tell application "Firefox" to quit',
      ]);
    } catch (_) {
      /* fall through to pkill */
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    try {
      await Process.run('pkill', <String>['-i', '-f', 'firefox']);
    } catch (_) {}
    final bool stillRunning = await _isProcessRunning('firefox');
    AppLogger.instance.info('quitFirefox done, stillRunning=$stillRunning');
    return !stillRunning;
  }
}

class BlockerTestReport {
  const BlockerTestReport({required this.results});
  final List<BrowserTestResult> results;
}

class BrowserTestResult {
  const BrowserTestResult({
    required this.label,
    required this.icon,
    required this.isRunning,
    required this.probes,
    required this.passed,
    required this.summary,
    this.hint,
  });
  final String label;
  final String icon;
  final bool isRunning;
  final List<HostProbe> probes;
  final bool passed;
  final String summary;
  final String? hint;
}

class HostProbe {
  const HostProbe({
    required this.host,
    required this.detail,
    required this.blocked,
  });
  final String host;
  final String detail;
  final bool blocked;
}
