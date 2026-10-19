import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/vpn_bypass_diagnostic_models.dart';
import 'windows_dns_lock_service.dart';
import 'windows_hidden_process.dart';

/// Deep checks for the "hidden 10" bypass causes (Windows).
final class WindowsBypassHardeningService {
  WindowsBypassHardeningService._();
  static final WindowsBypassHardeningService instance =
      WindowsBypassHardeningService._();

  static const Duration _kTimeout = Duration(seconds: 8);

  /// Steps 5–10 (1–4 are covered by [VpnBypassDiagnosticService]).
  Future<List<VpnBypassDiagnosticStep>> runExtendedChecks({
    required bool blockActive,
  }) async {
    if (!Platform.isWindows) return <VpnBypassDiagnosticStep>[];
    return <VpnBypassDiagnosticStep>[
      await _stepSecondaryDns(blockActive: blockActive),
      await _stepVirtualAdapters(),
      await _stepTcp53Sink(),
      await _stepUacShadow(),
      await _stepDefenderInterference(),
      await _stepRouterDnsHijack(blockActive: blockActive),
      await _stepChromeDnsCacheHint(),
    ];
  }

  Future<VpnBypassDiagnosticStep> _stepSecondaryDns({
    required bool blockActive,
  }) async {
    final String? out = await _ps(r'''
$bad = @()
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V' } | ForEach-Object {
  $addrs = @(Get-DnsClientServerAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
  if ($addrs.Count -gt 1) { $bad += "$($_.Name): $($addrs -join ',')" }
  elseif ($addrs.Count -eq 1 -and $addrs[0] -eq '127.0.0.1' -and $addrs.Count -gt 1) { }
}
if ($bad.Count -eq 0) { 'ok' } else { $bad -join "`n" }
''');
    final bool hasSecondary =
        out != null && out.trim().isNotEmpty && out.trim() != 'ok';
    final bool issue = blockActive && hasSecondary;
    return VpnBypassDiagnosticStep(
      id: 'secondary_dns',
      title: '5. 보조 DNS(Secondary)',
      issueDetected: issue,
      detail: hasSecondary
          ? '여러 DNS 서버가 설정됨 — 로컬 싱크홀이 느리면 보조(8.8.8.8 등)로 우회할 수 있음:\n$out'
          : '활성 어댑터에 보조 DNS 없음 (또는 단일 127.0.0.1)',
      cause: issue ? VpnBypassCause.secondaryDns : null,
      remedy: issue ? VpnBypassCause.secondaryDns.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepVirtualAdapters() async {
    final String? out = await _ps(r'''
$phys = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V|VMware|VirtualBox|WSL|vEthernet' } | Select-Object -First 1
$physMetric = 9999
if ($phys) {
  $physMetric = (Get-NetIPInterface -InterfaceAlias $phys.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
}
$virt = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V|VMware|VirtualBox|WSL|vEthernet' } | Select-Object -First 3
$lines = @("physical=$($phys.Name) metric=$physMetric")
foreach ($v in $virt) {
  $m = (Get-NetIPInterface -InterfaceAlias $v.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
  $dns = (Get-DnsClientServerAddress -InterfaceAlias $v.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ','
  $lines += "virt=$($v.Name) metric=$m dns=$dns"
}
$lines -join "`n"
''');
    bool virtWins = false;
    if (out != null && out.contains('virt=')) {
      final RegExp metricRe = RegExp(r'virt=.* metric=(\d+)');
      final RegExp physRe = RegExp(r'physical=.* metric=(\d+)');
      final int? physM = int.tryParse(physRe.firstMatch(out)?.group(1) ?? '');
      for (final RegExpMatch m in metricRe.allMatches(out)) {
        final int? vm = int.tryParse(m.group(1) ?? '');
        if (physM != null && vm != null && vm < physM) {
          virtWins = true;
          break;
        }
      }
    }
    return VpnBypassDiagnosticStep(
      id: 'virtual_adapter',
      title: '6. 가상 어댑터 우선순위',
      issueDetected: virtWins,
      detail: out?.trim().isNotEmpty == true ? out!.trim() : '(어댑터 없음)',
      cause: virtWins ? VpnBypassCause.virtualAdapterPriority : null,
      remedy: virtWins ? VpnBypassCause.virtualAdapterPriority.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepTcp53Sink() async {
    final bool udpPid = await File(WindowsDnsLockService.dnsPidPath()).exists();
    final bool tcpPid =
        await File(WindowsDnsLockService.dnsTcpPidPath()).exists();
    File? tcpErr;
    final File errF = File(p.join(
      WindowsDnsLockService.programDataDir(),
      'dns_sink_tcp_error.log',
    ));
    if (await errF.exists()) tcpErr = errF;

    final bool issue = udpPid && !tcpPid;
    final StringBuffer buf = StringBuffer()
      ..writeln('UDP 53 싱크홀: ${udpPid ? "실행 중" : "미실행"}')
      ..writeln('TCP 53 싱크홀: ${tcpPid ? "실행 중" : "미실행"}');
    if (tcpErr != null) {
      final String e = (await tcpErr.readAsString()).trim();
      if (e.isNotEmpty) buf.writeln('TCP 오류: $e');
    }
    if (issue) {
      buf.writeln(
        'Windows가 TCP 53으로 질의할 때 응답이 없을 수 있습니다 — UAC 적용 시 TCP 싱크홀을 함께 띄웁니다.',
      );
    }

    return VpnBypassDiagnosticStep(
      id: 'tcp53',
      title: '8. TCP 53 싱크홀',
      issueDetected: issue,
      detail: buf.toString().trim(),
      cause: issue ? VpnBypassCause.tcp53Sink : null,
      remedy: issue ? VpnBypassCause.tcp53Sink.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepUacShadow() async {
    final File transcript = File(WindowsDnsLockService.elevateTranscriptPath());
    String detail = 'UAC 상승 로그 없음 — 아직 「지금 적용」을 안 했거나 transcript 미생성';
    bool issue = false;

    if (await transcript.exists()) {
      final String tail = await _readTail(transcript, 48);
      final bool sinkRan = tail.contains('[sixvpn] DNS sink running') ||
          tail.contains('DNS UDP sink OK');
      final bool sinkFail = tail.contains('DNS sink failed') ||
          tail.contains('DNS unchanged') ||
          tail.contains('DNS lock skip');
      final bool adapterSet = tail.contains('DNS set') &&
          tail.contains('127.0.0.1');
      issue = sinkFail && !adapterSet && !tail.contains('NRPT installed');
      detail = '최근 elevate transcript (요약):\n'
          '${tail.length > 900 ? '${tail.substring(tail.length - 900)}' : tail}\n'
          '싱크홀: ${sinkRan ? "기동됨" : "미기동/실패"} · 어댑터 127.0.0.1: ${adapterSet ? "적용 로그 있음" : "없음"}';
    }

    return VpnBypassDiagnosticStep(
      id: 'uac_shadow',
      title: '9. UAC 적용 검증',
      issueDetected: issue,
      detail: detail,
      cause: issue ? VpnBypassCause.uacShadowFailure : null,
      remedy: issue ? VpnBypassCause.uacShadowFailure.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepDefenderInterference() async {
    final String? out = await _ps(r'''
$lines = @()
try {
  $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
  if ($mp) { $lines += "Defender realtime=$($mp.RealTimeProtectionEnabled)" }
} catch {}
try {
  $cfa = (Get-MpPreference -ErrorAction SilentlyContinue).EnableControlledFolderAccess
  $lines += "ControlledFolderAccess=$cfa"
} catch {}
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Test-Path $hosts) {
  try {
    $acl = Get-Acl -LiteralPath $hosts | Select-Object -ExpandProperty Owner
    $lines += "hosts owner=$acl"
  } catch {}
}
if ($lines.Count -eq 0) { 'unknown' } else { $lines -join "`n" }
''');
    final bool cfaOn =
        out != null && out.toLowerCase().contains('controlledfolderaccess=1');
    return VpnBypassDiagnosticStep(
      id: 'defender',
      title: '5b. Defender/백신 간섭',
      issueDetected: cfaOn,
      detail: out?.trim().isNotEmpty == true ? out!.trim() : '상태 읽기 실패',
      cause: cfaOn ? VpnBypassCause.antivirusInterference : null,
      remedy: cfaOn ? VpnBypassCause.antivirusInterference.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepRouterDnsHijack({
    required bool blockActive,
  }) async {
    final String? out = await _ps(r'''
try {
  $u = New-Object System.Net.Sockets.UdpClient
  $u.Client.ReceiveTimeout = 1500
  $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback), 53
  $u.Client.Bind($ep)
  $u.Close()
  'loopback_bind=ok'
} catch {
  "loopback_bind=fail $($_.Exception.Message)"
}
''');
    final bool loopbackBindFail =
        out != null && out.contains('loopback_bind=fail');
    final bool issue = blockActive && loopbackBindFail;
    return VpnBypassDiagnosticStep(
      id: 'router_hijack',
      title: '10. 포트 53 / 공유기 납치',
      issueDetected: issue,
      detail: out?.trim() ?? '프로브 실패',
      cause: issue ? VpnBypassCause.routerDnsHijack : null,
      remedy: issue ? VpnBypassCause.routerDnsHijack.remedy : null,
    );
  }

  Future<VpnBypassDiagnosticStep> _stepChromeDnsCacheHint() async {
    return const VpnBypassDiagnosticStep(
      id: 'chrome_cache',
      title: '3b. Chrome 내부 DNS 캐시',
      issueDetected: false,
      detail: 'ipconfig /flushdns 는 OS 캐시만 비웁니다. Chrome은 '
          'chrome://net-internals/#dns 에서 「Clear host cache」가 필요할 수 있습니다.\n'
          'UAC 적용 후 아래 「Chrome DNS 캐시」 버튼으로 열 수 있습니다.',
      remedy: '진단 패널 → Chrome DNS 캐시 → Clear host cache → 브라우저 재시작',
    );
  }

  /// NRPT rules tagged by this app (Dnscache path when sink is down).
  Future<int> countNrptRules() async {
    final String? out = await _ps(
      "(@(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | "
      "Where-Object { \$_.Comment -eq '${WindowsDnsLockService.kNrptTag}' })).Count",
    );
    return int.tryParse(out?.trim() ?? '') ?? 0;
  }

  Future<bool> hasSecondaryDnsOnActiveAdapter() async {
    final String? out = await _ps(r'''
$bad = $false
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V' } | ForEach-Object {
  $n = @(Get-DnsClientServerAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses.Count
  if ($n -gt 1) { $bad = $true }
}
if ($bad) { 'yes' } else { 'no' }
''');
    return out?.trim().toLowerCase() == 'yes';
  }

  Future<String> _readTail(File f, int maxLines) async {
    try {
      final List<String> lines = await f.readAsLines();
      if (lines.length <= maxLines) return lines.join('\n');
      return lines.sublist(lines.length - maxLines).join('\n');
    } catch (_) {
      return '';
    }
  }

  Future<String?> _ps(String script) async {
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
      ).timeout(_kTimeout);
      if (r.exitCode != 0) return null;
      return '${r.stdout}'.trim();
    } catch (_) {
      return null;
    }
  }
}
