import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'chrome_block_autonomy_service.dart';
import 'chrome_extension_auto_sync_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'crash_journal_service.dart';
import 'firefox_xpi_packager.dart';
import 'universal_browser_block_service.dart';
import 'usage_ingest_server.dart';
import 'windows_emergency_block_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_firefox_extension_install_service.dart';
import 'automated_browser_handoff_service.dart';
import 'autonomous_browser_protection_service.dart';
import 'browser_extension_force_install_service.dart';
import 'chrome_extension_install_verifier.dart';
import 'chrome_extension_state_probe.dart';

/// Diagnose + self-heal Chrome · Edge · Firefox blocking in one cycle.
final class TriBrowserSelfHealService {
  TriBrowserSelfHealService._();
  static final TriBrowserSelfHealService instance =
      TriBrowserSelfHealService._();

  // @incident: repair_race_with_policy_writer — 12-min floor between repair
  // passes; shorter intervals risk racing the policy layer's own write
  // cycle and re-triggering the same forcelist regression.
  static const Duration kRepairCooldown = Duration(minutes: 12);

  final ValueNotifier<TriBrowserHealReport?> latest =
      ValueNotifier<TriBrowserHealReport?>(null);

  bool _running = false;
  DateTime? _lastRepairAt;

  String get reportPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'tri_browser_heal_last.json',
      );

  Future<TriBrowserHealReport> runCycle({
    String reason = 'manual',
    bool userInitiated = false,
    bool repair = true,
  }) async {
    if (!Platform.isWindows) {
      return TriBrowserHealReport(
        at: DateTime.now(),
        reason: reason,
        ok: true,
        verdict: 'Windows 전용',
        browsers: const <BrowserHealthRow>[],
        actions: const <String>[],
      );
    }
    if (_running) {
      return latest.value ??
          TriBrowserHealReport(
            at: DateTime.now(),
            reason: reason,
            ok: false,
            verdict: '이전 점검 실행 중',
            browsers: const <BrowserHealthRow>[],
            actions: const <String>[],
          );
    }
    if (!await BlockingSelfHealPrefs.instance.isEnabled() && !userInitiated) {
      return TriBrowserHealReport(
        at: DateTime.now(),
        reason: reason,
        ok: true,
        verdict: '자가 점검 꺼짐',
        browsers: const <BrowserHealthRow>[],
        actions: const <String>[],
      );
    }

    _running = true;
    try {
      if (!UsageIngestServer.instance.isRunning) {
        UsageIngestServer.instance.start();
      }

      List<BrowserHealthRow> rows = await diagnose();
      final List<String> actions = <String>['diagnose'];

      final bool needsRepair = rows.any((BrowserHealthRow r) => !r.ok);
      final bool repairAllowed = _repairAllowed() || userInitiated;
      if (repair &&
          needsRepair &&
          repairAllowed &&
          (userInitiated ||
              reason == 'boot' ||
              reason == 'resume' ||
              reason == 'periodic' ||
              reason == 'post_rebuild')) {
        actions.addAll(await _repair(rows, reason: reason, force: userInitiated));
        _lastRepairAt = DateTime.now();
        rows = await diagnose();
        actions.add('re_diagnose');
      }

      final bool allOk = rows.every((BrowserHealthRow r) => r.ok || r.skipped);
      final String verdict = allOk
          ? 'Chrome · Edge · Firefox 차단 준비됨'
          : _verdictFor(rows);

      final TriBrowserHealReport report = TriBrowserHealReport(
        at: DateTime.now(),
        reason: reason,
        ok: allOk,
        verdict: verdict,
        browsers: rows,
        actions: actions,
      );
      latest.value = report;
      await _persist(report);
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: verdict,
        data: report.toJson(),
        level: allOk ? 'info' : 'warn',
        debounceKey: 'tri_browser_heal',
      );
      AppLogger.instance.info(
        'tri_browser_heal [$reason] ok=$allOk actions=$actions',
      );
      return report;
    } catch (e, st) {
      AppLogger.instance.error('tri_browser_heal failed', error: e, stack: st);
      final TriBrowserHealReport fail = TriBrowserHealReport(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        verdict: '자가 점검 오류: $e',
        browsers: const <BrowserHealthRow>[],
        actions: const <String>['error'],
      );
      latest.value = fail;
      return fail;
    } finally {
      _running = false;
    }
  }

  Future<List<BrowserHealthRow>> diagnose() async {
    final ExtensionPolicyVerifyResult policy =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final ChromeBlockStatus chrome =
        await ChromeBlockAutonomyService.instance.runOnce(repair: false);

    final bool pacOk = await File(WindowsEmergencyBlockService.pacPath()).exists();
    final bool launchersOk = await ChromeLoadExtensionLauncher.isInstalled();
    final bool ffInstalled =
        await WindowsFirefoxExtensionInstallService.isFirefoxInstalled();
    final FirefoxInstallVerifyResult ff =
        await WindowsFirefoxExtensionInstallService.verify();

    final ChromeExtensionProbeResult chromeProbe =
        await ChromeExtensionStateProbe.probe(browser: 'chrome');
    final ChromeInstallVerifyReport chromeVerify =
        await ChromeExtensionInstallVerifier.instance.verify();
    final bool chromeProfileExt = !chromeProbe.extensionNotPresent;
    final bool chromeOk = (chrome.blockingOk || chromeProfileExt) &&
        (policy.chromeEnforcementReady || chromeProfileExt);
    final bool edgeOk =
        policy.edgeEnforcementReady && pacOk && launchersOk;
    final bool firefoxOk =
        !ffInstalled ||
        (policy.firefoxEnforcementReady && ff.profileCount > 0);

    return <BrowserHealthRow>[
      BrowserHealthRow(
        id: 'chrome',
        label: 'Chrome',
        ok: chromeOk,
        issues: _chromeIssues(chrome, policy, chromeVerify),
        detail: chromeOk
            ? chromeProfileExt
                ? '프로필에 확장 설치됨 + 규칙 API'
                : '보호 실행기 + 규칙 API 준비'
            : chrome.userMessage,
      ),
      BrowserHealthRow(
        id: 'edge',
        label: 'Edge',
        ok: edgeOk,
        issues: _edgeIssues(policy, pacOk, launchersOk),
        detail: edgeOk ? '확장 + PAC 준비' : 'Edge 보호 미완료',
      ),
      BrowserHealthRow(
        id: 'firefox',
        label: 'Firefox',
        ok: firefoxOk,
        skipped: !ffInstalled,
        issues: ffInstalled ? _firefoxIssues(policy, ff) : const <String>[],
        detail: !ffInstalled
            ? '미설치 — 스킵'
            : firefoxOk
                ? '정책 + 프로필 XPI (${ff.profileCount}/${ff.profileTotal})'
                : 'Firefox 확장·정책 미완료',
      ),
    ];
  }

  List<String> _chromeIssues(
    ChromeBlockStatus chrome,
    ExtensionPolicyVerifyResult policy,
    ChromeInstallVerifyReport chromeVerify,
  ) {
    final List<String> out = <String>[];
    if (!chrome.payloadOk) out.add('확장 파일 없음');
    if (!chrome.launchersOk) out.add('보호 실행기 없음');
    if (!chrome.rulesSnapshotOk) out.add('규칙 스냅샷 없음');
    if (!chrome.rulesApiOk) out.add('규칙 API 꺼짐');
    if (!policy.chromeEnforcementReady) {
      out.add('확장 미로드(바로가기·정책 필요)');
    }
    if (!chromeVerify.installedInProfile && !chromeVerify.policyReady) {
      out.add('프로필에 확장 없음');
    }
    if (chromeVerify.chromeInstallCount > 1) {
      out.add(
        'Chrome ${chromeVerify.chromeInstallCount}개 설치 — v${chromeVerify.canonicalVersion} 통합 중',
      );
    }
    return out;
  }

  List<String> _edgeIssues(
    ExtensionPolicyVerifyResult policy,
    bool pacOk,
    bool launchersOk,
  ) {
    final List<String> out = <String>[];
    if (!policy.edgeEnforcementReady) out.add('Edge 확장 미연결');
    if (!pacOk) out.add('PAC 파일 없음');
    if (!launchersOk) out.add('보호 실행기 없음');
    return out;
  }

  List<String> _firefoxIssues(
    ExtensionPolicyVerifyResult policy,
    FirefoxInstallVerifyResult ff,
  ) {
    final List<String> out = <String>[];
    if (!policy.firefoxEnforcementReady) out.add('XPI/정책 없음');
    if (ff.profileCount == 0) out.add('프로필에 XPI 없음');
    return out;
  }

  Future<List<String>> _repair(
    List<BrowserHealthRow> before, {
    required String reason,
    bool force = false,
  }) async {
    final List<String> done = <String>[];
    final bool chromeFail = before.any((BrowserHealthRow r) => r.id == 'chrome' && !r.ok);
    final bool edgeFail = before.any((BrowserHealthRow r) => r.id == 'edge' && !r.ok);
    final bool ffFail = before.any((BrowserHealthRow r) => r.id == 'firefox' && !r.ok);

    if (chromeFail || edgeFail || ffFail) {
      final BrowserExtensionForceInstallReport forceReport =
          await BrowserExtensionForceInstallService.instance.installAll(
        reason: 'tri_heal_$reason',
        force: force,
        userInitiated: force,
        attemptElevated: force || reason == 'boot',
      );
      if (!forceReport.skipped) {
        done.add('force_install:${forceReport.ok}');
        done.addAll(forceReport.actions);
      }
    }

    if (chromeFail || edgeFail) {
      final ChromeExtensionSyncResult sync =
          await ChromeExtensionAutoSyncService.instance.syncIfNeeded(
        force: force || chromeFail,
        reason: 'tri_heal_$reason',
      );
      if (!sync.skipped) done.add('chrome_ext_sync');
      await ChromeBlockAutonomyService.instance.runOnce(
        reason: 'tri_heal',
        repair: true,
      );
      done.add('chrome_autonomy_repair');
    }

    if (ffFail) {
      try {
        final String? ffFolder =
            await _resolveFirefoxSource();
        if (ffFolder != null) {
          await FirefoxXpiPackager.instance.ensureProgramDataXpi(
            sourceFolder: ffFolder,
          );
          done.add('firefox_xpi_pack');
        }
        final List<String> profiles =
            await WindowsFirefoxExtensionInstallService.instance
                .installXpiToAllProfiles();
        if (profiles.isNotEmpty) done.add('firefox_profiles:${profiles.length}');
      } catch (e) {
        AppLogger.instance.warn('tri_heal firefox repair', error: e);
        done.add('firefox_repair_partial');
      }
    }

    final UniversalBlockResult pac =
        await UniversalBrowserBlockService.instance.syncNow(
      reason: 'tri_heal_$reason',
    );
    if (pac.ok) done.add('pac_sync');

    if (chromeFail || edgeFail || ffFail) {
      final AutonomousProtectionStatus auto =
          await AutonomousBrowserProtectionService.instance
              .ensureAllBrowsersProtected(
        reason: 'tri_heal_$reason',
        force: force,
      );
      done.addAll(auto.actions);
    }

    if (chromeFail || edgeFail) {
      final AutomatedHandoffResult handoff =
          await AutomatedBrowserHandoffService.instance.runZeroTouch(
        reason: 'tri_heal_$reason',
        force: force,
      );
      if (!handoff.skipped) {
        done.add('zero_touch_handoff');
        done.addAll(handoff.actions);
      }
    }

    WindowsExtensionGuardService.invalidateVerifyCache();
    return done;
  }

  Future<String?> _resolveFirefoxSource() async {
    final String pd = p.join(
      Platform.environment['ProgramData'] ?? r'C:\ProgramData',
      'SixVPNBlocker',
      'firefox',
    );
    if (await File(p.join(pd, 'manifest.json')).exists()) return pd;
    final String la = p.join(
      Platform.environment['LOCALAPPDATA'] ?? '',
      'SixVPNBlocker',
      'firefox_blocker',
    );
    if (await File(p.join(la, 'manifest.json')).exists()) return la;
    return null;
  }

  bool _repairAllowed() {
    if (_lastRepairAt == null) return true;
    return DateTime.now().difference(_lastRepairAt!) >= kRepairCooldown;
  }

  static String _verdictFor(List<BrowserHealthRow> rows) {
    final List<String> bad = rows
        .where((BrowserHealthRow r) => !r.ok && !r.skipped)
        .map((BrowserHealthRow r) => r.label)
        .toList();
    if (bad.isEmpty) return '일부 브라우저 점검 필요';
    return '${bad.join(' · ')} — 앱이 자동 복구·보호 브라우저 전환 중입니다.';
  }

  Future<void> _persist(TriBrowserHealReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      await File(reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (_) {}
  }
}

final class BrowserHealthRow {
  const BrowserHealthRow({
    required this.id,
    required this.label,
    required this.ok,
    required this.issues,
    required this.detail,
    this.skipped = false,
  });

  final String id;
  final String label;
  final bool ok;
  final bool skipped;
  final List<String> issues;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'label': label,
        'ok': ok,
        'skipped': skipped,
        'issues': issues,
        'detail': detail,
      };
}

final class TriBrowserHealReport {
  const TriBrowserHealReport({
    required this.at,
    required this.reason,
    required this.ok,
    required this.verdict,
    required this.browsers,
    required this.actions,
  });

  final DateTime at;
  final String reason;
  final bool ok;
  final String verdict;
  final List<BrowserHealthRow> browsers;
  final List<String> actions;

  BrowserHealthRow? row(String id) {
    for (final BrowserHealthRow r in browsers) {
      if (r.id == id) return r;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'reason': reason,
        'ok': ok,
        'verdict': verdict,
        'browsers': browsers.map((BrowserHealthRow r) => r.toJson()).toList(),
        'actions': actions,
      };
}
