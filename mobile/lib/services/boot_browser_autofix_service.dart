import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'automated_browser_handoff_service.dart';
import 'autonomous_browser_protection_service.dart';
import 'block_activity_log_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'browser_extension_force_install_service.dart';
import 'chrome_extension_payload_service.dart';
import 'work_context_tracker.dart';
import 'cursor_agent_fix_log_service.dart';
import 'crash_journal_service.dart';
import 'browser_apply_direct_verify_service.dart';
import 'hosts_health_probe_service.dart';
import 'network_url_block_service.dart';
import 'youtube_hosts_autofix_service.dart';
import 'protected_browser_realtime_guard_service.dart';
import 'tri_browser_self_heal_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_policy_acl_unlock_service.dart';
import 'boot_apply_idempotency_service.dart';
import 'installed_browsers_auto_apply_service.dart';
import 'windows_protection_mode_prefs.dart';

/// Zero-touch boot pipeline: PAC/URL rules → hosts repair → extension install →
/// Chrome/Edge/Firefox self-heal. Staggered and mutex-guarded to avoid UI lag.
final class BootBrowserAutofixService {
  BootBrowserAutofixService._();
  static final BootBrowserAutofixService instance = BootBrowserAutofixService._();

  static const Duration kBootPipelineCooldown = Duration(minutes: 6);
  static const Duration kResumePipelineCooldown = Duration(minutes: 10);

  bool _running = false;
  DateTime? _lastBootPipelineAt;
  DateTime? _lastResumePipelineAt;

  String get reportPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'boot_browser_autofix_last.json',
      );

  /// Legacy entry — [AutonomousApplyOrchestratorService] owns launch now.
  void scheduleOnLaunch({required bool postRebuildLight}) {}

  /// Lighter repair when app returns to foreground (rate-limited).
  void scheduleOnResume() {
    if (!Platform.isWindows) return;
    if (WorkContextTracker.instance.isBusy || _running) return;
    final DateTime now = DateTime.now();
    if (_lastResumePipelineAt != null &&
        now.difference(_lastResumePipelineAt!) < kResumePipelineCooldown) {
      return;
    }
    _lastResumePipelineAt = now;
    unawaited(runResumePipeline(reason: 'resume'));
  }

  Future<BootAutofixReport> runBootPipeline({
    required String reason,
    bool light = false,
    bool ignoreCooldown = false,
    bool skipYoutubeStep = false,
  }) async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return BootAutofixReport.skipped('수동 보호 꺼짐');
    }
    if (!Platform.isWindows) {
      return BootAutofixReport.skipped('Windows 전용');
    }
    if (!await BlockingSelfHealPrefs.instance.isEnabled()) {
      return BootAutofixReport.skipped('자가 점검 꺼짐');
    }
    if (_running) {
      return BootAutofixReport.skipped('이전 부트 복구 실행 중');
    }
    final DateTime now = DateTime.now();
    if (_lastBootPipelineAt != null &&
        !ignoreCooldown &&
        now.difference(_lastBootPipelineAt!) < kBootPipelineCooldown) {
      return BootAutofixReport.skipped('부트 복구 쿨다운');
    }

    _running = true;
    final List<String> steps = <String>[];
    final DateTime started = DateTime.now();

    try {
      return await WorkContextTracker.instance.run(
        'boot_browser_autofix.pipeline',
        () async {
      AppLogger.instance.info('boot_autofix: start light=$light reason=$reason');

      // 0) YouTube apex DNS (orchestrator may have already run this).
      if (!skipYoutubeStep) {
        final YoutubeHostsAutofixReport ytHosts =
            await YoutubeHostsAutofixService.instance.runAutofix(reason: reason);
        steps.add(ytHosts.ok ? 'youtube_dns_ok' : 'youtube_dns_repair');
      } else {
        steps.add('youtube_dns_orchestrator');
      }

      // 1) Network layer — no UAC, fast (PAC + HKCU URLBlocklist).
      await NetworkUrlBlockService.instance.enforceNow(reason: reason);
      steps.add('network_url_block');

      await Future<void>.delayed(const Duration(seconds: 2));

      // 2) hosts corruption → one UAC regenerate from DB (if needed).
      final bool hostsRepaired =
          await HostsHealthProbeService.instance.repairIfNeeded(reason: reason);
      steps.add(hostsRepaired ? 'hosts_repaired' : 'hosts_ok');

      // 3) HKCU Policies ACL — must run before registry writes land.
      try {
        await WindowsPolicyAclUnlockService.instance
            .runElevatedUnlockIfNeeded();
        steps.add('policy_acl');
      } catch (_) {
        steps.add('policy_acl_skip');
      }

      await ProtectedBrowserRealtimeGuardService.instance.syncScriptOnly();
      steps.add('guard_script');

      // 4) HKCU extension forcelist + payload (cheap).
      try {
        final String? folder =
            await ChromeExtensionPayloadService.resolveValidSource();
        if (folder != null) {
          await WindowsExtensionSelfHealService.instance
              .reapplyHkcuOnly(sourceFolder: folder);
          steps.add('hkcu_extension');
        }
      } catch (_) {
        steps.add('hkcu_extension_fail');
      }

      if (!light) {
        await Future<void>.delayed(const Duration(seconds: 4));
      }

      // 5) Full extension install/export (Chrome · Edge · Firefox).
      final BrowserExtensionForceInstallReport install =
          await BrowserExtensionForceInstallService.instance.installAll(
        reason: reason,
        force: !light,
        attemptElevated: !light,
      );
      steps.add(
        install.skipped ? 'ext_install_skipped' : 'ext_install_${install.ok}',
      );

      await Future<void>.delayed(light ? const Duration(seconds: 3) : const Duration(seconds: 6));

      // 6) Tri-browser diagnose + repair.
      final TriBrowserHealReport heal = await TriBrowserSelfHealService.instance
          .runCycle(reason: reason, repair: true);
      steps.add('tri_heal_${heal.ok}');

      if (!heal.ok && await BlockingSelfHealPrefs.instance.autoEasySetup()) {
        await Future<void>.delayed(const Duration(seconds: 4));
        final AutonomousProtectionStatus auto =
            await AutonomousBrowserProtectionService.instance
                .ensureAllBrowsersProtected(reason: reason, force: false);
        steps.add('autonomous_${auto.ok}');
      }

      if (!light && await BlockingSelfHealPrefs.instance.zeroTouchHandoff()) {
        await Future<void>.delayed(const Duration(seconds: 5));
        await AutomatedBrowserHandoffService.instance.runZeroTouch(
          reason: reason,
          force: false,
        );
        steps.add('zero_touch_handoff');
      }

      final InstalledBrowsersApplyReport allBrowsers =
          await InstalledBrowsersAutoApplyService.instance.applyAllInstalled(
        reason: reason,
        force: !light || reason.startsWith('launch'),
        showBanner: false,
      );
      steps.add(
        allBrowsers.skipped
            ? 'all_browsers_skip'
            : 'all_browsers_${allBrowsers.readyCount}/${allBrowsers.installedCount}',
      );

      final BrowserApplyDirectReport verify =
          await BrowserApplyDirectVerifyService.instance.verifyAndRepair(
        reason: reason,
      );
      steps.add(verify.ok ? 'direct_verify_ok' : 'direct_verify_fail');

      final BootAutofixReport report = BootAutofixReport(
        at: DateTime.now(),
        reason: reason,
        light: light,
        ok: heal.ok && verify.ok,
        steps: steps,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        triBrowser: heal,
        directVerify: verify,
      );
      await _persist(report);
      await CursorAgentFixLogService.instance.record(
        CursorAgentFixEntry(
          component: 'boot_browser_autofix',
          action: reason,
          ok: report.ok,
          verdict: report.summary,
          reason: reason,
          details: report.toJson(),
          failedLayers: report.ok
              ? const <String>[]
              : <String>['boot:${report.error ?? report.triBrowser?.verdict}'],
          appliedLayers: report.steps,
          fixesAttempted: report.steps,
        ),
      );
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: report.summary,
        data: report.toJson(),
        level: report.ok ? 'info' : 'warn',
        debounceKey: 'boot_autofix',
      );
      AppLogger.instance.info('boot_autofix: done ${report.summary}');
      _lastBootPipelineAt = DateTime.now();
      if (report.ok) {
        await BootApplyIdempotencyService.instance.recordSuccess(
          source: 'boot_browser_autofix_$reason',
          verdict: report.summary,
        );
      }
      return report;
        },
      );
    } catch (e, st) {
      AppLogger.instance.error('boot_autofix failed', error: e, stack: st);
      final BootAutofixReport fail = BootAutofixReport(
        at: DateTime.now(),
        reason: reason,
        light: light,
        ok: false,
        steps: <String>[...steps, 'error:$e'],
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: e.toString(),
      );
      await _persist(fail);
      return fail;
    } finally {
      _running = false;
    }
  }

  Future<BootAutofixReport> runResumePipeline({required String reason}) async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return BootAutofixReport.skipped('수동 보호 꺼짐');
    }
    if (!Platform.isWindows) {
      return BootAutofixReport.skipped('Windows 전용');
    }
    if (!await BlockingSelfHealPrefs.instance.isEnabled()) {
      return BootAutofixReport.skipped('자가 점검 꺼짐');
    }
    if (_running) {
      return BootAutofixReport.skipped('부트 복구 실행 중');
    }

    _running = true;
    final List<String> steps = <String>[];
    final DateTime started = DateTime.now();

    try {
      return await WorkContextTracker.instance.run(
        'boot_browser_autofix.resume',
        () async {
      await NetworkUrlBlockService.instance.enforceNow(reason: reason);
      steps.add('network');

      final HostsHealthStatus hosts = await HostsHealthProbeService.instance.probe();
      if (!hosts.ok) {
        await HostsHealthProbeService.instance.repairIfNeeded(reason: reason);
        steps.add('hosts_repair');
      }

      final TriBrowserHealReport heal = await TriBrowserSelfHealService.instance
          .runCycle(reason: reason, repair: true);
      steps.add('tri_heal_${heal.ok}');

      if (!heal.ok) {
        await BrowserExtensionForceInstallService.instance.installAll(
          reason: reason,
          force: false,
        );
        steps.add('ext_install_retry');
      }

      final BootAutofixReport report = BootAutofixReport(
        at: DateTime.now(),
        reason: reason,
        light: true,
        ok: heal.ok,
        steps: steps,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        triBrowser: heal,
      );
      await _persist(report);
      return report;
        },
      );
    } finally {
      _running = false;
    }
  }

  Future<void> _persist(BootAutofixReport report) async {
    try {
      final File f = File(reportPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (_) {}
  }
}

final class BootAutofixReport {
  BootAutofixReport({
    required this.at,
    required this.reason,
    required this.light,
    required this.ok,
    required this.steps,
    required this.durationMs,
    this.triBrowser,
    this.directVerify,
    this.error,
  });

  factory BootAutofixReport.skipped(String message) => BootAutofixReport(
        at: DateTime.now(),
        reason: 'skipped',
        light: true,
        ok: true,
        steps: <String>[message],
        durationMs: 0,
      );

  final DateTime at;
  final String reason;
  final bool light;
  final bool ok;
  final List<String> steps;
  final int durationMs;
  final TriBrowserHealReport? triBrowser;
  final BrowserApplyDirectReport? directVerify;
  final String? error;

  String get summary => ok
      ? '부트 자동 복구 OK (${steps.length}단계 · ${durationMs}ms)'
      : '부트 자동 복구 일부 실패 — ${error ?? triBrowser?.verdict ?? steps.join(", ")}';

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'reason': reason,
        'light': light,
        'ok': ok,
        'steps': steps,
        'durationMs': durationMs,
        'error': error,
        'triBrowser': triBrowser?.toJson(),
        'directVerify': directVerify?.toJson(),
        'summary': summary,
      };
}
