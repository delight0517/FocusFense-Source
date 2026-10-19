import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/vpn_bypass_diagnostic_models.dart';
import 'app_logger.dart';
import 'blocker_test_service.dart';
import 'chrome_dns_probe_service.dart';
import 'extension_rules_builder.dart';
import 'mac_system_block_service.dart';
import 'windows_bypass_hardening_service.dart';
import 'windows_dns_lock_service.dart';
import 'windows_hidden_process.dart';
import 'windows_system_block_service.dart';

/// In-app agent: detects why Chrome/Edge may bypass hosts/DNS blocking.
///
/// This app uses **hosts + 127.0.0.1 DNS sinkhole + browser extension**, not
/// Wintun. Step 4 therefore checks DNS adapter priority, not VPN tunnel metric.
final class VpnBypassDiagnosticService {
  VpnBypassDiagnosticService._();
  static final VpnBypassDiagnosticService instance = VpnBypassDiagnosticService._();

  static const Duration _kStepTimeout = Duration(seconds: 8);

  static const List<String> _dohProbeHosts = <String>[
    '1.1.1.1',
    '8.8.8.8',
    '9.9.9.9',
  ];

  Future<VpnBypassDiagnosticReport> run({String? testHost}) async {
    final Stopwatch sw = Stopwatch()..start();
    final String host = MacSystemBlockService.canonicalHost(
      testHost?.trim().isNotEmpty == true
          ? testHost!
          : kDiagnosticBlockSentinelHost,
    );

    final bool blockActive = await _blockLayerActive();
    final List<VpnBypassDiagnosticStep> steps = <VpnBypassDiagnosticStep>[];
    final List<VpnBypassCause> causes = <VpnBypassCause>[];

    if (!blockActive) {
      steps.add(
        VpnBypassDiagnosticStep(
          id: 'prereq_hosts',
          title: '0. 차단 레이어 활성',
          issueDetected: true,
          detail: 'hosts 마커 블록이 없습니다. 이후 단계는 “차단이 켜진 상태”를 가정합니다.',
          cause: VpnBypassCause.hostsNotApplied,
          remedy: VpnBypassCause.hostsNotApplied.remedy,
        ),
      );
      causes.add(VpnBypassCause.hostsNotApplied);
    } else {
      steps.add(
        const VpnBypassDiagnosticStep(
          id: 'prereq_hosts',
          title: '0. 차단 레이어 활성',
          issueDetected: false,
          detail: 'hosts 관리 구간이 적용되어 있습니다.',
        ),
      );
    }

    steps.add(await _stepIpv6(host, blockActive: blockActive));
    steps.add(await _stepDoh(blockActive: blockActive));
    steps.add(await _stepQuic(host, blockActive: blockActive));
    if (Platform.isWindows) {
      steps.add(await _stepWindowsDnsRouting(blockActive: blockActive));
      steps.addAll(
        await WindowsBypassHardeningService.instance.runExtendedChecks(
          blockActive: blockActive,
        ),
      );
    } else if (Platform.isMacOS) {
      steps.add(await _stepMacRoutingHint(blockActive: blockActive));
    } else {
      steps.add(
        const VpnBypassDiagnosticStep(
          id: 'routing',
          title: '4. DNS/라우팅',
          issueDetected: false,
          detail: '이 플랫폼에서는 어댑터 메트릭 검사를 건너뜁니다.',
        ),
      );
    }

    for (final VpnBypassDiagnosticStep s in steps) {
      if (s.issueDetected && s.cause != null && !causes.contains(s.cause)) {
        causes.add(s.cause!);
      }
      AppLogger.instance.info(
        '[VpnBypassDiag] ${s.id} issue=${s.issueDetected} — ${s.detail}',
      );
    }

    sw.stop();
    final String summary = causes.isEmpty
        ? 'Chrome/Edge 우회로 보이는 흔한 원인을 찾지 못했습니다. '
            '확장 프로그램 로드·브라우저 완전 종료도 확인하세요.'
        : '감지됨: ${causes.map((VpnBypassCause c) => c.title).join(', ')}';

    return VpnBypassDiagnosticReport(
      probeHost: host,
      steps: steps,
      detectedCauses: causes,
      summary: summary,
      elapsedMs: sw.elapsedMilliseconds,
      blockLayerActive: blockActive,
    );
  }

  Future<bool> _blockLayerActive() async {
    if (Platform.isMacOS) {
      return MacSystemBlockService.instance.isActive();
    }
    if (Platform.isWindows) {
      return WindowsSystemBlockService.instance.isActive();
    }
    return false;
  }

  Future<VpnBypassDiagnosticStep> _stepIpv6(
    String host, {
    required bool blockActive,
  }) async {
    bool hasAaaa = false;
    String aaaaDetail = 'AAAA 조회 없음';
    try {
      final List<InternetAddress> v6 = await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv6,
      ).timeout(_kStepTimeout);
      hasAaaa = v6.isNotEmpty;
      aaaaDetail = hasAaaa
          ? 'IPv6 ${v6.first.address} — 브라우저가 IPv4 hosts를 건너뛸 수 있음'
          : 'IPv6 레코드 없음';
    } catch (e) {
      aaaaDetail = 'AAAA 조회: $e';
    }

    bool hostsHasV6 = false;
    if (blockActive) {
      String? hosts;
      if (Platform.isWindows) {
        hosts = await WindowsSystemBlockService.tryReadSystemHostsNormalized();
      } else if (Platform.isMacOS) {
        try {
          hosts = await File('/etc/hosts').readAsString();
        } catch (_) {
          hosts = null;
        }
      }
      if (hosts != null) {
        hostsHasV6 = hosts.contains('::') &&
            (hosts.contains(' $host') || hosts.contains('::$host'));
      }
    }

    bool ipv6ConnectOk = false;
    if (hasAaaa) {
      ipv6ConnectOk = await _tryIpv6Connect(host, 443);
    }

    final bool issue = (hasAaaa && blockActive && (!hostsHasV6 || ipv6ConnectOk));
    String detail = '$aaaaDetail';
    if (blockActive) {
      detail += hostsHasV6 ? ' · hosts에 :: 줄 있음' : ' · hosts에 :: 줄 없음';
      if (ipv6ConnectOk) detail += ' · IPv6:443 연결 성공(누수 가능)';
    }

    return VpnBypassDiagnosticStep(
      id: 'ipv6',
      title: '1. IPv6 누수',
      issueDetected: issue,
      detail: detail,
      cause: issue ? VpnBypassCause.ipv6Leak : null,
      remedy: issue ? VpnBypassCause.ipv6Leak.remedy : null,
    );
  }

  Future<bool> _tryIpv6Connect(String host, int port) async {
    try {
      final List<InternetAddress> addrs = await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv6,
      ).timeout(_kStepTimeout);
      for (final InternetAddress a in addrs) {
        try {
          final Socket s = await Socket.connect(
            a,
            port,
            timeout: const Duration(seconds: 2),
          );
          await s.close();
          return true;
        } catch (_) {/* next */}
      }
    } catch (_) {}
    return false;
  }

  Future<VpnBypassDiagnosticStep> _stepDoh({required bool blockActive}) async {
    final List<String> parts = <String>[];
    bool chromiumOn = false;
    try {
      final List<BrowserDnsProfileStatus> browsers =
          await ChromeDnsProbeService.instance.probeInstalledBrowsers();
      for (final BrowserDnsProfileStatus b in browsers) {
        parts.add('${b.browser}: ${b.detail}');
        if (b.secureDnsLikelyOn) chromiumOn = true;
      }
    } catch (e) {
      parts.add('Chromium prefs 읽기 실패: $e');
    }

    int dohReachable = 0;
    for (final String ip in _dohProbeHosts) {
      if (await _tcpReachable(ip, 443)) dohReachable++;
    }
    parts.add('DoH 후보 IP:443 연결 가능 $dohReachable/${_dohProbeHosts.length}');

    if (Platform.isWindows && blockActive) {
      final bool loopbackDns = await _windowsUsesLoopbackDns();
      parts.add(
        loopbackDns
            ? '참고: 시스템 DNS 127.0.0.1 — 4단계와 일치'
            : '참고: Chromium 보안 DNS는 꺼져 있음. 라우터 DNS 우회는 「4. DNS 우선순위」에서 조치',
      );
    }

    final bool issue = chromiumOn;

    return VpnBypassDiagnosticStep(
      id: 'doh',
      title: '2. 보안 DNS(DoH)',
      issueDetected: issue,
      detail: parts.join('\n'),
      cause: issue ? VpnBypassCause.chromiumSecureDns : null,
      remedy: issue ? VpnBypassCause.chromiumSecureDns.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepQuic(
    String host, {
    required bool blockActive,
  }) async {
    final HostProbe tcp = await BlockerTestService.instance.httpProbe(host);
    final bool udpOk = Platform.isWindows
        ? await _windowsUdpReachable(host, 443)
        : false;

    final bool tcpBlocked = tcp.blocked;
    final bool issue =
        blockActive && udpOk && (!tcpBlocked || tcp.detail.contains('연결'));

    final String detail = 'TCP(HTTP): ${tcp.detail}${Platform.isWindows ? '\nUDP 443: ${udpOk ? "도달 가능 — QUIC 우회 의심" : "도달 불가 또는 차단됨"}' : '\nUDP 검사는 Windows에서만 수행'}';

    return VpnBypassDiagnosticStep(
      id: 'quic',
      title: '3. QUIC(UDP 443)',
      issueDetected: issue,
      detail: detail,
      cause: issue ? VpnBypassCause.quicBypass : null,
      remedy: issue ? VpnBypassCause.quicBypass.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepWindowsDnsRouting({
    required bool blockActive,
  }) async {
    final String? ps = await _runPowerShell(r'''
$active = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V' } | Select-Object -First 4
$lines = @()
foreach ($a in $active) {
  $m = (Get-NetIPInterface -InterfaceAlias $a.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
  $dns = (Get-DnsClientServerAddress -InterfaceAlias $a.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ','
  $lines += "$($a.Name)|metric=$m|dns=$dns"
}
$lines -join "`n"
''');
    final bool loopback = await _windowsUsesLoopbackDns();
    final bool sinkScript = await File(WindowsDnsLockService.dnsScriptPath()).exists();
    final bool sinkPid = await File(WindowsDnsLockService.dnsPidPath()).exists();
    final bool tcpPid =
        await File(WindowsDnsLockService.dnsTcpPidPath()).exists();
    final int nrptCount =
        await WindowsBypassHardeningService.instance.countNrptRules();

    final StringBuffer buf = StringBuffer()
      ..writeln(ps?.trim().isNotEmpty == true ? ps!.trim() : '(어댑터 정보 없음)')
      ..writeln('127.0.0.1 DNS: ${loopback ? "예" : "아니오"}')
      ..writeln(
        'DNS 싱크홀: UDP ${sinkPid ? "실행" : "미실행"} · TCP ${tcpPid ? "실행" : "미실행"} · NRPT 규칙 $nrptCount개',
      );
    if (sinkScript && !sinkPid) {
      final File errF = File(p.join(WindowsDnsLockService.programDataDir(), 'dns_sink_error.log'));
      if (await errF.exists()) {
        final String err = (await errF.readAsString()).trim();
        if (err.isNotEmpty) {
          buf.writeln('바인드 오류: ${err.length > 200 ? '${err.substring(0, 200)}…' : err}');
        }
      }
      buf.writeln(
        '원인 후보: Windows DNS Client(Dnscache)가 53번 포트 점유 — '
        '「이 결과 해결」→ UAC 「예」 시 Dnscache 중지 후 127.0.0.1 싱크홀을 띄웁니다.',
      );
    }

    final bool dnsPathOk = sinkPid || nrptCount > 0;
    final bool issue = blockActive && (!dnsPathOk || (!loopback && sinkPid));
    return VpnBypassDiagnosticStep(
      id: 'routing',
      title: '4. DNS 우선순위(어댑터)',
      issueDetected: issue,
      detail: buf.toString(),
      cause: issue ? VpnBypassCause.routingOrDnsPriority : null,
      remedy: issue ? VpnBypassCause.routingOrDnsPriority.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepMacRoutingHint({
    required bool blockActive,
  }) async {
    return VpnBypassDiagnosticStep(
      id: 'routing',
      title: '4. DNS/라우팅',
      issueDetected: false,
      detail: blockActive
          ? 'macOS는 /etc/hosts + dscacheutil 프로브를 사용합니다. '
              'Wi‑Fi 프라이빗 릴레이(Apple iCloud+)가 켜져 있으면 DNS가 우회될 수 있습니다.'
          : 'hosts 미적용 — 먼저 시스템 차단을 켜세요.',
    );
  }

  Future<bool> _tcpReachable(String host, int port) async {
    try {
      final Socket s = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _windowsUdpReachable(String host, int port) async {
    final String? out = await _runPowerShell(
      "Test-NetConnection -ComputerName '$host' -Port $port -Udp -WarningAction SilentlyContinue | Select-Object -ExpandProperty UdpTestSucceeded",
    );
    return out?.trim().toLowerCase() == 'true';
  }

  Future<bool> _windowsUsesLoopbackDns() async {
    final String? out = await _runPowerShell(r'''
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses -contains '127.0.0.1' } | Select-Object -First 1 -ExpandProperty InterfaceAlias
''');
    return out != null && out.trim().isNotEmpty;
  }

  Future<String?> _runPowerShell(String script) async {
    if (!Platform.isWindows) return null;
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String psExe = p.join(
        windir,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final ProcessResult r = await windowsRunHidden(
        psExe,
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-Command',
          script,
        ],
      ).timeout(_kStepTimeout);
      if (r.exitCode != 0) {
        return '${r.stderr}'.trim().isEmpty ? null : '${r.stderr}'.trim();
      }
      return '${r.stdout}'.trim();
    } on TimeoutException {
      return 'timeout';
    } catch (e) {
      return 'error: $e';
    }
  }
}
