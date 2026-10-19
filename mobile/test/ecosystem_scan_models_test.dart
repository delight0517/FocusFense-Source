import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/ecosystem_scan_models.dart';
import 'package:six_clean_room/services/blocking_ecosystem_scan_service.dart';
import 'package:six_clean_room/services/browser_block_health_monitor_service.dart';
import 'package:six_clean_room/services/browser_protection_truth_service.dart';
import 'package:six_clean_room/services/windows_extension_guard_service.dart';

void main() {
  test('tryFromJson accepts schema v1 cache', () {
    final BlockingEcosystemReport? report = BlockingEcosystemReport.tryFromJson(
      <String, Object?>{
        'schemaVersion': 1,
        'buildLabel': 'v1.0.0+302',
        'scannedAt': '2026-06-11T17:24:32.129167',
        'isPostUpdateScan': false,
        'platformLabel': 'Windows',
        'summaryKo': 'test summary',
        'builtinAdultCount': 10,
        'activeRuleCount': 100,
        'targets': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'chrome',
            'displayName': 'Chrome',
            'level': 'ready',
            'headline': 'ok',
            'detailLines': <String>['line'],
            'installed': true,
            'running': false,
          },
        ],
        'features': <Map<String, Object?>>[],
      },
    );
    expect(report, isNotNull);
    expect(report!.targets.single.urlBlockUsable, isTrue);
  });

  test('truth overlay can downgrade level without LateInitializationError', () {
    const BrowserHealth chrome = BrowserHealth(
      id: 'chrome',
      displayName: 'Chrome',
      installed: true,
      running: true,
      pid: 1,
      processStart: null,
      policyHasEntries: true,
      policyEntryCount: 400,
      policyLastWrite: null,
      policySampleMatch: true,
      processOlderThanPolicy: true,
      blockActive: true,
      reasons: <String>[],
      remedy: null,
    );
    const ExtensionPolicyVerifyResult ext = ExtensionPolicyVerifyResult(
      registryOk: true,
      policyHklmOk: true,
      forcelistOk: true,
      chromeForcelistOk: true,
      edgeForcelistOk: true,
      chromeHkcuForcelistOk: true,
      edgeHkcuForcelistOk: true,
      chromeHkcuPolicyOk: true,
      edgeHkcuPolicyOk: true,
      chromeUserInstallOk: true,
      edgeUserInstallOk: true,
      chromeHklmInstallOk: true,
      edgeHklmInstallOk: true,
      chromeLoadExtensionFallbackOk: true,
      chromeExtensionInProfile: true,
      chromeInstallOk: true,
      edgeInstallOk: true,
      firefoxPolicyOk: true,
      programDataPath: r'C:\test',
      detail: 'ok',
    );

    final EcosystemTargetRow row = BlockingEcosystemScanService.instance
        .mapBrowserHealthForTest(
          chrome,
          ext,
          truth: const BrowserProtectionTruth(
            health: chrome,
            hardKill: true,
            liveUrlBlocked: false,
            liveDetail: 'registry_ok_but_live_leak_hard_kill',
          ),
          gmailOnly: false,
          killGuard: true,
        );

    expect(row.level, EcosystemScanLevel.off);
    expect(row.urlBlockUsable, isFalse);
  });

  test('live pass marks Opera usable even when blockActive false', () {
    const BrowserHealth opera = BrowserHealth(
      id: 'opera',
      displayName: 'Opera',
      installed: true,
      running: false,
      pid: null,
      processStart: null,
      policyHasEntries: true,
      policyEntryCount: 1000,
      policyLastWrite: null,
      policySampleMatch: true,
      processOlderThanPolicy: false,
      blockActive: false,
      reasons: <String>[],
      remedy: null,
    );
    const BrowserProtectionTruth truth = BrowserProtectionTruth(
      health: opera,
      hardKill: false,
      liveUrlBlocked: true,
      liveDetail: 'policy_and_live_ok',
    );
    expect(truth.urlBlockUsable, isTrue);
    expect(truth.shouldForceKillWhenRunning, isFalse);
  });

  test('truth overlay upgrades Opera row when live pass', () {
    const BrowserHealth opera = BrowserHealth(
      id: 'opera',
      displayName: 'Opera',
      installed: true,
      running: false,
      pid: null,
      processStart: null,
      policyHasEntries: true,
      policyEntryCount: 1000,
      policyLastWrite: null,
      policySampleMatch: true,
      processOlderThanPolicy: false,
      blockActive: false,
      reasons: <String>[],
      remedy: null,
    );
    const ExtensionPolicyVerifyResult ext = ExtensionPolicyVerifyResult(
      registryOk: false,
      policyHklmOk: false,
      forcelistOk: false,
      chromeForcelistOk: false,
      edgeForcelistOk: false,
      chromeHkcuForcelistOk: false,
      edgeHkcuForcelistOk: false,
      chromeHkcuPolicyOk: false,
      edgeHkcuPolicyOk: false,
      chromeUserInstallOk: false,
      edgeUserInstallOk: false,
      chromeHklmInstallOk: false,
      edgeHklmInstallOk: false,
      chromeLoadExtensionFallbackOk: false,
      chromeInstallOk: false,
      edgeInstallOk: false,
      firefoxPolicyOk: true,
      programDataPath: null,
      detail: 'test',
    );
    final EcosystemTargetRow row = BlockingEcosystemScanService.instance
        .mapBrowserHealthForTest(
          opera,
          ext,
          truth: const BrowserProtectionTruth(
            health: opera,
            hardKill: false,
            liveUrlBlocked: true,
            liveDetail: 'policy_and_live_ok',
          ),
          gmailOnly: false,
          killGuard: true,
        );
    expect(row.urlBlockUsable, isTrue);
    expect(row.level, isNot(EcosystemScanLevel.off));
    expect(row.killOnNoBlock, isFalse);
    expect(row.detailLines.any((String l) => l.contains('즉시 종료')), isFalse);
  });

  test('usable Firefox clears stale kill lines when kill guard on', () {
    const BrowserHealth firefox = BrowserHealth(
      id: 'firefox',
      displayName: 'Firefox',
      installed: true,
      running: false,
      pid: null,
      processStart: null,
      policyHasEntries: true,
      policyEntryCount: 200,
      policyLastWrite: null,
      policySampleMatch: true,
      processOlderThanPolicy: false,
      blockActive: false,
      reasons: <String>[],
      remedy: null,
    );
    const ExtensionPolicyVerifyResult ext = ExtensionPolicyVerifyResult(
      registryOk: true,
      policyHklmOk: true,
      forcelistOk: true,
      chromeForcelistOk: true,
      edgeForcelistOk: true,
      chromeHkcuForcelistOk: true,
      edgeHkcuForcelistOk: true,
      chromeHkcuPolicyOk: true,
      edgeHkcuPolicyOk: true,
      chromeUserInstallOk: true,
      edgeUserInstallOk: true,
      chromeHklmInstallOk: true,
      edgeHklmInstallOk: true,
      chromeLoadExtensionFallbackOk: true,
      chromeExtensionInProfile: true,
      chromeInstallOk: true,
      edgeInstallOk: true,
      firefoxPolicyOk: true,
      programDataPath: r'C:\test',
      detail: 'ok',
    );
    final EcosystemTargetRow row = BlockingEcosystemScanService.instance
        .mapBrowserHealthForTest(
          firefox,
          ext,
          truth: const BrowserProtectionTruth(
            health: firefox,
            hardKill: false,
            liveUrlBlocked: true,
            liveDetail: 'policy_and_live_ok',
          ),
          gmailOnly: false,
          killGuard: true,
        );
    expect(row.urlBlockUsable, isTrue);
    expect(row.killOnNoBlock, isFalse);
    expect(row.detailLines.any((String l) => l.contains('즉시 종료')), isFalse);
  });

  test('extension only counts as working protection', () {
    const BrowserHealth chrome = BrowserHealth(
      id: 'chrome',
      displayName: 'Chrome',
      installed: true,
      running: false,
      pid: null,
      processStart: null,
      policyHasEntries: false,
      policyEntryCount: 0,
      policyLastWrite: null,
      policySampleMatch: false,
      processOlderThanPolicy: false,
      blockActive: false,
      reasons: <String>[],
      remedy: null,
    );
    const BrowserProtectionTruth truth = BrowserProtectionTruth(
      health: chrome,
      hardKill: false,
      extensionReady: true,
    );
    expect(truth.hasWorkingProtection, isTrue);
    expect(truth.urlBlockUsable, isTrue);
    expect(truth.shouldForceKillWhenRunning, isFalse);
  });

  test('no extension and no url policy does not kill a running browser', () {
    const BrowserHealth edge = BrowserHealth(
      id: 'edge',
      displayName: 'Edge',
      installed: true,
      running: true,
      pid: 2,
      processStart: null,
      policyHasEntries: false,
      policyEntryCount: 0,
      policyLastWrite: null,
      policySampleMatch: false,
      processOlderThanPolicy: false,
      blockActive: false,
      reasons: <String>[],
      remedy: null,
    );
    const BrowserProtectionTruth truth = BrowserProtectionTruth(
      health: edge,
      hardKill: false,
      extensionReady: false,
      liveUrlBlocked: false,
    );
    expect(truth.hasWorkingProtection, isFalse);
    expect(truth.shouldForceKillWhenRunning, isFalse);
  });
}
