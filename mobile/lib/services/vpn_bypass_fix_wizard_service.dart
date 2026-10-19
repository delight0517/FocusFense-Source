import 'dart:io';

import '../models/vpn_bypass_diagnostic_models.dart';
import 'block_sync_service.dart';
import 'chrome_dns_probe_service.dart';

/// One actionable item in the fix wizard.
final class VpnBypassFixAction {
  const VpnBypassFixAction({
    required this.label,
    required this.hint,
    required this.run,
    this.isPrimary = false,
  });

  final String label;
  final String hint;
  final Future<void> Function() run;
  final bool isPrimary;
}

/// Guided step derived from a diagnostic report.
final class VpnBypassFixWizardStep {
  const VpnBypassFixWizardStep({
    required this.order,
    required this.title,
    required this.body,
    required this.actions,
  });

  final int order;
  final String title;
  final String body;
  final List<VpnBypassFixAction> actions;
}

/// Builds step-by-step fix flows from [VpnBypassDiagnosticReport].
final class VpnBypassFixWizardService {
  VpnBypassFixWizardService._();
  static final VpnBypassFixWizardService instance = VpnBypassFixWizardService._();

  List<VpnBypassFixWizardStep> stepsFromReport(VpnBypassDiagnosticReport report) {
    final List<VpnBypassFixWizardStep> out = <VpnBypassFixWizardStep>[];
    int n = 1;

    if (report.detectedCauses.contains(VpnBypassCause.hostsNotApplied)) {
      out.add(_hostsStep(n++, report));
    }

    for (final VpnBypassCause c in report.detectedCauses) {
      switch (c) {
        case VpnBypassCause.chromiumSecureDns:
        case VpnBypassCause.dohBypass:
          if (!out.any((VpnBypassFixWizardStep s) => s.title.contains('보안 DNS'))) {
            out.add(_chromiumDnsStep(n++));
          }
        case VpnBypassCause.routingOrDnsPriority:
          out.add(_dnsLockStep(n++, report));
        case VpnBypassCause.ipv6Leak:
          out.add(_ipv6Step(n++));
        case VpnBypassCause.quicBypass:
          out.add(_quicStep(n++));
        case VpnBypassCause.secondaryDns:
        case VpnBypassCause.tcp53Sink:
        case VpnBypassCause.uacShadowFailure:
        case VpnBypassCause.routerDnsHijack:
          if (!out.any((VpnBypassFixWizardStep s) => s.title.contains('DNS 127'))) {
            out.add(_dnsLockStep(n++, report));
          }
        case VpnBypassCause.virtualAdapterPriority:
        case VpnBypassCause.antivirusInterference:
        case VpnBypassCause.hostsNotApplied:
          break;
      }
    }

    if (out.isEmpty) {
      out.add(
        VpnBypassFixWizardStep(
          order: 1,
          title: '확인 완료',
          body: '진단에서 자동 수정할 항목이 없습니다. '
              'Chrome/Edge를 완전히 종료한 뒤 ${report.probeHost} 를 다시 열어 보세요.',
          actions: <VpnBypassFixAction>[
            VpnBypassFixAction(
              label: 'Chrome 열기',
              hint: '주소창에 chrome://settings/security',
              isPrimary: true,
              run: () => ChromeDnsProbeService.instance.openSecureDnsSettings(browser: 'Chrome'),
            ),
          ],
        ),
      );
    }

    out.add(_verifyStep(n, report.probeHost));
    return out;
  }

  VpnBypassFixWizardStep _hostsStep(int order, VpnBypassDiagnosticReport report) {
    return VpnBypassFixWizardStep(
      order: order,
      title: '1. hosts 차단 켜기',
      body: '앱 규칙이 아직 Windows hosts 파일에 쓰이지 않았습니다. '
          'UAC 창에서 「예」를 눌러야 ${report.probeHost} 등이 막힙니다.',
      actions: <VpnBypassFixAction>[
        VpnBypassFixAction(
          label: 'UAC 적용 (hosts + DNS)',
          hint: '관리자 한 번만 승인',
          isPrimary: true,
          run: () async {
            await BlockSyncService.instance.applyNow();
          },
        ),
      ],
    );
  }

  VpnBypassFixWizardStep _chromiumDnsStep(int order) {
    return VpnBypassFixWizardStep(
      order: order,
      title: '보안 DNS(DoH) 끄기',
      body: 'Chrome/Edge가 「보안 DNS」를 쓰면 hosts·127.0.0.1 DNS를 건너뛸 수 있습니다.\n\n'
          '① 아래 버튼으로 브라우저 설정을 엽니다.\n'
          '② 「보안 DNS 사용」을 끄거나 「현재 서비스 제공업체」로 바꿉니다.\n'
          '③ 브라우저를 완전히 종료했다가 다시 실행합니다.\n\n'
          '또는 「정책으로 끄기」로 앱이 Chromium 정책을 설치할 수 있습니다.',
      actions: <VpnBypassFixAction>[
        VpnBypassFixAction(
          label: 'Chrome 설정 열기',
          hint: 'chrome://settings/security',
          isPrimary: true,
          run: () => ChromeDnsProbeService.instance.openSecureDnsSettings(browser: 'Chrome'),
        ),
        VpnBypassFixAction(
          label: 'Edge 설정 열기',
          hint: 'edge://settings/privacy',
          run: () => ChromeDnsProbeService.instance.openSecureDnsSettings(browser: 'Edge'),
        ),
        if (Platform.isWindows)
          VpnBypassFixAction(
            label: '정책으로 보안 DNS 끄기 (UAC)',
            hint: 'DnsOverHttpsMode=off',
            run: () async {
              await BlockSyncService.instance.applyNow();
            },
          ),
      ],
    );
  }

  VpnBypassFixWizardStep _dnsLockStep(int order, VpnBypassDiagnosticReport report) {
    return VpnBypassFixWizardStep(
      order: order,
      title: 'DNS 127.0.0.1 · 싱크홀',
      body: 'Wi‑Fi/이더넷 DNS가 공유기(192.168.x)이면 hosts보다 먼저 조회됩니다. '
          '앱은 127.0.0.1 로컬 DNS 싱크홀을 띄운 뒤 어댑터 DNS를 127.0.0.1로 맞춥니다.\n\n'
          'UAC 「예」 후 10초 정도 기다렸다가 ${report.probeHost} 를 Chrome에서 다시 열어 보세요.',
      actions: <VpnBypassFixAction>[
        VpnBypassFixAction(
          label: '지금 적용 (UAC · DNS 잠금)',
          hint: 'Dnscache 중지 → 싱크홀 → 127.0.0.1',
          isPrimary: true,
          run: () async {
            await BlockSyncService.instance.applyNow();
          },
        ),
      ],
    );
  }

  VpnBypassFixWizardStep _ipv6Step(int order) {
    return VpnBypassFixWizardStep(
      order: order,
      title: 'IPv6(::) 차단',
      body: '사이트에 AAAA(IPv6) 주소가 있으면 IPv4 hosts만으로는 뚫릴 수 있습니다. '
          '「지금 적용」이 hosts에 :: 줄을 넣습니다.',
      actions: <VpnBypassFixAction>[
        VpnBypassFixAction(
          label: 'UAC 적용 (IPv6 포함)',
          hint: 'hosts에 :: 줄 추가',
          isPrimary: true,
          run: () async {
            await BlockSyncService.instance.applyNow();
          },
        ),
      ],
    );
  }

  VpnBypassFixWizardStep _quicStep(int order) {
    return VpnBypassFixWizardStep(
      order: order,
      title: 'QUIC(UDP 443) 우회',
      body: 'TCP는 막혀도 QUIC이 열려 있으면 YouTube 등이 우회할 수 있습니다.\n\n'
          'Chrome 주소창: chrome://flags → 「QUIC」 검색 → Disabled → Relaunch',
      actions: <VpnBypassFixAction>[
        VpnBypassFixAction(
          label: 'Chrome flags 열기',
          hint: 'QUIC → Disabled',
          isPrimary: true,
          run: () => ChromeDnsProbeService.instance.openUrl('chrome://flags/#enable-quic'),
        ),
      ],
    );
  }

  VpnBypassFixWizardStep _verifyStep(int order, String host) {
    return VpnBypassFixWizardStep(
      order: order,
      title: '마지막: 확인',
      body: '① Chrome·Edge를 작업 관리자에서 모두 종료\n'
          '② 왼쪽 아래 「적용」이 초록이면 OK\n'
          '③ $host 접속 — 차단 페이지 또는 연결 실패가 정상',
      actions: <VpnBypassFixAction>[
        VpnBypassFixAction(
          label: 'Chrome 열기',
          hint: '새 창에서 테스트',
          run: () => ChromeDnsProbeService.instance.openUrl('https://$host/'),
        ),
      ],
    );
  }
}
