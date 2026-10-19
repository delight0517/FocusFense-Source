import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'block_probe_service.dart';
import 'block_sync_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'boot_apply_idempotency_service.dart';
import 'browser_block_enforcement_health_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'automated_browser_handoff_service.dart';
import 'autonomous_browser_protection_service.dart';
import 'chrome_extension_state_probe.dart';
import 'chrome_block_autonomy_service.dart';
import 'chrome_unification_service.dart';
import 'cursor_agent_fix_log_service.dart';
import 'crash_journal_service.dart';
import 'windows_extension_guard_service.dart';
import 'extension_rules_builder.dart';
import 'usage_ingest_server.dart';
import 'numeric_apex_hosts_gap_healer_service.dart';
import 'tri_browser_self_heal_service.dart';
import 'windows_protection_mode_prefs.dart';
import 'windows_extension_self_heal_service.dart';

/// Observe → probe sites → optional protected-browser test → repair → log.
///
/// Designed to be **light**: event-driven cycles, no periodic polling loop.
final class BlockingSelfHealAgentService {
  BlockingSelfHealAgentService._();
  static final BlockingSelfHealAgentService instance =
      BlockingSelfHealAgentService._();

  // @incident: boot_order_self_heal_race — 90s boot delay lets
  // earlier-priority services (hosts/DNS/extension layers) finish their own
  // boot-time apply before self-heal starts probing; 30-min cooldown avoids
  // fighting those same services mid-cycle.
  static const Duration kBootDelay = Duration(seconds: 90);
  static const Duration kRepairCooldown = Duration(minutes: 30);

  final ValueNotifier<SelfHealReport?> latest = ValueNotifier<SelfHealReport?>(
    null,
  );

  bool _cycleRunning = false;
  bool _allowBrowserProbes = true;
  DateTime? _lastRepairAt;

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'blocking_self_heal_last.json',
  );

  void start({
    bool skipInitialBootCycle = false,
    bool allowBrowserProbes = true,
  }) {
    _allowBrowserProbes = allowBrowserProbes;
    if (!Platform.isWindows && !Platform.isMacOS) return;
    if (!skipInitialBootCycle) {
      Future<void>.delayed(kBootDelay, () async {
        final BootApplySkipVerdict skip = await BootApplyIdempotencyService
            .instance
            .evaluateSkip(reason: 'boot');
        if (skip.skip) return;
        unawaited(runCycle(reason: 'boot'));
      });
    }
  }

  void stop() {}

  Future<SelfHealReport> runCycle({
    String reason = 'manual',
    bool userInitiated = false,
  }) async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return SelfHealReport(
        at: DateTime.now(),
        reason: reason,
        verdict: '수동 보호 꺼짐',
        ok: true,
        probes: const <SelfHealProbe>[],
        actions: const <String>['manual_protection_off'],
      );
    }
    if (_cycleRunning) {
      return latest.value ??
          SelfHealReport(
            at: DateTime.now(),
            reason: reason,
            verdict: '이전 주기 실행 중 — 잠시 후 다시 시도',
            ok: false,
            probes: const <SelfHealProbe>[],
            actions: const <String>[],
          );
    }
    if (!await BlockingSelfHealPrefs.instance.isEnabled() && !userInitiated) {
      return SelfHealReport(
        at: DateTime.now(),
        reason: reason,
        verdict: '자가 점검 꺼짐',
        ok: true,
        probes: const <SelfHealProbe>[],
        actions: const <String>[],
      );
    }

    _cycleRunning = true;
    try {
      final List<SelfHealProbe> probes = <SelfHealProbe>[];
      final List<String> actions = <String>[];

      if (!UsageIngestServer.instance.isRunning) {
        UsageIngestServer.instance.start();
        actions.add('rules_api_started');
      }

      final TriBrowserHealReport tri = await TriBrowserSelfHealService.instance
          .runCycle(
            reason: reason,
            userInitiated: userInitiated,
            repair: userInitiated || reason == 'boot' || reason == 'resume',
          );
      actions.addAll(tri.actions);

      if (Platform.isWindows) {
        final NumericApexHostsHealReport apex =
            await NumericApexHostsGapHealerService.instance.healIfNeeded(
              reason: 'self_heal_$reason',
              force: userInitiated || reason == 'boot',
              allowElevatedHosts: userInitiated,
            );
        actions.addAll(apex.actions);
        if (apex.probeHosts.isNotEmpty) {
          probes.add(
            SelfHealProbe(
              label: 'dns_numeric_apex',
              url: apex.probeHosts.first,
              ok: apex.ok,
              detail: apex.message,
            ),
          );
        }
      }

      for (final BrowserHealthRow row in tri.browsers) {
        probes.add(
          SelfHealProbe(
            label: row.id,
            url: row.label,
            ok: row.ok || row.skipped,
            detail: row.detail,
          ),
        );
      }

      final ChromeBlockStatus chrome = await ChromeBlockAutonomyService.instance
          .runOnce(repair: false);
      actions.addAll(chrome.actions);

      ExtensionPolicyVerifyResult policy =
          await WindowsExtensionGuardService.verifyAllPolicies();
      if (!policy.protectionOk &&
          await BlockingSelfHealPrefs.instance.autoEasySetup()) {
        final AutonomousProtectionStatus auto =
            await AutonomousBrowserProtectionService.instance
                .ensureAllBrowsersProtected(
                  reason: reason,
                  force: userInitiated,
                );
        actions.addAll(auto.actions);
        policy =
            auto.verify ??
            await WindowsExtensionGuardService.verifyAllPolicies(force: true);
      }

      BrowserEnforcementHealth before =
          await BrowserBlockEnforcementHealthService.instance.analyze();
      final ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildActiveNow();
      final List<_TestTarget> targets = _pickTargets(rules, maxCount: 2);

      for (final _TestTarget t in targets) {
        if (t.host != null) {
          final SiteBlockProbeReport r = await BlockProbeService.instance
              .probeHost(t.host!);
          probes.add(
            SelfHealProbe(
              label: t.label,
              url: t.displayUrl,
              ok: r.allOk,
              detail: r.verdict,
            ),
          );
        }
      }

      final bool wantBrowserProbe = await BlockingSelfHealPrefs.instance
          .browserProbeEnabled();
      if (Platform.isWindows &&
          (_allowBrowserProbes || userInitiated) &&
          wantBrowserProbe &&
          targets.isNotEmpty &&
          targets.first.browserUrl != null &&
          (userInitiated || before.needsUserAction)) {
        await ChromeUnificationService.instance.ensureUnifiedChrome(
          applyPolicies: false,
        );
        final bool opened =
            await ChromeLoadExtensionLauncher.openUrlInProtectedChrome(
              targets.first.browserUrl!,
            );
        actions.add(
          opened
              ? 'browser_probe:${targets.first.browserUrl}'
              : 'browser_probe_failed',
        );
        await Future<void>.delayed(const Duration(seconds: 4));
      }

      final bool shouldRepair =
          userInitiated ||
          before.needsUserAction ||
          probes.any((SelfHealProbe p) => !p.ok);

      if (shouldRepair && _repairAllowed()) {
        actions.addAll(await _repair(before));
        _lastRepairAt = DateTime.now();
        before = await BrowserBlockEnforcementHealthService.instance.analyze();
      }

      final bool ok =
          tri.ok &&
          !before.needsUserAction &&
          probes.every((SelfHealProbe p) => p.ok);

      final SelfHealReport report = SelfHealReport(
        at: DateTime.now(),
        reason: reason,
        verdict: ok ? tri.verdict : tri.verdict,
        ok: ok,
        enforcement: before,
        probes: probes,
        actions: actions,
      );

      latest.value = report;
      await _persist(report);
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: report.verdict,
        data: report.toJson(),
        level: ok ? 'info' : 'warn',
        debounceKey: 'self_heal_cycle',
      );
      AppLogger.instance.info(
        'self_heal [$reason] ok=$ok actions=$actions probes=${probes.length}',
      );
      return report;
    } catch (e, st) {
      AppLogger.instance.error('self_heal cycle failed', error: e, stack: st);
      final SelfHealReport fail = SelfHealReport(
        at: DateTime.now(),
        reason: reason,
        verdict: '자가 점검 오류: $e',
        ok: false,
        probes: const <SelfHealProbe>[],
        actions: const <String>['error'],
      );
      latest.value = fail;
      return fail;
    } finally {
      _cycleRunning = false;
    }
  }

  bool _repairAllowed() {
    if (_lastRepairAt == null) return true;
    return DateTime.now().difference(_lastRepairAt!) >= kRepairCooldown;
  }

  Future<List<String>> _repair(BrowserEnforcementHealth before) async {
    final List<String> done = <String>[];
    if (Platform.isWindows) {
      // Check Chrome Preferences directly — catches "no extension at all" cases
      // that process cmdline check misses (e.g. Chrome not currently running).
      final ChromeExtensionProbeResult prefsProbe =
          await ChromeExtensionStateProbe.probe(browser: 'chrome');
      if (prefsProbe.extensionNotPresent || !prefsProbe.properlyInstalled) {
        done.add(
          'chrome_prefs_probe:notPresent=${prefsProbe.extensionNotPresent}',
        );
      }

      final bool chromeOk =
          !prefsProbe.extensionNotPresent &&
          await AutomatedBrowserHandoffService.isChromeEffectivelyProtected();
      if (!chromeOk) {
        final AutomatedHandoffResult handoff =
            await AutomatedBrowserHandoffService.instance.runZeroTouch(
              reason: 'self_heal_repair',
              force: true,
            );
        done.addAll(handoff.actions);
      }
      final AutonomousProtectionStatus auto =
          await AutonomousBrowserProtectionService.instance
              .ensureAllBrowsersProtected(reason: 'repair');
      done.addAll(auto.actions);

      if (!auto.ok) {
        await ChromeUnificationService.instance.ensureUnifiedChrome(
          applyPolicies: true,
        );
        done.add('chrome_unify_policies');

        final ExtensionSelfHealResult heal =
            await WindowsExtensionSelfHealService.instance.runIfNeeded(
              attemptElevated: false,
            );
        if (heal.hkcuApplied) done.add('hkcu_heal');
      }
    }
    BlockSyncService.instance.requestApply();
    done.add('block_sync');
    return done;
  }

  List<_TestTarget> _pickTargets(
    ExtensionRulesPayload rules, {
    int maxCount = 2,
  }) {
    final List<_TestTarget> out = <_TestTarget>[];
    for (final String vid in rules.blockedYoutubeVideoIds) {
      if (out.length >= maxCount) break;
      final String id = vid.trim();
      if (id.isEmpty) continue;
      out.add(
        _TestTarget(
          label: 'video',
          displayUrl: 'https://www.youtube.com/watch?v=$id',
          browserUrl: 'https://www.youtube.com/watch?v=$id',
          host: null,
        ),
      );
    }
    for (final String k in rules.keywords) {
      if (out.length >= maxCount) break;
      final String? url = _youtubeUrlFromKeyword(k);
      if (url != null) {
        out.add(
          _TestTarget(
            label: 'keyword',
            displayUrl: url,
            browserUrl: url,
            host: null,
          ),
        );
      }
    }
    for (final String d in rules.blockedDomains) {
      if (out.length >= maxCount) break;
      final String host = d.trim().toLowerCase();
      if (host.isEmpty) continue;
      out.add(
        _TestTarget(
          label: 'domain',
          displayUrl: 'https://$host/',
          browserUrl: 'https://$host/',
          host: host,
        ),
      );
    }
    if (out.isEmpty) {
      out.add(
        _TestTarget(
          label: 'canary',
          displayUrl: kDiagnosticBlockSentinelHost,
          browserUrl: 'https://$kDiagnosticBlockSentinelHost/',
          host: kDiagnosticBlockSentinelHost,
        ),
      );
    }
    return out;
  }

  String? _youtubeUrlFromKeyword(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return null;
    final RegExp vid = RegExp(r'(?:v=|/)([\w-]{11})');
    final RegExpMatch? m = vid.firstMatch(s);
    if (m != null) {
      return 'https://www.youtube.com/watch?v=${m.group(1)}';
    }
    if (s.contains('youtube.com') || s.contains('youtu.be')) {
      return s.startsWith('http') ? s : 'https://$s';
    }
    if (s.startsWith('@')) {
      return 'https://www.youtube.com/${s.replaceFirst('@', '@')}';
    }
    return null;
  }

  Future<void> _persist(SelfHealReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      final File f = File(reportPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
      final List<String> failed = report.probes
          .where((SelfHealProbe p) => !p.ok)
          .map((SelfHealProbe p) => '${p.label}:${p.detail}')
          .toList();
      await CursorAgentFixLogService.instance.record(
        CursorAgentFixEntry(
          component: 'blocking_self_heal',
          action: report.reason,
          ok: report.ok,
          verdict: report.verdict,
          reason: report.reason,
          details: report.toJson(),
          failedLayers: failed,
          appliedLayers: report.actions,
          fixesAttempted: report.actions,
        ),
      );
    } catch (_) {}
  }
}

final class SelfHealReport {
  const SelfHealReport({
    required this.at,
    required this.reason,
    required this.verdict,
    required this.ok,
    this.enforcement,
    required this.probes,
    required this.actions,
  });

  final DateTime at;
  final String reason;
  final String verdict;
  final bool ok;
  final BrowserEnforcementHealth? enforcement;
  final List<SelfHealProbe> probes;
  final List<String> actions;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'reason': reason,
    'verdict': verdict,
    'ok': ok,
    if (enforcement != null) 'enforcementPhase': enforcement!.phase.name,
    'probes': probes.map((SelfHealProbe p) => p.toJson()).toList(),
    'actions': actions,
  };
}

final class SelfHealProbe {
  const SelfHealProbe({
    required this.label,
    required this.url,
    required this.ok,
    required this.detail,
  });

  final String label;
  final String url;
  final bool ok;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'url': url,
    'ok': ok,
    'detail': detail,
  };
}

final class _TestTarget {
  const _TestTarget({
    required this.label,
    required this.displayUrl,
    required this.browserUrl,
    required this.host,
  });

  final String label;
  final String displayUrl;
  final String? browserUrl;
  final String? host;
}
