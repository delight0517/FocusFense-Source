import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/apply_activation_report.dart';
import 'browser_one_tap_service.dart';
import 'block_probe_service.dart';
import 'block_sync_service.dart';
import 'blocker_test_service.dart';
import 'chrome_dns_probe_service.dart';
import 'chromium_policy_service.dart';
import 'mac_system_block_service.dart';
import 'windows_bypass_hardening_service.dart';
import 'windows_dns_lock_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_hidden_process.dart';
import 'windows_hkcu_policy_service.dart';
import 'windows_chrome_easy_block_service.dart';
import 'windows_system_block_service.dart';
import 'windows_uac_apply_session.dart';
import 'youtube_video_block_resolver.dart';
import 'protected_browser_realtime_guard_service.dart';

/// Post-apply verification for Windows (non-elevated reads where possible).
final class WindowsApplyStatusService {
  WindowsApplyStatusService._();
  static final WindowsApplyStatusService instance =
      WindowsApplyStatusService._();

  /// UAC apply + post-check (use from diagnostics / agent).
  ///
  /// Phase 1 (fast, no UAC): HKCU URLBlocklist · PAC · 확장 규칙.
  /// Phase 1b: 보호 Chrome 자동 실행 (일반 chrome.exe 종료).
  /// Phase 2: UAC hosts · DNS. Use [easyMode] only for Chrome-only handoff.
  Future<ApplyActivationReport> applyAndVerify({
    String? verifyHost,
    void Function(String phaseLabel)? onPhase,
    bool easyMode = false,
  }) async {
    if (!Platform.isWindows) {
      return const ApplyActivationReport(
        success: false,
        steps: <ApplyActivationStep>[],
        summary: 'Windows 전용',
      );
    }
    WindowsUacApplySession.instance.resetSession();
    onPhase?.call(
      easyMode
          ? '1/2 Chrome 차단 규칙 적용 중 (UAC 없음)…'
          : '1/3 Chrome 차단 규칙 적용 중 (UAC 없음)…',
    );
    final WindowsBrowserLayersPrep prep = await WindowsSystemBlockService
        .instance
        .prepareBrowserLayers();
    if (WindowsUacApplySession.instance.cancelRequested) {
      return _cancelledReport(await collect(verifyHost: verifyHost));
    }

    onPhase?.call('Chrome 보호 모드로 자동 전환 중… (일반 Chrome 종료)');
    // 60s ceiling: this phase used to have no timeout at all and could hang
    // indefinitely (observed: 6+ minutes stuck here with no UAC dialog ever
    // appearing — confirmed on this machine to correlate with AV/EDR
    // interference). A stuck phase here must not block the rest of
    // applyAndVerify (hosts/DNS still needs to run) — log and move on.
    try {
      await ProtectedBrowserRealtimeGuardService.instance
          .syncScriptOnly()
          .timeout(const Duration(seconds: 20));
      await WindowsChromeEasyBlockService.instance
          .ensureChromeBlocksYoutube(reason: 'apply_and_verify', force: true)
          .timeout(const Duration(seconds: 40));
    } on TimeoutException {
      // Non-fatal — Phase 2 (hosts/DNS) below still gives full protection
      // for every browser regardless of whether Chrome's own protected-mode
      // relaunch finished.
    }

    if (WindowsUacApplySession.instance.cancelRequested) {
      return _cancelledReport(await collect(verifyHost: verifyHost));
    }

    if (easyMode) {
      return collect(
        verifyHost: verifyHost,
        hostsApplyAttempted: false,
        easyChromeApplied: true,
      );
    }

    onPhase?.call('3/3 hosts·DNS — UAC 창에서 「예」를 눌러 주세요…');
    final MacBlockResult block = await WindowsSystemBlockService.instance
        .applyElevatedHosts(
          prep.managedPayload,
          hkcu: prep.hkcu,
          emergency: prep.emergency,
        );
    BlockSyncService.instance.lastResult = block;
    if (block.status == MacBlockStatus.success) {
      BlockSyncService.instance.hostsApplyPending.value = false;
    }
    if (block.status == MacBlockStatus.cancelled) {
      final ApplyActivationReport partial = await collect(
        verifyHost: verifyHost,
        hostsApplyAttempted: false,
      );
      if (partial.success) return partial;
      return const ApplyActivationReport(
        success: false,
        steps: <ApplyActivationStep>[
          ApplyActivationStep(
            id: 'uac',
            label: 'UAC',
            ok: false,
            detail: '사용자가 취소함',
          ),
        ],
        summary: 'UAC를 취소했습니다. 브라우저 보호는 이미 켜져 있을 수 있습니다 — 아래 결과를 확인하세요.',
      );
    }
    if (block.status != MacBlockStatus.success) {
      final ApplyActivationReport partial = await collect(
        verifyHost: verifyHost,
        hostsApplyAttempted: true,
      );
      if (partial.success) return partial;
      return ApplyActivationReport(
        success: false,
        steps: partial.steps.isNotEmpty
            ? partial.steps
            : <ApplyActivationStep>[
                ApplyActivationStep(
                  id: 'apply',
                  label: 'hosts 적용',
                  ok: false,
                  detail: block.message ?? block.status.name,
                ),
              ],
        summary: partial.summary.isNotEmpty
            ? partial.summary
            : '적용 실패: ${block.message ?? block.status.name}',
      );
    }
    return collect(verifyHost: verifyHost, hostsApplyAttempted: true);
  }

  ApplyActivationReport _cancelledReport(ApplyActivationReport partial) {
    return ApplyActivationReport(
      success: partial.success,
      steps: <ApplyActivationStep>[
        const ApplyActivationStep(
          id: 'uac',
          label: 'UAC / hosts',
          ok: false,
          detail: '사용자가 취소함',
        ),
        ...partial.steps,
      ],
      summary:
          '적용을 취소했습니다. 1단계(브라우저 HKCU 정책)는 이미 반영되었을 수 있습니다 — '
          'Chrome을 완전히 종료한 뒤 다시 열고 chrome://policy → Reload policies를 눌러 보세요.',
    );
  }

  Future<ApplyActivationReport> collect({
    String? verifyHost,
    bool hostsApplyAttempted = false,
    bool easyChromeApplied = false,
  }) async {
    if (!Platform.isWindows) {
      return const ApplyActivationReport(
        success: false,
        steps: <ApplyActivationStep>[],
        summary: 'Windows 전용',
      );
    }

    final List<ApplyActivationStep> steps = <ApplyActivationStep>[];

    final BrowserOneTapResult? chromeHandoff =
        WindowsChromeEasyBlockService.instance.lastResult;
    if (easyChromeApplied || chromeHandoff != null) {
      final BrowserOneTapResult h =
          chromeHandoff ??
          const BrowserOneTapResult(
            ok: false,
            launched: false,
            userMessage: 'Chrome 전환 정보 없음',
          );
      steps.add(
        ApplyActivationStep(
          id: 'chrome_handoff',
          label: 'Chrome 자동 전환 (보호 모드)',
          ok: h.ok,
          detail: h.launched
              ? h.userMessage
              : '${h.userMessage} — 앱 상단 「보호 Chrome」을 눌러 주세요.',
        ),
      );
    }

    final ExtensionPolicyVerifyResult ext =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final bool browserProtectionOk = ext.protectionOk;
    steps.add(
      ApplyActivationStep(
        id: 'browser_protection',
        label: '브라우저 보호 (Chrome·Edge·Firefox)',
        ok: browserProtectionOk,
        detail: browserProtectionOk
            ? (ext.chromeLoadExtensionFallbackOk
                  ? '시스템 바로가기 + 확장 연결됨 — 키워드·도메인 규칙 적용 가능'
                  : '정책/확장 설치 확인됨')
            : '설정 → 쉬운 설치에서 Firefox·Chrome 보호를 먼저 완료하세요.',
      ),
    );

    final String? hostsText =
        await WindowsSystemBlockService.tryReadSystemHostsNormalized();
    final bool markers =
        hostsText != null &&
        hostsText.contains(MacSystemBlockService.kMarkerStart) &&
        hostsText.contains(MacSystemBlockService.kMarkerEnd);
    steps.add(
      ApplyActivationStep(
        id: 'hosts_marker',
        label: 'hosts 관리 구간',
        ok: markers,
        detail: markers ? '마커 블록 적용됨' : '마커 없음 — UAC 취소 또는 쓰기 실패',
      ),
    );

    final String host = verifyHost != null
        ? MacSystemBlockService.canonicalHost(verifyHost)
        : '';
    if (host.isNotEmpty && hostsText != null) {
      final bool listed = BlockProbeService.hostsTextContains(hostsText, host);
      steps.add(
        ApplyActivationStep(
          id: 'hosts_host',
          label: 'hosts에 $host',
          ok: listed,
          detail: listed
              ? '0.0.0.0 줄 확인'
              : '이 도메인 줄 없음 — 활성 스케줄·도메인 목록 확인 후 다시 적용',
        ),
      );
    }

    final bool sinkPid = await File(
      WindowsDnsLockService.dnsPidPath(),
    ).exists();
    final bool tcpPid = await File(
      WindowsDnsLockService.dnsTcpPidPath(),
    ).exists();
    final int nrptCount = await WindowsBypassHardeningService.instance
        .countNrptRules();
    String sinkDetail = sinkPid
        ? '127.0.0.1:53 UDP 싱크홀 실행 중${tcpPid ? ' · TCP OK' : ' · TCP 미실행'}'
        : (nrptCount > 0 ? 'UDP 미실행 — NRPT $nrptCount개 (Dnscache 경로)' : '미실행');
    if (!sinkPid) {
      final File err = File(
        p.join(WindowsDnsLockService.programDataDir(), 'dns_sink_error.log'),
      );
      if (await err.exists()) {
        final String e = (await err.readAsString()).trim();
        if (e.isNotEmpty) {
          sinkDetail =
              '바인드 실패: ${e.length > 120 ? '${e.substring(0, 120)}…' : e}';
        }
      } else {
        sinkDetail = 'PID 없음 — 포트 53 점유 또는 Dnscache 중지 실패 가능';
      }
    }
    steps.add(
      ApplyActivationStep(
        id: 'dns_sink',
        label: '로컬 DNS 싱크홀',
        ok: sinkPid || nrptCount > 0,
        detail: sinkDetail,
      ),
    );

    if (sinkPid) {
      steps.add(
        ApplyActivationStep(
          id: 'dns_tcp53',
          label: 'TCP 53 싱크홀',
          ok: tcpPid,
          detail: tcpPid ? '127.0.0.1:53 TCP 리스닝' : 'TCP 미실행 — UAC 재적용',
        ),
      );
    }

    final bool secondaryDns = await WindowsBypassHardeningService.instance
        .hasSecondaryDnsOnActiveAdapter();
    steps.add(
      ApplyActivationStep(
        id: 'secondary_dns',
        label: '보조 DNS 없음',
        ok: !secondaryDns,
        detail: secondaryDns
            ? '어댑터에 DNS가 2개 이상 — UAC 재적용으로 127.0.0.1 단일 고정'
            : '보조 DNS 없음',
      ),
    );

    final bool loopbackDns = await _adapterUsesLoopbackDns();
    steps.add(
      ApplyActivationStep(
        id: 'adapter_dns',
        label: '어댑터 DNS → 127.0.0.1',
        ok: loopbackDns,
        detail: loopbackDns
            ? '활성 어댑터가 로컬 싱크홀 사용'
            : (sinkPid
                  ? '일부 어댑터가 여전히 공유기 DNS — 싱크홀만으로도 동작 가능'
                  : '공유기 DNS(192.168.x.x) 우선 — 싱크홀 미동작 시 hosts만으로 제한적'),
      ),
    );

    final EmergencyBlockResult emergency = await WindowsEmergencyBlockService
        .instance
        .readStatus();
    steps.add(
      ApplyActivationStep(
        id: 'pac_block',
        label: 'PAC 비상 차단 (관리자 없음)',
        ok: emergency.pacApplied,
        detail: emergency.pacApplied
            ? '인터넷 설정 PAC → ${emergency.pacPath}'
            : '미적용 — 레지스트리 거부 시 BAT 사용',
      ),
    );
    steps.add(
      ApplyActivationStep(
        id: 'extension_rules',
        label: '브라우저 확장 규칙',
        ok: emergency.extensionRulesOk,
        detail: emergency.extensionRulesOk
            ? '${emergency.extensionHostCount}개 도메인 동기화'
            : '확장 미연동 — Chrome에서 확장 켜기',
      ),
    );
    if (emergency.adminBatPath != null) {
      steps.add(
        ApplyActivationStep(
          id: 'admin_bat',
          label: 'hosts 관리자 BAT',
          ok: true,
          detail: '바탕화면: ${emergency.adminBatPath}',
        ),
      );
    }

    final bool hkcuPolicy = await WindowsHkcuPolicyService.instance.isActive();
    final bool programFilesPolicy =
        await _programFilesChromiumPolicyInstalled();
    final bool chromiumPolicy = hkcuPolicy || programFilesPolicy;
    steps.add(
      ApplyActivationStep(
        id: 'chromium_policy',
        label: 'Chrome·Edge 정책 (DoH OFF)',
        ok: chromiumPolicy,
        detail: chromiumPolicy
            ? (hkcuPolicy
                  ? 'HKCU URLBlocklist 적용됨 (관리자 없음)${programFilesPolicy ? ' + Program Files 정책' : ''}'
                  : 'policies\\managed\\policies.json 설치됨')
            : '미설치 — 「지금 적용」 UAC 「예」 또는 chrome://policy Reload',
      ),
    );

    for (final String vid in const <String>[
      'wCrc7vy_Tmk',
      'lDRT5e6JsY4',
      'so-Rv8RlCUc',
    ]) {
      try {
        final YoutubeBlockCheckResult yt = await YoutubeVideoBlockResolver
            .instance
            .checkVideo(vid);
        final List<String> patterns =
            await ChromiumPolicyService.activeBlocklistPatterns();
        final bool inBlocklist = patterns.any(
          (String pat) => pat.toLowerCase().contains(vid.toLowerCase()),
        );
        steps.add(
          ApplyActivationStep(
            id: 'yt_$vid',
            label: 'YouTube watch?v=$vid',
            ok: yt.blocked || inBlocklist,
            detail: yt.blocked
                ? '규칙 매칭: ${yt.matched ?? yt.rule ?? yt.channelHandle ?? "채널"}'
                : (inBlocklist
                      ? 'URLBlocklist 패턴 등록됨 — Chrome 재시작 + Reload policies'
                      : '차단 규칙 없음 — 스케줄에 채널/영상 추가 후 다시 적용'),
          ),
        );
      } catch (_) {
        /* best-effort */
      }
    }

    final bool ffPolicy = await File(
      p.join(
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
        'Mozilla Firefox',
        'distribution',
        'policies.json',
      ),
    ).exists();
    steps.add(
      ApplyActivationStep(
        id: 'firefox_policy',
        label: 'Firefox 정책 (DoH OFF)',
        ok: ffPolicy,
        detail: ffPolicy
            ? 'distribution\\policies.json'
            : 'Firefox 미설치 또는 정책 미복사',
      ),
    );

    if (host.isNotEmpty) {
      final HostProbe dns = await BlockerTestService.instance.systemProbe(host);
      steps.add(
        ApplyActivationStep(
          id: 'lookup',
          label: '시스템 DNS 조회 ($host)',
          ok: dns.blocked,
          detail: dns.detail,
        ),
      );
      if (!dns.blocked) {
        try {
          final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
          await windowsRunHidden(
            p.join(windir, 'System32', 'ipconfig.exe'),
            const <String>['/flushdns'],
          );
          final HostProbe again = await BlockerTestService.instance.systemProbe(
            host,
          );
          steps.add(
            ApplyActivationStep(
              id: 'lookup_flush',
              label: 'DNS 캐시 비운 뒤 재조회',
              ok: again.blocked,
              detail: again.detail,
            ),
          );
        } catch (_) {
          /* best-effort */
        }
      }
    }

    final bool markerOk = steps.any(
      (ApplyActivationStep s) => s.id == 'hosts_marker' && s.ok,
    );
    final bool hostLineOk =
        host.isEmpty ||
        steps.any((ApplyActivationStep s) => s.id == 'hosts_host' && s.ok);
    final bool lookupOk =
        host.isEmpty ||
        steps.any(
          (ApplyActivationStep s) =>
              (s.id == 'lookup' || s.id == 'lookup_flush') && s.ok,
        );
    final bool emergencyOk =
        emergency.anyLayerActive || emergency.adminBatPath != null;
    final bool hostsStackOk = markerOk && hostLineOk && lookupOk;
    final bool browserRulesOk =
        browserProtectionOk && emergency.extensionRulesOk;
    final bool chromeHandoffOk = steps.any(
      (ApplyActivationStep s) => s.id == 'chrome_handoff' && s.ok,
    );
    final bool ok =
        hostsStackOk ||
        emergencyOk ||
        browserRulesOk ||
        (easyChromeApplied && chromeHandoffOk);

    if (hostsStackOk || (emergencyOk && browserRulesOk)) {
      BlockSyncService.instance.hostsApplyPending.value = false;
    }

    final String summary;
    if (easyChromeApplied && chromeHandoffOk) {
      summary =
          '✅ Chrome 보호 모드가 켜졌습니다.\n'
          '지금 열린 Chrome에서 유튜브 주소를 다시 열어 보세요 — 별도 설정 없이 차단됩니다.\n'
          '(hosts·DNS까지 막으려면 진단 화면에서 「hosts 포함 적용」을 사용하세요.)';
    } else if (hostsStackOk) {
      summary =
          '시스템 hosts + DNS 차단이 활성화되었습니다. Chrome·Edge·Firefox를 완전히 종료한 뒤 다시 열어 주세요.';
    } else if (browserRulesOk || browserProtectionOk) {
      summary =
          '✅ 브라우저 보호는 이미 작동 중입니다.\n'
          '키워드·유튜브·도메인 규칙은 확장 + 앱 규칙 서버로 적용됩니다.\n'
          '${hostsApplyAttempted ? "시스템 hosts는 회사 PC 정책으로 막힐 수 있습니다 — UAC/BAT 없이도 Chrome·Edge·Firefox 차단은 가능합니다." : "hosts·DNS까지 막으려면 UAC 「예」 또는 바탕화면 관리자 BAT를 사용하세요."}';
    } else if (emergencyOk) {
      summary =
          '일부 비상 차단(PAC·확장 규칙)만 적용됨. '
          '「쉬운 설치」로 브라우저 보호를 완료하거나 관리자 BAT를 실행하세요.';
    } else {
      summary =
          '브라우저 보호와 hosts가 모두 미완료입니다. '
          '설정 → 쉬운 설치를 먼저 실행한 뒤, 필요하면 UAC 「예」로 hosts를 적용하세요.';
    }

    return ApplyActivationReport(success: ok, steps: steps, summary: summary);
  }

  /// Browser layer + rules API — enough for keyword/domain blocking without hosts.
  static Future<bool> isBrowserProtectionSufficient() async {
    if (!Platform.isWindows) return false;
    final ExtensionPolicyVerifyResult ext =
        await WindowsExtensionGuardService.verifyAllPolicies();
    if (!ext.protectionOk) return false;
    final EmergencyBlockResult emergency = await WindowsEmergencyBlockService
        .instance
        .readStatus();
    return emergency.extensionRulesOk;
  }

  /// Browser matrix for diagnostic agent (Chrome / Edge / Firefox).
  Future<List<BrowserTestResult>> runBrowserMatrix(List<String> hosts) async {
    final List<BrowserTestResult> out = <BrowserTestResult>[];
    out.add(await BlockerTestService.instance.systemResolverTest(hosts));

    final List<BrowserDnsProfileStatus> chromium = await ChromeDnsProbeService
        .instance
        .probeInstalledBrowsers();
    for (final BrowserDnsProfileStatus b in chromium) {
      out.add(
        await BlockerTestService.instance.chromiumBrowserTest(
          browserLabel: b.browser,
          hosts: hosts,
          profile: b,
        ),
      );
    }

    out.add(await BlockerTestService.instance.firefoxTest(hosts));
    return out;
  }

  Future<bool> _adapterUsesLoopbackDns() async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult r = await windowsRunHidden(
        p.join(
          windir,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        <String>[
          '-NoProfile',
          '-WindowStyle',
          'Hidden',
          '-Command',
          r"(Get-DnsClientServerAddress -AddressFamily IPv4 | "
              r"Where-Object { $_.ServerAddresses -contains '127.0.0.1' } | "
              r"Measure-Object).Count -gt 0",
        ],
      );
      final String out = (r.stdout as String? ?? '').trim();
      return out == 'True' || out == '1';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _programFilesChromiumPolicyInstalled() async {
    final List<String> paths = <String>[
      p.join(
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
        'Google',
        'Chrome',
        'Application',
        'policies',
        'managed',
        'policies.json',
      ),
      p.join(
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
        'Microsoft',
        'Edge',
        'Application',
        'policies',
        'managed',
        'policies.json',
      ),
    ];
    for (final String path in paths) {
      if (await File(path).exists()) return true;
    }
    return false;
  }
}
