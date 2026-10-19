/// Known root causes when Chrome/Edge bypass hosts/DNS blocking.
enum VpnBypassCause {
  ipv6Leak,
  dohBypass,
  quicBypass,
  routingOrDnsPriority,
  hostsNotApplied,
  chromiumSecureDns,
  secondaryDns,
  virtualAdapterPriority,
  tcp53Sink,
  uacShadowFailure,
  antivirusInterference,
  routerDnsHijack,
}

extension VpnBypassCauseLabels on VpnBypassCause {
  String get title {
    switch (this) {
      case VpnBypassCause.ipv6Leak:
        return 'IPv6 누수';
      case VpnBypassCause.dohBypass:
        return '보안 DNS(DoH) 우회';
      case VpnBypassCause.quicBypass:
        return 'QUIC(UDP 443) 우회';
      case VpnBypassCause.routingOrDnsPriority:
        return 'DNS/라우팅 우선순위';
      case VpnBypassCause.hostsNotApplied:
        return 'hosts 미적용';
      case VpnBypassCause.chromiumSecureDns:
        return 'Chrome/Edge 보안 DNS';
      case VpnBypassCause.secondaryDns:
        return '보조 DNS 우회';
      case VpnBypassCause.virtualAdapterPriority:
        return '가상 어댑터 우선순위';
      case VpnBypassCause.tcp53Sink:
        return 'TCP 53 미응답';
      case VpnBypassCause.uacShadowFailure:
        return 'UAC 적용 미반영';
      case VpnBypassCause.antivirusInterference:
        return 'Defender/백신 간섭';
      case VpnBypassCause.routerDnsHijack:
        return '포트 53 점유/납치';
    }
  }

  String get remedy {
    switch (this) {
      case VpnBypassCause.ipv6Leak:
        return '진단 → 지금 적용(UAC 예)으로 hosts에 IPv6(::) 줄을 넣거나, '
            'Windows 네트워크에서 IPv6를 끄세요. 차단 사이트 AAAA가 있으면 IPv4만 막아서는 뚫릴 수 있습니다.';
      case VpnBypassCause.dohBypass:
        return 'Chrome/Edge 설정에서 「보안 DNS」를 끄거나 「현재 서비스 제공업체」로 바꾸세요. '
            '또는 진단 → 지금 적용으로 Chromium 정책(DnsOverHttpsMode=off)을 설치하세요.';
      case VpnBypassCause.quicBypass:
        return 'Chrome에서 chrome://flags 의 QUIC/HTTP3를 끄거나, '
            '확장 프로그램 규칙이 켜져 있는지 확인하세요. UDP 443이 열리면 YouTube 등이 TCP 차단을 우회할 수 있습니다.';
      case VpnBypassCause.routingOrDnsPriority:
        return '진단 → 지금 적용으로 어댑터 DNS를 127.0.0.1(로컬 싱크홀)로 맞춥니다. '
            'Wi‑Fi가 다른 DNS(1.1.1.1 등)를 쓰면 hosts보다 먼저 조회될 수 있습니다.';
      case VpnBypassCause.hostsNotApplied:
        return '진단 화면에서 「지금 적용」→ UAC 「예」. '
            'Access denied가 로그에 있으면 관리자 권한이 거부된 상태입니다.';
      case VpnBypassCause.chromiumSecureDns:
        return '아래 「Chrome 보안 DNS 열기」로 끄거나, 앱이 설치한 managed policies.json을 확인하세요.';
      case VpnBypassCause.secondaryDns:
        return '「UAC 한 번에 적용」으로 어댑터 DNS를 127.0.0.1 단일로 고정합니다(보조 DNS 제거).';
      case VpnBypassCause.virtualAdapterPriority:
        return 'VPN·VM·WSL 가상 어댑터를 끄거나, 실제 Wi‑Fi/이더넷만 Up 상태로 두세요.';
      case VpnBypassCause.tcp53Sink:
        return '「지금 적용」→ UAC 「예」 — UDP+TCP 127.0.0.1:53 싱크홀을 함께 기동합니다.';
      case VpnBypassCause.uacShadowFailure:
        return 'UAC에서 「예」를 눌렀는지 확인하고, ProgramData\\SixVPNBlocker\\elevate_transcript.log 를 확인한 뒤 다시 적용하세요.';
      case VpnBypassCause.antivirusInterference:
        return 'Windows 보안 → 랜섬웨어 방지(제어된 폴더 액세스)에서 hosts/앱을 허용하거나, Focus Fense를 예외로 추가하세요.';
      case VpnBypassCause.routerDnsHijack:
        return '공유기가 53번 포트를 납치하면 로컬 싱크홀이 실패할 수 있습니다. UAC 적용 후에도 실패하면 공유기 DNS/가족 보호 설정을 확인하세요.';
    }
  }
}

/// One step in the 4-stage bypass diagnostic sequence.
final class VpnBypassDiagnosticStep {
  const VpnBypassDiagnosticStep({
    required this.id,
    required this.title,
    required this.issueDetected,
    required this.detail,
    this.cause,
    this.remedy,
  });

  final String id;
  final String title;
  final bool issueDetected;
  final String detail;
  final VpnBypassCause? cause;
  final String? remedy;

  bool get ok => !issueDetected;
}

/// Full report from [VpnBypassDiagnosticService.run].
final class VpnBypassDiagnosticReport {
  const VpnBypassDiagnosticReport({
    required this.probeHost,
    required this.steps,
    required this.detectedCauses,
    required this.summary,
    required this.elapsedMs,
    required this.blockLayerActive,
  });

  final String probeHost;
  final List<VpnBypassDiagnosticStep> steps;
  final List<VpnBypassCause> detectedCauses;
  final String summary;
  final int elapsedMs;
  final bool blockLayerActive;

  bool get hasIssues => detectedCauses.isNotEmpty;
}
