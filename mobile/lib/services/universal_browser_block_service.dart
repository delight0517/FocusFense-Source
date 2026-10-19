import 'dart:async';
import 'dart:io';

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'browser_block_health_monitor_service.dart';
import 'browser_live_url_block_gate_service.dart';
import 'cpu_spike_detector_service.dart';
import 'easy_setup_bulletproof_prefs.dart';
import 'extension_rules_builder.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart';
import 'extension_rules_snapshot_service.dart';
import 'tier_enforcement_service.dart';
import 'windows_browser_proxy_policy_service.dart';
import 'windows_chromium_registry_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_chrome_easy_block_service.dart';
import 'windows_hkcu_policy_service.dart';
import 'automated_browser_handoff_service.dart';
import 'chrome_channel_apply_probe_service.dart';
import 'edge_channel_apply_probe_service.dart';
import 'firefox_channel_apply_probe_service.dart';
import 'chrome_url_block_reload_orchestrator_service.dart';
import 'unprotected_browser_kill_guard_service.dart';
import '../models/cross_browser_leak_scenario.dart';
import 'chrome_gmail_gemini_allowlist_service.dart';
import 'cross_browser_url_leak_guard_service.dart';
import 'windows_firefox_extension_install_service.dart';
import 'youtube_policy_layer_gap_healer.dart';
import 'brave_extension_install_service.dart';
import 'chromium_derivative_extension_service.dart';
import 'windows_protection_mode_prefs.dart';

/// Layer 0 (PAC, all browsers) + tiers 1–3 + extension — no UAC.
final class UniversalBrowserBlockService {
  UniversalBrowserBlockService._();
  static final UniversalBrowserBlockService instance =
      UniversalBrowserBlockService._();

  static const Duration _pacDebounce = Duration(seconds: 2);
  Timer? _pacTimer;

  // Mutex against overlapping syncNow runs. Two concurrent syncs would
  // each call `reg.exe delete /f` on URLBlocklist then start re-adding —
  // the second `delete` runs in the middle of the first's re-add, leaving
  // the registry with only a partial slice (the user saw 24 of 1000
  // entries after this race fired). Plus the overlap doubles the
  // child-process spawn rate, contributing directly to lag.
  Completer<UniversalBlockResult>? _inFlight;
  DateTime? _lastSyncAt;
  // Minimum gap between syncs. If a caller asks for one within this window
  // of the previous, we return the previous result instead of re-running.
  // The watchdog tick / one-tap UI / requestApply / rule-edits all funnel
  // through here; coalescing prevents the spawn storm.
  static const Duration _kMinSyncGap = Duration(seconds: 15);
  UniversalBlockResult? _lastResult;

  /// Debounced PAC + tiers when rules change.
  void scheduleSync({String reason = 'rules'}) {
    if (!Platform.isWindows) return;
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      _pacTimer?.cancel();
      return;
    }
    _pacTimer?.cancel();
    _pacTimer = Timer(_pacDebounce, () {
      unawaited(syncNow(reason: reason));
    });
  }

  /// Immediate: system PAC (Chrome/Edge/Firefox) + 3-tier + realtime guard.
  Future<UniversalBlockResult> syncNow({String reason = 'manual'}) async {
    if (!Platform.isWindows) {
      return const UniversalBlockResult(ok: true, message: 'Windows 전용');
    }
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      _pacTimer?.cancel();
      return const UniversalBlockResult(
        ok: true,
        message: '수동 보호가 꺼져 있어 차단 정책 적용을 건너뜁니다.',
        steps: <String>['manual_protection_off'],
      );
    }
    // If a sync is already in flight, latch onto it instead of starting a
    // second one. This is what stops the 1001→24 entry truncation race.
    final Completer<UniversalBlockResult>? existing = _inFlight;
    if (existing != null) {
      AppLogger.instance.info(
        'universal_block: coalescing sync (in-flight, reason=$reason)',
      );
      return existing.future;
    }
    // If a sync just finished, return its result for callers within the
    // gap — avoids the watchdog firing one every minute even though the
    // user hasn't changed anything.
    final DateTime? last = _lastSyncAt;
    final UniversalBlockResult? lastRes = _lastResult;
    if (last != null &&
        lastRes != null &&
        DateTime.now().difference(last) < _kMinSyncGap &&
        reason != 'one_tap' &&
        reason != 'live_card' &&
        reason != 'url_test' &&
        !reason.startsWith('installed_browsers_')) {
      AppLogger.instance.info(
        'universal_block: reusing recent sync (gap=${DateTime.now().difference(last).inSeconds}s, reason=$reason)',
      );
      return lastRes;
    }
    final Completer<UniversalBlockResult> completer =
        Completer<UniversalBlockResult>();
    _inFlight = completer;
    // Tell the CPU spike detector who's running. If a spike fires while
    // this label is active, the captured report names this service so the
    // AI agent / user knows the culprit.
    final String activityLabel = 'universal_browser_block.syncNow($reason)';
    CpuSpikeDetectorService.instance.noteActivity(activityLabel);
    try {
      ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildForBrowserEnforcement();
      if (_hasYoutubeBlocks(rules)) {
        final int policyHealed = await YoutubePolicyLayerGapHealer.instance
            .healFromRules(rules);
        if (policyHealed > 0) {
          rules = await ExtensionRulesBuilder.buildForBrowserEnforcement();
        }
      }
      final bool hasYoutube = _hasYoutubeBlocks(rules);
      final bool hasAny =
          rules.blockedDomains.isNotEmpty ||
          rules.keywords.isNotEmpty ||
          rules.searchQueries.isNotEmpty;

      if (!hasAny) {
        await WindowsEmergencyBlockService.instance.removePac();
        await WindowsBrowserProxyPolicyService.instance.clearChromiumPac();
        await WindowsBrowserProxyPolicyService.instance.setYoutubeEnforceActive(
          false,
        );
        return const UniversalBlockResult(
          ok: true,
          message: '활성 규칙 없음 — PAC 해제',
        );
      }

      await WindowsBrowserProxyPolicyService.instance.setYoutubeEnforceActive(
        hasYoutube,
      );

      final EmergencyBlockResult pac = await WindowsEmergencyBlockService
          .instance
          .applyFromRules(rules);
      final String pacFile =
          pac.pacPath ?? WindowsEmergencyBlockService.pacPath();
      final bool proxyPolicy =
          await WindowsChromiumRegistryService.instance
              .ensureChromiumEnforcement(pacPath: pacFile) ||
          await WindowsBrowserProxyPolicyService.instance.forceChromiumPac(
            pacPath: pacFile,
          );
      final HkcuPolicyResult hkcu = await WindowsHkcuPolicyService.instance
          .applyNow();
      final bool gmailGeminiOnly = await ChromeGmailGeminiAllowlistService
          .instance
          .enabled();
      // Bypass closer: URLAllowlist sweep, derivative Chromium browsers
      // (Whale/Brave/Vivaldi/Opera/EdgeBeta/EdgeDev/Chromium), incognito-mode
      // disable, ExtensionInstallBlocklist scrub. Failure here does not
      // abort — base Chrome/Edge/Firefox are already applied above.
      final CrossBrowserLeakGuardReport leakGuard =
          await CrossBrowserUrlLeakGuardService.instance.sealAll(
            reason: reason,
          );
      if (gmailGeminiOnly) {
        await ChromeGmailGeminiAllowlistService.instance.applyNow();
      }

      final List<String> steps = <String>[
        if (pac.pacApplied) 'pac_ok' else 'pac_fail',
        if (proxyPolicy) 'chrome_edge_pac_policy' else 'chrome_edge_pac_fail',
        if (hkcu.success) 'hkcu_url_blocklist' else 'hkcu_blocklist_fail',
        'hkcu_targets=${hkcu.targets.join(",")}',
        if (gmailGeminiOnly) 'chrome_gmail_gemini_only',
        'pac_yt=$hasYoutube',
        'leak_guard=${leakGuard.sealed.length}/5',
        if (leakGuard.ok) 'leak_guard_ok' else 'leak_guard_partial',
        ...leakGuard.steps,
      ];

      // NOTE: we deliberately do NOT kill/restart Firefox here anymore. Force-
      // closing the user's browser to reload policy is the root of the "브라우저
      // 가 시도때도 없이 꺼진다" complaint. Newly added blocks apply on the next
      // Firefox launch (and immediately via the content script if the extension
      // is loaded). The URLBlocklist/WebsiteFilter policy is written regardless.

      if (hasAny) {
        await EasySetupBulletproofPrefs.instance.setAll(
          hijackShortcuts: true,
          browserWatchdog: true,
          forceEnterprisePolicies: true,
          realtimeBrowserGuard: false,
        );
        steps.add('bulletproof_on_nonkill');

        await ExtensionRulesSnapshotService.instance.writeToChromePayload();
        steps.add('snapshot');
        if (hasYoutube) {
          try {
            await WindowsFirefoxExtensionInstallService.instance
                .applyHkcuExtensionPolicy();
            steps.add('firefox_xpi_hkcu');
          } catch (e) {
            AppLogger.instance.warn(
              'firefox hkcu extension apply failed',
              error: e,
            );
            steps.add('firefox_xpi_hkcu_fail');
          }
          try {
            await ChromeChannelApplyProbeService.instance.repairForHandle(
              'sync_now',
            );
            steps.add('chrome_ext_hkcu');
          } catch (e) {
            AppLogger.instance.warn(
              'chrome hkcu extension apply failed',
              error: e,
            );
            steps.add('chrome_ext_hkcu_fail');
          }
          try {
            await EdgeChannelApplyProbeService.instance.repairForHandle(
              'sync_now',
            );
            steps.add('edge_ext_hkcu');
          } catch (e) {
            AppLogger.instance.warn(
              'edge hkcu extension apply failed',
              error: e,
            );
            steps.add('edge_ext_hkcu_fail');
          }
          try {
            await FirefoxChannelApplyProbeService.instance.repairForHandle(
              'sync_now',
            );
            steps.add('firefox_channel_repair');
          } catch (e) {
            AppLogger.instance.warn('firefox channel repair failed', error: e);
            steps.add('firefox_channel_repair_fail');
          }
        }

        final String? folder =
            await ChromeExtensionPayloadService.ensureStablePayload();
        if (folder != null && folder.isNotEmpty) {
          await ChromeLoadExtensionLauncher.install(extensionFolder: folder);
          await ChromeLoadExtensionLauncher.refreshChromiumLaunchersFromDisk();
          steps.add('launchers_pac');

          final bool edgeLocked = await WindowsChromiumRegistryService.instance
              .isEdgeHkcuPolicyLocked();
          final bool edgePolicyMissing = !hkcu.targets.contains('Edge');
          if (edgeLocked || edgePolicyMissing || !proxyPolicy) {
            final ShortcutHijackResult hijack =
                await ChromeShortcutHijackService.instance.apply(
                  extensionFolder: folder,
                  force: true,
                );
            steps.add(
              edgeLocked
                  ? 'edge_hijack_corp_lock:${hijack.patchedCount}'
                  : 'edge_hijack:${hijack.patchedCount}',
            );
          }

          final TierEnforcementResult tier = await TierEnforcementService
              .instance
              .installAllTiers(
                extensionFolder: folder,
                force: hasYoutube || edgeLocked,
              );
          steps.addAll(tier.steps);
          await TierEnforcementService.instance.runTier3Once();
          steps.add('tier3_once_nonkill');
        }
      }

      final bool enforced = pac.pacApplied || proxyPolicy || hkcu.success;
      final String msg = enforced
          ? (hasYoutube
                ? '✅ 전 브라우저 차단: PAC + Chrome정책 URL목록 + 3단계'
                : '✅ 전 브라우저 PAC + URL 차단 목록')
          : '⚠️ 일부 레이어 실패 — Chrome 완전 종료 후 앱 「Chrome 열기」';

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.protection,
        message: '$msg ($reason)',
        data: <String, Object?>{'steps': steps, 'hasYoutube': hasYoutube},
        debounceKey: 'universal_block',
      );
      AppLogger.instance.info('universal_block: $msg steps=$steps');

      if (hasYoutube && enforced) {
        final BrowserProcessProbe probe =
            await AutomatedBrowserHandoffService.probeBrowsers();
        if (probe.chromeUnprotected || !probe.chromeRunning) {
          await WindowsChromeEasyBlockService.instance
              .ensureChromeBlocksYoutube(reason: reason, force: false);
          steps.add('chrome_easy_handoff');
        }
      }

      if (hasAny) {
        try {
          await BraveExtensionInstallService.instance.apply(
            reason: reason,
            force: false,
          );
          await ChromiumDerivativeExtensionService.instance.applyAllInstalled(
            reason: reason,
            force: false,
          );
          steps.add('derivative_brave_ext');
        } catch (e) {
          AppLogger.instance.warn('derivative ext during sync failed: $e');
          steps.add('derivative_ext_fail');
        }
      }

      // Tell the health monitor a fresh policy was just written. It probes
      // each browser shortly after to flag "process predates policy" cases
      // and writes the agent prompt / user nudge.
      BrowserBlockHealthMonitorService.instance.notifyPolicyApplied();
      UnprotectedBrowserKillGuardService.instance.notifyPolicyApplied();
      // Live headless probe — browsers that leak test URLs go on hard-kill roster.
      unawaited(
        BrowserLiveUrlBlockGateService.instance
            .runLiveTest(applyPolicyFirst: false, reason: 'post_sync_$reason')
            .then((BrowserLiveUrlBlockGateReport gate) {
              if (!gate.ok && gate.hardKillIds.isNotEmpty) {
                UnprotectedBrowserKillGuardService.instance
                    .notifyPolicyApplied();
              }
            }),
      );
      ChromeUrlBlockReloadOrchestratorService.instance.notifyPolicyApplied();

      final UniversalBlockResult okResult = UniversalBlockResult(
        ok: enforced || hasYoutube,
        message: msg,
        pacApplied: pac.pacApplied,
        steps: steps,
      );
      _lastResult = okResult;
      _lastSyncAt = DateTime.now();
      completer.complete(okResult);
      return okResult;
    } catch (e, st) {
      AppLogger.instance.error('universal_block failed', error: e, stack: st);
      final UniversalBlockResult err = UniversalBlockResult(
        ok: false,
        message: '범용 차단 동기화 실패: $e',
      );
      _lastResult = err;
      _lastSyncAt = DateTime.now();
      completer.complete(err);
      return err;
    } finally {
      _inFlight = null;
      CpuSpikeDetectorService.instance.clearActivity(activityLabel);
    }
  }

  bool _hasYoutubeBlocks(ExtensionRulesPayload rules) {
    if (rules.hasYoutubeChannelBlocks) return true;
    for (final String k in rules.keywords) {
      final String s = k.toLowerCase();
      if (s.contains('youtube.com') ||
          s.contains('youtu.be') ||
          s.contains('watch?v=')) {
        return true;
      }
    }
    return false;
  }
}

final class UniversalBlockResult {
  const UniversalBlockResult({
    required this.ok,
    required this.message,
    this.pacApplied = false,
    this.steps = const <String>[],
  });

  final bool ok;
  final String message;
  final bool pacApplied;
  final List<String> steps;
}
