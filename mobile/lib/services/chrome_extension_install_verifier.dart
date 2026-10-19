import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'chrome_extension_state_probe.dart';
import 'chrome_install_discovery_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_unification_service.dart';
import 'crash_journal_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_protection_mode_prefs.dart';

/// Verifies Chrome extension is **actually** in profile or policy-ready, then repairs.
final class ChromeExtensionInstallVerifier {
  ChromeExtensionInstallVerifier._();
  static final ChromeExtensionInstallVerifier instance =
      ChromeExtensionInstallVerifier._();

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'chrome_extension_verify_last.json',
  );

  /// Profile metadata proves installation/enabled state, not running code or
  /// actual enforcement. Registry/shortcut readiness never substitutes for it.
  static bool profileInstallationIsEnabled(ChromeExtensionProbeResult probe) =>
      !probe.extensionNotPresent && probe.hasEnabledCopy;

  static bool shouldRepairInstallation(
    ChromeInstallVerifyReport report, {
    required bool protectionEnabled,
    bool force = false,
  }) => protectionEnabled && (force || !report.ok);

  Future<ChromeInstallVerifyReport> verify() async {
    if (!Platform.isWindows) {
      return const ChromeInstallVerifyReport(
        ok: false,
        installedInProfile: false,
        policyReady: false,
        launchersReady: false,
        verdict: 'Windows 전용',
      );
    }

    final ChromeExtensionProbeResult probe =
        await ChromeExtensionStateProbe.probe(browser: 'chrome');
    final ExtensionPolicyVerifyResult policy =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final List<DiscoveredChrome> installs = await ChromeInstallDiscoveryService
        .instance
        .discover();
    final DiscoveredChrome? canonical = await ChromeInstallDiscoveryService
        .instance
        .canonical();
    final bool launchers = await ChromeLoadExtensionLauncher.isInstalled();
    final bool payload = await File(
      p.join(ChromeLoadExtensionLauncher.stableChromeExtDir, 'manifest.json'),
    ).exists();

    final bool inProfile = !probe.extensionNotPresent;
    final bool policyReady = policy.chromeEnforcementReady;
    final bool ok = profileInstallationIsEnabled(probe);

    String verdict;
    if (inProfile && !probe.hasEnabledCopy) {
      verdict = '⚠️ Chrome 확장 — 설치 기록은 있으나 활성 상태가 확인되지 않았습니다.';
    } else if (inProfile && probe.hasStoreCopy) {
      verdict = '✅ Chrome 스토어 확장 설치됨 — 강제 설치/삭제 잠금과는 별도입니다.';
    } else if (inProfile && probe.hasRegistryManaged) {
      verdict = '✅ Chrome 확장 — 프로필에 정책 설치됨';
    } else if (inProfile && probe.hasUnpackedCopy) {
      verdict = '⚠️ Chrome 확장 — 개발자 모드 복사본 (정책 설치 권장)';
    } else if (policyReady && launchers) {
      verdict = '✅ Chrome 보호 실행기 준비 — Chrome 완전 종료 후 아이콘으로 다시 열기';
    } else if (!payload) {
      verdict = '❌ Chrome 확장 파일 없음 — 앱이 복구 시도 중';
    } else {
      verdict = '❌ Chrome 프로필에 확장 없음 — 통합·재설치 필요';
    }

    if (installs.length > 1 && canonical != null) {
      verdict += ' (Chrome ${installs.length}개 → v${canonical.fileVersion} 통합)';
    }

    return ChromeInstallVerifyReport(
      ok: ok,
      installedInProfile: inProfile,
      enabledInProfile: probe.hasEnabledCopy,
      policyReady: policyReady,
      launchersReady: launchers,
      payloadReady: payload,
      hasManagedCopy: probe.hasRegistryManaged,
      hasUnpackedCopy: probe.hasUnpackedCopy,
      chromeInstallCount: installs.length,
      canonicalExe: canonical?.exePath,
      canonicalVersion: canonical?.fileVersion,
      verdict: verdict,
      probeDetail: probe.detail,
      policyDetail: policy.userFacingDetail,
    );
  }

  Future<ChromeInstallVerifyReport> verifyAndRepair({
    String reason = 'auto',
    bool force = false,
  }) async {
    ChromeInstallVerifyReport report = await verify();
    // @incident: manual-protection-off — repair must preserve OFF even for a
    // forced diagnostic; disabled extensions still need repair while ON.
    if (!shouldRepairInstallation(
      report,
      protectionEnabled: !WindowsProtectionModePrefs.isProtectionExplicitlyOff,
      force: force,
    )) {
      await _persist(report);
      return report;
    }

    final List<String> actions = <String>['verify_fail'];
    AppLogger.instance.warn(
      'chrome_ext_verify: repair reason=$reason ${report.verdict}',
    );

    final ChromeUnifyResult unify = await ChromeInstallDiscoveryService.instance
        .unifyInstalls(force: true);
    actions.addAll(unify.actions);

    await ChromeUnificationService.instance.ensureUnifiedChrome(
      applyPolicies: force || reason == 'boot',
    );
    actions.add('chrome_unify');

    WindowsExtensionGuardService.invalidateVerifyCache();
    report = await verify();
    report = report.copyWith(repaired: true, repairActions: actions);

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.selfHeal,
      message: report.verdict,
      data: report.toJson(),
      level: report.ok ? 'info' : 'warn',
      debounceKey: 'chrome_ext_verify',
    );

    await _persist(report);
    return report;
  }

  Future<void> _persist(ChromeInstallVerifyReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      await File(reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (_) {}
  }
}

final class ChromeInstallVerifyReport {
  const ChromeInstallVerifyReport({
    required this.ok,
    required this.installedInProfile,
    required this.policyReady,
    required this.launchersReady,
    required this.verdict,
    this.payloadReady = false,
    this.enabledInProfile = false,
    this.activeVerified = false,
    this.enforcementVerified = false,
    this.hasManagedCopy = false,
    this.hasUnpackedCopy = false,
    this.chromeInstallCount = 0,
    this.canonicalExe,
    this.canonicalVersion,
    this.probeDetail,
    this.policyDetail,
    this.repaired = false,
    this.repairActions = const <String>[],
  });

  final bool ok;
  final bool installedInProfile;
  final bool enabledInProfile;
  final bool activeVerified;
  final bool enforcementVerified;
  final bool policyReady;
  final bool launchersReady;
  final bool payloadReady;
  final bool hasManagedCopy;
  final bool hasUnpackedCopy;
  final int chromeInstallCount;
  final String? canonicalExe;
  final String? canonicalVersion;
  final String verdict;
  final String? probeDetail;
  final String? policyDetail;
  final bool repaired;
  final List<String> repairActions;

  /// Files/launchers/policy may be available before any extension is installed.
  bool get available =>
      installedInProfile || payloadReady || launchersReady || policyReady;

  ChromeInstallVerifyReport copyWith({
    bool? ok,
    bool? repaired,
    List<String>? repairActions,
  }) {
    return ChromeInstallVerifyReport(
      ok: ok ?? this.ok,
      installedInProfile: installedInProfile,
      enabledInProfile: enabledInProfile,
      activeVerified: activeVerified,
      enforcementVerified: enforcementVerified,
      policyReady: policyReady,
      launchersReady: launchersReady,
      verdict: verdict,
      payloadReady: payloadReady,
      hasManagedCopy: hasManagedCopy,
      hasUnpackedCopy: hasUnpackedCopy,
      chromeInstallCount: chromeInstallCount,
      canonicalExe: canonicalExe,
      canonicalVersion: canonicalVersion,
      probeDetail: probeDetail,
      policyDetail: policyDetail,
      repaired: repaired ?? this.repaired,
      repairActions: repairActions ?? this.repairActions,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'available': available,
    'installedInProfile': installedInProfile,
    'enabledInProfile': enabledInProfile,
    'activeVerified': activeVerified,
    'enforcementVerified': enforcementVerified,
    'policyReady': policyReady,
    'launchersReady': launchersReady,
    'payloadReady': payloadReady,
    'chromeInstallCount': chromeInstallCount,
    'canonicalExe': canonicalExe,
    'canonicalVersion': canonicalVersion,
    'verdict': verdict,
    'repaired': repaired,
    'repairActions': repairActions,
  };
}
