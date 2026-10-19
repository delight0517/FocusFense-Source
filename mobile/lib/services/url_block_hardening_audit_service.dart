import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/cross_browser_leak_scenario.dart';
import '../utils/numeric_suffix_evasion.dart';
import 'browser_extension_force_install_service.dart';
import 'chrome_dns_probe_service.dart';
import 'chromium_policy_service.dart';
import 'cross_browser_url_leak_guard_service.dart';
import 'extension_rules_builder.dart';
import 'firefox_config_service.dart';
import 'mac_system_block_service.dart';
import 'numeric_apex_hosts_gap_healer_service.dart';
import 'universal_browser_block_service.dart';
import 'windows_browser_bypass_closer_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_firefox_extension_install_service.dart';
import 'windows_hidden_process.dart';

final class UrlBlockFailureMode {
  const UrlBlockFailureMode({
    required this.id,
    required this.title,
    required this.repair,
  });

  final String id;
  final String title;
  final String repair;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'repair': repair,
  };
}

final class UrlBlockHardeningCheck {
  const UrlBlockHardeningCheck({
    required this.id,
    required this.title,
    required this.ok,
    required this.detail,
    required this.repair,
    this.repaired = false,
    this.critical = true,
    this.machineState = const <String, Object?>{},
  });

  final String id;
  final String title;
  final bool ok;
  final String detail;
  final String repair;
  final bool repaired;
  final bool critical;
  final Map<String, Object?> machineState;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'ok': ok,
    'critical': critical,
    'repaired': repaired,
    'detail': detail,
    'repair': repair,
    if (machineState.isNotEmpty) 'machineState': machineState,
  };
}

final class UrlBlockHardeningReport {
  const UrlBlockHardeningReport({
    required this.ok,
    required this.checks,
    required this.repairsAttempted,
    required this.elapsedMs,
  });

  final bool ok;
  final List<UrlBlockHardeningCheck> checks;
  final List<String> repairsAttempted;
  final int elapsedMs;

  int get passedCount =>
      checks.where((UrlBlockHardeningCheck c) => c.ok).length;

  int get failedCount =>
      checks.where((UrlBlockHardeningCheck c) => !c.ok).length;

  int get criticalFailedCount =>
      checks.where((UrlBlockHardeningCheck c) => c.critical && !c.ok).length;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'passedCount': passedCount,
    'failedCount': failedCount,
    'criticalFailedCount': criticalFailedCount,
    'repairsAttempted': repairsAttempted,
    'elapsedMs': elapsedMs,
    'checks': checks.map((UrlBlockHardeningCheck c) => c.toJson()).toList(),
  };
}

final class UrlBlockHardeningAuditService {
  UrlBlockHardeningAuditService._();
  static final UrlBlockHardeningAuditService instance =
      UrlBlockHardeningAuditService._();

  static const List<UrlBlockFailureMode> failureModeCatalog =
      <UrlBlockFailureMode>[
        UrlBlockFailureMode(
          id: 'no_active_rules',
          title: '차단할 URL 규칙이 비어 있음',
          repair: '활성 프리셋/사용자 규칙을 다시 읽고 비어 있으면 실패로 표시',
        ),
        UrlBlockFailureMode(
          id: 'changed_but_not_applied',
          title: '규칙 변경 후 실제 적용을 한 번도 안 함',
          repair: '활성 규칙과 HKCU URLBlocklist/PAC를 비교하고 자동 동기화',
        ),
        UrlBlockFailureMode(
          id: 'chrome_edge_urlblocklist_stale',
          title: 'Chrome/Edge URLBlocklist 누락 또는 오래됨',
          repair: 'Chrome/Edge HKCU 정책에 우선 패턴 1000개 재기록',
        ),
        UrlBlockFailureMode(
          id: 'extension_force_install_missing',
          title: '브라우저 확장 강제 설치 정책 누락',
          repair: '확장 페이로드/정책/바로가기 fallback을 재설치',
        ),
        UrlBlockFailureMode(
          id: 'hosts_file_missing',
          title: 'hosts 파일에 숫자형/성인 도메인 sinkhole 줄 누락',
          repair: '관리자 승인 흐름으로 hosts를 재적용',
        ),
        UrlBlockFailureMode(
          id: 'dns_cache_or_resolver_leak',
          title: 'DNS 캐시 또는 시스템 resolver가 실제 IP를 반환',
          repair: 'DNS 캐시 flush 후 숫자형 도메인 sinkhole 재검증',
        ),
        UrlBlockFailureMode(
          id: 'secure_dns_doh_bypass',
          title: 'Chrome/Edge/Whale 등의 보안 DNS가 hosts를 우회',
          repair: '브라우저별 DnsOverHttpsMode=off 정책 재적용',
        ),
        UrlBlockFailureMode(
          id: 'firefox_profile_gap',
          title: 'Firefox policies/XPI/user.js/DoH 설정 누락',
          repair: 'Firefox policies.json, XPI, user.js를 프로필별 재적용',
        ),
        UrlBlockFailureMode(
          id: 'other_chromium_browser_gap',
          title: 'Brave/Whale/Vivaldi/Opera 등 다른 Chromium 브라우저 누락',
          repair: '파생 Chromium 정책 루트에도 URLBlocklist/PAC를 미러링',
        ),
        UrlBlockFailureMode(
          id: 'plain_browser_launch_gap',
          title: '보호 바로가기가 아닌 일반 브라우저 실행 우회',
          repair: '정책 기반 URLBlocklist와 load-extension 바로가기를 둘 다 보장',
        ),
        UrlBlockFailureMode(
          id: 'pac_or_proxy_gap',
          title: 'PAC/프록시 보조 차단 파일 또는 정책 누락',
          repair: '사용자 쓰기 가능한 PAC 파일과 AutoConfigURL 정책 재생성',
        ),
        UrlBlockFailureMode(
          id: 'urlblocklist_cap_eviction',
          title: 'URLBlocklist 1000개 제한 때문에 중요한 항목이 밀림',
          repair: '숫자형 미러/사용자 규칙을 앞쪽 우선순위로 재정렬',
        ),
        UrlBlockFailureMode(
          id: 'numeric_mirror_rotation_gap',
          title: '16.xbbg.tv 같은 숫자형 회전 미러 도메인 누락',
          repair: '부모 도메인과 1-99 숫자형 자식 도메인을 우선 차단',
        ),
        UrlBlockFailureMode(
          id: 'running_browser_old_policy',
          title: '이미 실행 중인 브라우저가 오래된 정책/캐시를 들고 있음',
          repair: 'DNS/정책 상태를 확인하고 필요 시 재시작 안내가 뜨도록 표시',
        ),
        UrlBlockFailureMode(
          id: 'false_success_after_uac_or_acl',
          title: 'UAC/ACL 실패인데 성공처럼 보이는 거짓 적용',
          repair: '최종 DNS/hosts/정책 검증 실패 시 성공 처리 금지',
        ),
      ];

  Future<UrlBlockHardeningReport> auditAndRepair({
    String reason = 'manual',
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    if (!Platform.isWindows) {
      final List<UrlBlockHardeningCheck> checks = failureModeCatalog
          .map(
            (UrlBlockFailureMode m) => UrlBlockHardeningCheck(
              id: m.id,
              title: m.title,
              ok: true,
              critical: false,
              detail: 'Windows 전용 점검',
              repair: m.repair,
            ),
          )
          .toList(growable: false);
      return UrlBlockHardeningReport(
        ok: true,
        checks: checks,
        repairsAttempted: const <String>[],
        elapsedMs: watch.elapsedMilliseconds,
      );
    }

    _UrlBlockSnapshot before = await _snapshot();
    final List<String> repairs = <String>[];

    if (before.needsUniversalSync) {
      final UniversalBlockResult r = await UniversalBrowserBlockService.instance
          .syncNow(reason: 'hardening_$reason')
          .timeout(
            const Duration(seconds: 35),
            onTimeout: () => const UniversalBlockResult(
              ok: false,
              message: 'hardening universal sync timeout',
            ),
          );
      repairs.add('universal_sync:${r.ok}:${r.message}');
    }

    if (before.needsCrossBrowserSeal) {
      final CrossBrowserLeakGuardReport r =
          await CrossBrowserUrlLeakGuardService.instance
              .sealAll(reason: 'hardening_$reason')
              .timeout(
                const Duration(seconds: 30),
                onTimeout: () => const CrossBrowserLeakGuardReport(
                  ok: false,
                  message: 'cross-browser seal timeout',
                  sealed: <CrossBrowserLeakScenario>[],
                  steps: <String>[],
                ),
              );
      repairs.add('cross_browser:${r.ok}:${r.message}');
    }

    if (before.needsExtensionRepair) {
      final BrowserExtensionForceInstallReport r =
          await BrowserExtensionForceInstallService.instance
              .installAll(
                reason: 'hardening_$reason',
                force: true,
                userInitiated: false,
                attemptElevated: false,
              )
              .timeout(
                const Duration(seconds: 35),
                onTimeout: () => const BrowserExtensionForceInstallReport(
                  ok: false,
                  skipped: true,
                  verdict: 'extension install timeout',
                  actions: <String>[],
                ),
              );
      repairs.add('extension:${r.ok}:${r.verdict}');
    }

    if (before.needsHostsRepair) {
      final NumericApexHostsHealReport r =
          await NumericApexHostsGapHealerService.instance
              .healIfNeeded(reason: 'hardening_$reason', force: true)
              .timeout(
                const Duration(seconds: 95),
                onTimeout: () => NumericApexHostsHealReport(
                  at: DateTime.now(),
                  reason: 'hardening_$reason',
                  ok: false,
                  probeHosts: before.numericProbeHosts,
                  leaksBefore: before.dnsLeaks,
                  leaksAfter: before.dnsLeaks,
                  actions: const <String>['hardening_timeout'],
                  message: 'numeric hosts repair timeout',
                ),
              );
      repairs.add('numeric_hosts:${r.ok}:${r.message}');
    }

    final _UrlBlockSnapshot after = repairs.isEmpty
        ? before
        : await _snapshot();
    final List<UrlBlockHardeningCheck> checks = _checks(
      before: before,
      after: after,
      repairsAttempted: repairs,
    );
    final bool ok = checks.every(
      (UrlBlockHardeningCheck c) => !c.critical || c.ok,
    );
    return UrlBlockHardeningReport(
      ok: ok,
      checks: checks,
      repairsAttempted: repairs,
      elapsedMs: watch.elapsedMilliseconds,
    );
  }

  Future<_UrlBlockSnapshot> _snapshot() async {
    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    final List<String> expected =
        await ChromiumPolicyService.activeBlocklistPatterns();
    final List<String> numericProbeHosts =
        await NumericApexHostsGapHealerService.instance.priorityProbeHosts(
          maxHosts: 8,
        );
    final List<String> chromeUrlBlocklist = await _readUrlBlocklist(
      r'HKCU\SOFTWARE\Policies\Google\Chrome',
    );
    final List<String> edgeUrlBlocklist = await _readUrlBlocklist(
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge',
    );
    final Map<String, int> derivativeCounts = <String, int>{};
    int derivativeFreshCount = 0;
    final Set<String> priority = _priorityPatterns(
      expected: expected,
      rules: rules,
      numericProbeHosts: numericProbeHosts,
    );
    for (final String root
        in WindowsBrowserBypassCloserService.derivativeHkcuRoots) {
      final List<String> values = await _readUrlBlocklist(root);
      derivativeCounts[root] = values.length;
      if (_containsAll(values, priority)) derivativeFreshCount++;
    }

    WindowsExtensionGuardService.invalidateVerifyCache();
    final ExtensionPolicyVerifyResult extension =
        await WindowsExtensionGuardService.verifyAllPolicies(force: true);
    final FirefoxInstallVerifyResult firefoxInstall =
        await WindowsFirefoxExtensionInstallService.verify();
    final List<FirefoxProfileStatus> firefoxProfiles =
        await FirefoxConfigService.instance.probeProfiles();
    final List<BrowserDnsProfileStatus> chromiumDns =
        await ChromeDnsProbeService.instance.probeInstalledBrowsers();
    final EmergencyBlockResult emergency = await WindowsEmergencyBlockService
        .instance
        .readStatus();
    final List<String> hostsLeaks = await NumericApexHostsGapHealerService
        .instance
        .findHostsFileLeaks(hosts: numericProbeHosts);
    final List<String> dnsLeaks = await NumericApexHostsGapHealerService
        .instance
        .findDnsLeaks(hosts: numericProbeHosts);
    final List<String> runningBrowsers = await _runningBrowserProcesses();
    final bool pacFileExists = await File(
      WindowsEmergencyBlockService.pacPath(),
    ).exists();

    return _UrlBlockSnapshot(
      rules: rules,
      expectedBlocklist: expected,
      priorityPatterns: priority,
      chromeUrlBlocklist: chromeUrlBlocklist,
      edgeUrlBlocklist: edgeUrlBlocklist,
      derivativeCounts: derivativeCounts,
      derivativeFreshCount: derivativeFreshCount,
      extension: extension,
      firefoxInstall: firefoxInstall,
      firefoxProfiles: firefoxProfiles,
      chromiumDns: chromiumDns,
      emergency: emergency,
      numericProbeHosts: numericProbeHosts,
      hostsLeaks: hostsLeaks,
      dnsLeaks: dnsLeaks,
      runningBrowsers: runningBrowsers,
      pacFileExists: pacFileExists,
    );
  }

  List<UrlBlockHardeningCheck> _checks({
    required _UrlBlockSnapshot before,
    required _UrlBlockSnapshot after,
    required List<String> repairsAttempted,
  }) {
    final Map<String, UrlBlockFailureMode> modeById =
        <String, UrlBlockFailureMode>{
          for (final UrlBlockFailureMode m in failureModeCatalog) m.id: m,
        };
    UrlBlockHardeningCheck check(
      String id,
      bool ok,
      String detail, {
      bool critical = true,
      Map<String, Object?> machineState = const <String, Object?>{},
    }) {
      final UrlBlockFailureMode mode = modeById[id]!;
      return UrlBlockHardeningCheck(
        id: mode.id,
        title: mode.title,
        ok: ok,
        critical: critical,
        repaired: !before.sameVerdictFor(id, after) && ok,
        detail: detail,
        repair: mode.repair,
        machineState: machineState,
      );
    }

    final bool hasRules = after.hasRules;
    final bool chromePrimaryOk = after.chromePrimaryOk;
    final bool edgePrimaryOk = after.edgePrimaryOk;
    final bool primaryPolicyOk = chromePrimaryOk && edgePrimaryOk;
    final bool extensionOk = after.extensionReady;
    final bool hostsOk = after.hostsLeaks.isEmpty;
    final bool dnsOk = after.dnsLeaks.isEmpty;
    final bool dohOk = after.dohRiskBrowsers.isEmpty;
    final bool firefoxOk = after.firefoxOk;
    final bool derivativeOk = after.derivativeOk;
    final bool pacOk = after.pacOk;
    final bool priorityOk = after.priorityMissingInPrimary.isEmpty;
    final bool numericMirrorOk = after.numericMirrorOk;
    final bool runningOk =
        after.runningBrowsers.isEmpty || (primaryPolicyOk && dnsOk && dohOk);
    final bool falseSuccessOk =
        hasRules && primaryPolicyOk && hostsOk && dnsOk && priorityOk;

    return <UrlBlockHardeningCheck>[
      check(
        'no_active_rules',
        hasRules,
        hasRules
            ? '활성 URL/도메인 규칙 ${after.rules.blockedDomains.length}개 확인'
            : '차단할 규칙이 0개라 어떤 URL도 막을 수 없음',
        machineState: <String, Object?>{
          'blockedDomains': after.rules.blockedDomains.length,
          'keywords': after.rules.keywords.length,
          'searchQueries': after.rules.searchQueries.length,
        },
      ),
      check(
        'changed_but_not_applied',
        primaryPolicyOk || pacOk,
        primaryPolicyOk
            ? '활성 규칙이 Chrome/Edge URLBlocklist에 반영됨'
            : pacOk
            ? 'URLBlocklist 일부 누락, PAC 보조 차단은 활성'
            : '활성 규칙이 브라우저 정책/PAC에 아직 반영되지 않음',
        machineState: <String, Object?>{
          'repairsAttempted': repairsAttempted,
          'chromeCount': after.chromeUrlBlocklist.length,
          'edgeCount': after.edgeUrlBlocklist.length,
          'pacOk': pacOk,
        },
      ),
      check(
        'chrome_edge_urlblocklist_stale',
        primaryPolicyOk,
        primaryPolicyOk
            ? 'Chrome/Edge 우선 차단 패턴 일치'
            : 'Chrome/Edge URLBlocklist 우선 패턴 누락: ${after.primaryPolicyGaps.join(", ")}',
        machineState: <String, Object?>{
          'priorityCount': after.priorityPatterns.length,
          'missing': after.primaryPolicyGaps,
        },
      ),
      check(
        'extension_force_install_missing',
        extensionOk,
        extensionOk
            ? 'Chrome/Edge/Firefox 확장 차단 계층 준비됨'
            : '확장 차단 계층 누락: ${after.extension.detail}',
        machineState: <String, Object?>{
          'chromeReady': after.extension.chromeEnforcementReady,
          'edgeReady': after.extension.edgeEnforcementReady,
          'firefoxReady': after.extension.firefoxEnforcementReady,
        },
      ),
      check(
        'hosts_file_missing',
        hostsOk,
        hostsOk
            ? 'hosts 파일에 숫자형 우회 도메인 sinkhole 줄 있음'
            : 'hosts 누락: ${after.hostsLeaks.join(", ")}',
        machineState: <String, Object?>{
          'probeHosts': after.numericProbeHosts,
          'hostsLeaks': after.hostsLeaks,
        },
      ),
      check(
        'dns_cache_or_resolver_leak',
        dnsOk,
        dnsOk
            ? '시스템 DNS가 우선 점검 도메인을 0.0.0.0으로 차단'
            : '시스템 DNS 누수: ${after.dnsLeaks.join(", ")}',
        machineState: <String, Object?>{
          'probeHosts': after.numericProbeHosts,
          'dnsLeaks': after.dnsLeaks,
        },
      ),
      check(
        'secure_dns_doh_bypass',
        dohOk,
        dohOk
            ? '설치된 Chromium 계열 보안 DNS 위험 없음'
            : '보안 DNS 켜짐 가능: ${after.dohRiskBrowsers.join(", ")}',
        machineState: <String, Object?>{
          'browsers': after.chromiumDns
              .map(
                (BrowserDnsProfileStatus b) => <String, Object?>{
                  'browser': b.browser,
                  'profile': b.profileName,
                  'secureDnsLikelyOn': b.secureDnsLikelyOn,
                  'mode': b.mode,
                  'detail': b.detail,
                },
              )
              .toList(),
        },
      ),
      check(
        'firefox_profile_gap',
        firefoxOk,
        firefoxOk
            ? 'Firefox policies/XPI/user.js 상태 정상 또는 Firefox 미설치'
            : 'Firefox 프로필/DoH/XPI 누락',
        machineState: <String, Object?>{
          'policiesOk': after.firefoxInstall.policiesOk,
          'xpiInProgramData': after.firefoxInstall.xpiInProgramData,
          'profileCount': after.firefoxInstall.profileCount,
          'profileTotal': after.firefoxInstall.profileTotal,
          'riskyProfiles': after.firefoxRiskProfiles,
        },
      ),
      check(
        'other_chromium_browser_gap',
        derivativeOk,
        derivativeOk
            ? '파생 Chromium 정책 루트에 우선 차단 패턴 미러링됨'
            : '파생 Chromium 정책 루트 일부가 비어 있거나 오래됨',
        critical: false,
        machineState: <String, Object?>{
          'freshCount': after.derivativeFreshCount,
          'totalRoots': after.derivativeCounts.length,
          'counts': after.derivativeCounts,
        },
      ),
      check(
        'plain_browser_launch_gap',
        primaryPolicyOk && (extensionOk || pacOk),
        primaryPolicyOk && (extensionOk || pacOk)
            ? '일반 실행 브라우저도 정책/PAC/확장 중 최소 2계층으로 차단'
            : '보호 바로가기 밖에서 실행하면 URL 차단 계층이 부족함',
        machineState: <String, Object?>{
          'primaryPolicyOk': primaryPolicyOk,
          'extensionOk': extensionOk,
          'pacOk': pacOk,
        },
      ),
      check(
        'pac_or_proxy_gap',
        pacOk,
        pacOk ? 'PAC 파일과 AutoConfigURL 보조 차단 활성' : 'PAC 보조 차단 누락',
        critical: false,
        machineState: <String, Object?>{
          'pacApplied': after.emergency.pacApplied,
          'pacPath': after.emergency.pacPath,
          'pacFileExists': after.pacFileExists,
          'errors': after.emergency.errors,
        },
      ),
      check(
        'urlblocklist_cap_eviction',
        priorityOk,
        priorityOk
            ? '1000개 제한 안에서도 우선 차단 패턴이 앞쪽에 남아 있음'
            : '우선 패턴이 URLBlocklist에서 밀림: ${after.priorityMissingInPrimary.join(", ")}',
        machineState: <String, Object?>{
          'expectedCount': after.expectedBlocklist.length,
          'priorityMissing': after.priorityMissingInPrimary,
        },
      ),
      check(
        'numeric_mirror_rotation_gap',
        numericMirrorOk,
        numericMirrorOk
            ? '16.xbbg.tv 같은 숫자형 회전 미러 점검 통과'
            : '숫자형 회전 미러 누수: hosts=${after.hostsLeaks.join(", ")} dns=${after.dnsLeaks.join(", ")}',
        machineState: <String, Object?>{
          'numericProbeHosts': after.numericProbeHosts,
          'hostsLeaks': after.hostsLeaks,
          'dnsLeaks': after.dnsLeaks,
        },
      ),
      check(
        'running_browser_old_policy',
        runningOk,
        runningOk
            ? after.runningBrowsers.isEmpty
                  ? '실행 중인 주요 브라우저 없음'
                  : '브라우저 실행 중이지만 정책/DNS 차단 상태는 정상'
            : '실행 중 브라우저가 오래된 정책을 들고 있을 가능성: ${after.runningBrowsers.join(", ")}',
        critical: false,
        machineState: <String, Object?>{
          'runningBrowsers': after.runningBrowsers,
          'primaryPolicyOk': primaryPolicyOk,
          'dnsOk': dnsOk,
          'dohOk': dohOk,
        },
      ),
      check(
        'false_success_after_uac_or_acl',
        falseSuccessOk,
        falseSuccessOk
            ? '정책/hosts/DNS 최종 검증 통과 - 성공 처리 가능'
            : '적용 성공처럼 보여도 실제 차단 검증이 아직 실패',
        machineState: <String, Object?>{
          'hasRules': hasRules,
          'primaryPolicyOk': primaryPolicyOk,
          'hostsOk': hostsOk,
          'dnsOk': dnsOk,
          'priorityOk': priorityOk,
        },
      ),
    ];
  }

  Set<String> _priorityPatterns({
    required List<String> expected,
    required ExtensionRulesPayload rules,
    required List<String> numericProbeHosts,
  }) {
    final Set<String> out = <String>{};
    out.addAll(expected.take(80));
    final Set<String> expectedSet = expected.toSet();
    for (final String rawHost in numericProbeHosts) {
      final String host = MacSystemBlockService.canonicalHost(rawHost);
      if (host.isEmpty) continue;
      for (final String p in <String>[
        host,
        ..._parentPriorityPatterns(host),
      ]) {
        if (expectedSet.contains(p)) out.add(p);
      }
    }
    for (final String rawHost in rules.blockedDomains.take(40)) {
      final String host = MacSystemBlockService.canonicalHost(rawHost);
      if (host.isEmpty) continue;
      for (final String p in <String>[host]) {
        if (expectedSet.contains(p)) out.add(p);
      }
    }
    return out;
  }

  List<String> _parentPriorityPatterns(String host) {
    final int dot = host.indexOf('.');
    if (dot <= 0 || dot == host.length - 1) return const <String>[];
    final String prefix = host.substring(0, dot);
    if (!RegExp(r'^\d{1,3}$').hasMatch(prefix)) return const <String>[];
    final String parent = host.substring(dot + 1);
    return <String>[parent];
  }

  bool _containsAll(List<String> values, Set<String> required) {
    if (required.isEmpty) return values.isNotEmpty;
    final Set<String> normalized = values.map((String v) => v.trim()).toSet();
    return required.every(normalized.contains);
  }

  Future<List<String>> _readUrlBlocklist(String root) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String regExe = p.join(windir, 'System32', 'reg.exe');
    try {
      final ProcessResult pr = await windowsRunHidden(regExe, <String>[
        'query',
        '$root\\URLBlocklist',
      ]);
      if (pr.exitCode != 0) return const <String>[];
      final String out = '${pr.stdout}';
      final RegExp re = RegExp(
        r'^\s+\S+\s+REG_SZ\s+(.+?)\s*$',
        multiLine: true,
      );
      return re
          .allMatches(out)
          .map((RegExpMatch m) => (m.group(1) ?? '').trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<List<String>> _runningBrowserProcesses() async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String psExe = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    try {
      final ProcessResult pr = await windowsRunHidden(psExe, const <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        r"$names = 'chrome','msedge','firefox','brave','vivaldi','opera','whale'; Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName } | Select-Object -ExpandProperty ProcessName -Unique",
      ]).timeout(const Duration(seconds: 5));
      if (pr.exitCode != 0) return const <String>[];
      return '${pr.stdout}'
          .split(RegExp(r'\r?\n'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toSet()
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }
}

final class _UrlBlockSnapshot {
  const _UrlBlockSnapshot({
    required this.rules,
    required this.expectedBlocklist,
    required this.priorityPatterns,
    required this.chromeUrlBlocklist,
    required this.edgeUrlBlocklist,
    required this.derivativeCounts,
    required this.derivativeFreshCount,
    required this.extension,
    required this.firefoxInstall,
    required this.firefoxProfiles,
    required this.chromiumDns,
    required this.emergency,
    required this.numericProbeHosts,
    required this.hostsLeaks,
    required this.dnsLeaks,
    required this.runningBrowsers,
    required this.pacFileExists,
  });

  final ExtensionRulesPayload rules;
  final List<String> expectedBlocklist;
  final Set<String> priorityPatterns;
  final List<String> chromeUrlBlocklist;
  final List<String> edgeUrlBlocklist;
  final Map<String, int> derivativeCounts;
  final int derivativeFreshCount;
  final ExtensionPolicyVerifyResult extension;
  final FirefoxInstallVerifyResult firefoxInstall;
  final List<FirefoxProfileStatus> firefoxProfiles;
  final List<BrowserDnsProfileStatus> chromiumDns;
  final EmergencyBlockResult emergency;
  final List<String> numericProbeHosts;
  final List<String> hostsLeaks;
  final List<String> dnsLeaks;
  final List<String> runningBrowsers;
  final bool pacFileExists;

  bool get hasRules =>
      rules.blockedDomains.isNotEmpty ||
      rules.keywords.isNotEmpty ||
      rules.searchQueries.isNotEmpty ||
      rules.blockedYoutubeHandles.isNotEmpty ||
      rules.blockedYoutubeChannelIds.isNotEmpty ||
      rules.blockedYoutubeVideoIds.isNotEmpty ||
      rules.numericStemHosts.isNotEmpty;

  bool get chromePrimaryOk => _containsAll(chromeUrlBlocklist);

  bool get edgePrimaryOk => _containsAll(edgeUrlBlocklist);

  bool _containsAll(List<String> values) {
    if (priorityPatterns.isEmpty) return values.isNotEmpty;
    final Set<String> normalized = values.map((String v) => v.trim()).toSet();
    return priorityPatterns.every(normalized.contains);
  }

  bool get extensionReady =>
      extension.chromeEnforcementReady &&
      extension.edgeEnforcementReady &&
      extension.firefoxEnforcementReady;

  bool get pacOk =>
      emergency.pacApplied &&
      pacFileExists &&
      (emergency.pacPath?.contains('sixvpn_block.pac') ?? false);

  bool get derivativeOk {
    if (derivativeCounts.isEmpty) return true;
    return derivativeFreshCount >= (derivativeCounts.length / 2).ceil();
  }

  List<String> get dohRiskBrowsers => chromiumDns
      .where((BrowserDnsProfileStatus b) => b.secureDnsLikelyOn)
      .map((BrowserDnsProfileStatus b) => '${b.browser}:${b.profileName}')
      .toList(growable: false);

  List<String> get firefoxRiskProfiles => firefoxProfiles
      .where((FirefoxProfileStatus f) => !f.dohLikelyOff)
      .map((FirefoxProfileStatus f) => f.displayName())
      .toList(growable: false);

  bool get firefoxOk {
    if (firefoxInstall.profileTotal == 0 && firefoxProfiles.isEmpty) {
      return true;
    }
    return firefoxInstall.allOk && firefoxRiskProfiles.isEmpty;
  }

  List<String> get priorityMissingInPrimary {
    final Set<String> chrome = chromeUrlBlocklist.toSet();
    final Set<String> edge = edgeUrlBlocklist.toSet();
    return priorityPatterns
        .where((String p) => !chrome.contains(p) || !edge.contains(p))
        .take(20)
        .toList(growable: false);
  }

  List<String> get primaryPolicyGaps {
    final List<String> gaps = <String>[];
    if (!chromePrimaryOk) gaps.add('chrome');
    if (!edgePrimaryOk) gaps.add('edge');
    return gaps;
  }

  bool get numericMirrorOk {
    if (numericProbeHosts.isEmpty) return true;
    final bool hasNumericProbe = numericProbeHosts.any(
      (String host) =>
          NumericSuffixEvasion.fromHost(host) != null ||
          RegExp(r'^\d{1,3}\.').hasMatch(host),
    );
    if (!hasNumericProbe) return hostsLeaks.isEmpty && dnsLeaks.isEmpty;
    return hostsLeaks.isEmpty &&
        dnsLeaks.isEmpty &&
        priorityMissingInPrimary.isEmpty;
  }

  bool get needsUniversalSync =>
      hasRules &&
      (!chromePrimaryOk ||
          !edgePrimaryOk ||
          !pacOk ||
          !derivativeOk ||
          dohRiskBrowsers.isNotEmpty ||
          !firefoxOk);

  bool get needsCrossBrowserSeal =>
      hasRules &&
      (!derivativeOk ||
          dohRiskBrowsers.isNotEmpty ||
          !pacOk ||
          runningBrowsers.isNotEmpty);

  bool get needsExtensionRepair => hasRules && !extensionReady;

  bool get needsHostsRepair =>
      hasRules && (hostsLeaks.isNotEmpty || dnsLeaks.isNotEmpty);

  bool sameVerdictFor(String id, _UrlBlockSnapshot other) {
    bool verdict(_UrlBlockSnapshot s) {
      switch (id) {
        case 'no_active_rules':
          return s.hasRules;
        case 'changed_but_not_applied':
          return (s.chromePrimaryOk && s.edgePrimaryOk) || s.pacOk;
        case 'chrome_edge_urlblocklist_stale':
          return s.chromePrimaryOk && s.edgePrimaryOk;
        case 'extension_force_install_missing':
          return s.extensionReady;
        case 'hosts_file_missing':
          return s.hostsLeaks.isEmpty;
        case 'dns_cache_or_resolver_leak':
          return s.dnsLeaks.isEmpty;
        case 'secure_dns_doh_bypass':
          return s.dohRiskBrowsers.isEmpty;
        case 'firefox_profile_gap':
          return s.firefoxOk;
        case 'other_chromium_browser_gap':
          return s.derivativeOk;
        case 'plain_browser_launch_gap':
          return s.chromePrimaryOk &&
              s.edgePrimaryOk &&
              (s.extensionReady || s.pacOk);
        case 'pac_or_proxy_gap':
          return s.pacOk;
        case 'urlblocklist_cap_eviction':
          return s.priorityMissingInPrimary.isEmpty;
        case 'numeric_mirror_rotation_gap':
          return s.numericMirrorOk;
        case 'running_browser_old_policy':
          return s.runningBrowsers.isEmpty ||
              (s.chromePrimaryOk &&
                  s.edgePrimaryOk &&
                  s.dnsLeaks.isEmpty &&
                  s.dohRiskBrowsers.isEmpty);
        case 'false_success_after_uac_or_acl':
          return s.hasRules &&
              s.chromePrimaryOk &&
              s.edgePrimaryOk &&
              s.hostsLeaks.isEmpty &&
              s.dnsLeaks.isEmpty &&
              s.priorityMissingInPrimary.isEmpty;
      }
      return true;
    }

    return verdict(this) == verdict(other);
  }
}
