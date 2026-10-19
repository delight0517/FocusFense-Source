import 'dart:async';
import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import 'enforcement/enforcement_bootstrap.dart';
import 'enforcement/enforcement_controller.dart';
import 'init_sqflite_desktop.dart';
import 'localization/app_i18n.dart';
import 'router/app_router.dart';
import 'services/app_block_user_notice_service.dart';
import 'services/app_force_restart_notice_service.dart';
import 'services/blocked_browser_launch_notice_service.dart';
import 'services/firefox_extension_integrity_guard_service.dart';
import 'services/app_logger.dart';
import 'services/block_activity_log_service.dart';
import 'services/autonomous_apply_orchestrator_service.dart';
import 'services/chrome_block_autonomy_service.dart';
import 'services/extension_rules_snapshot_service.dart';
import 'services/universal_browser_block_service.dart';
import 'services/tier_enforcement_service.dart';
import 'services/blocking_ecosystem_scan_service.dart';
import 'services/blocking_ecosystem_status_launcher_service.dart';
import 'services/browser_block_health_monitor_service.dart';
import 'services/browser_live_url_block_gate_service.dart';
import 'services/blocking_self_heal_agent_service.dart';
import 'services/block_sync_service.dart';
import 'services/windows_protection_mode_prefs.dart';
import 'services/backup_service.dart';
import 'services/brainwire_blocklist_sync_service.dart';
import 'services/crash_journal_service.dart';
import 'services/app_lag_detector_service.dart';
import 'services/browser_enforcement_readiness_service.dart';
import 'services/browser_exit_watcher_service.dart';
import 'services/default_browser_promoter_service.dart';
import 'services/chrome_url_block_reload_orchestrator_service.dart';
import 'services/unprotected_browser_kill_guard_service.dart';
import 'services/cpu_spike_detector_service.dart';
import 'services/cursor_agent_snapshot_service.dart';
import 'services/severe_lag_session_service.dart';
import 'services/youtube_proactive_guard_service.dart';
import 'services/build_identity_service.dart';
import 'services/locale_controller.dart';
import 'services/quick_block_session_service.dart';
import 'services/windows_desktop_rebuild_service.dart';
import 'services/toast_click_watcher_service.dart';
import 'services/windows_tray_controller.dart';
import 'services/windows_hidden_process.dart';
import 'services/windows_duplicate_instance_guard.dart';
import 'services/windows_single_instance.dart';
import 'services/chrome_browser_watchdog_service.dart';
import 'services/automated_browser_handoff_service.dart';
import 'services/boot_apply_idempotency_service.dart';
import 'services/chrome_shortcut_boot_repair_service.dart';
import 'services/chat_schedule_apply_service.dart';
import 'services/easy_setup_bulletproof_prefs.dart';
import 'services/protected_browser_realtime_guard_service.dart';
import 'services/post_rebuild_bootstrap_service.dart';
import 'services/rebuild_preferences_service.dart';
import 'services/rebuild_auto_shower_service.dart';
import 'services/windows_rebuild_monitor.dart';
import 'services/windows_five_layer_block_service.dart';
import 'services/windows_five_layer_experiment_service.dart';
import 'services/protection_gap_resume_notifier.dart';
import 'services/trusted_time_service.dart';
import 'services/windows_os_integration_service.dart';
import 'services/windows_hkcu_policy_service.dart';
import 'services/extension_keepalive_service.dart';
import 'services/agent_destruct_gate_service.dart';
import 'services/agent_tamper_watchdog_service.dart';
import 'services/browser_install_safety_service.dart';
import 'services/installed_browsers_auto_apply_service.dart';
import 'services/new_browser_install_watcher_service.dart';
import 'services/windows_extension_policy_watchdog.dart';
import 'services/windows_watchdog_service.dart';
import 'services/local_database.dart';
import 'services/lock_schedule_enforcement.dart';
import 'services/pending_share_ingest.dart';
import 'services/delayed_rule_removal_service.dart';
import 'services/usage_ingest_server.dart';
import 'services/usage_quota_enforcer_service.dart';
import 'services/usage_tracking_service.dart';
import 'services/app_freeze_monitor.dart';
import 'theme/app_theme.dart';
import 'widgets/post_rebuild_activation_listener.dart';
import 'widgets/severe_lag_overlay.dart';
import 'widgets/windows_rebuild_progress_overlay.dart';

bool get _isFlutterTest => Platform.environment['FLUTTER_TEST'] == 'true';

bool get _windowsTrayShell => Platform.isWindows && !_isFlutterTest;

bool _backgroundLaunch = false;

Future<void> main(List<String> args) async {
  _backgroundLaunch = args.contains('--background');
  WidgetsFlutterBinding.ensureInitialized();
  // Silence the modal "reg.exe - Application Error (0xc0000142)" dialog: every
  // child process inherits this quiet error mode at creation.
  suppressChildProcessErrorDialogs();
  // Guarantee exactly ONE running copy. A stray second instance (e.g. a
  // double-launch during an in-app rebuild) would steal the rules HTTP port
  // and lock the DB, which is what makes the block collapse after updating.
  if (!_isFlutterTest &&
      !acquireSingleInstanceOrSurfaceExisting(
        surfaceExisting: !_backgroundLaunch,
      )) {
    exit(0);
  }
  if (Platform.isWindows && !_isFlutterTest) {
    await WindowsDuplicateInstanceGuard.dedupeSiblings();
  }
  final bool protectionPaused =
      WindowsProtectionModePrefs.isProtectionExplicitlyOff;
  BlockSyncService.instance.enabled = !protectionPaused;
  EnforcementController.instance.enabled = !protectionPaused;
  ensureSqfliteDesktopInitialized();
  await bootstrapEnforcementController();
  try {
    final String tag = await BuildIdentityService.instance.summaryLine();
    AppLogger.instance.setLogTag(tag);
    CrashJournalService.instance.setLogTag(tag);
    CrashJournalService.instance.record(
      kind: 'boot',
      message:
          'Diagnostics tag bound (every log line / crash row includes appBuild)',
    );
  } catch (_) {
    /* package_info may fail in odd embedders */
  }
  if (!_isFlutterTest) {
    unawaited(CrashJournalService.instance.warmup());
  }
  if (_windowsTrayShell) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }

  runZonedGuarded<void>(
    () {
      AppLogger.instance.info('app launched');

      // Capture Flutter framework errors.
      final FlutterExceptionHandler? prev = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        final msg = details.exceptionAsString();
        CrashJournalService.instance.recordFlutterError(
          details.exception,
          details.stack ?? StackTrace.empty,
        );
        AppLogger.instance.error(
          'FlutterError: $msg',
          error: details.exception,
          stack: details.stack,
        );
        // 자동 진단: 특정 패턴 감지
        if (msg.contains('MaterialLocalizations')) {
          AppLogger.instance.warn(
            '[AutoDiagnostic] MaterialLocalizations missing',
          );
        }
        if (msg.contains('Null check operator')) {
          AppLogger.instance.warn('[AutoDiagnostic] Null pointer exception');
        }
        prev?.call(details);
      };

      // Capture platform-dispatcher-level errors (async, no zone).
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        CrashJournalService.instance.recordDispatcherError(error, stack);
        AppLogger.instance.error(
          'PlatformDispatcher error',
          error: error,
          stack: stack,
        );
        return false;
      };

      runApp(const ProviderScope(child: VpnImageBlockerApp()));
      if (Platform.isWindows &&
          !_isFlutterTest &&
          !_backgroundLaunch &&
          !WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
        scheduleMicrotask(() {
          AutonomousApplyOrchestratorService.instance.scheduleOnLaunch(
            postRebuildLight: true,
          );
        });
      }
      AppFreezeMonitor.instance.start();
      SevereLagSessionService.instance.start();
      scheduleMicrotask(() async {
        try {
          AppLogger.instance.info(
            'build identity: ${await BuildIdentityService.instance.summaryLine()}',
          );
        } catch (_) {
          /* best-effort */
        }
      });
    },
    (Object error, StackTrace stack) {
      CrashJournalService.instance.recordZoneError(error, stack);
      AppLogger.instance.error(
        'Uncaught zone error',
        error: error,
        stack: stack,
      );
    },
  );
}

class VpnImageBlockerApp extends StatefulWidget {
  const VpnImageBlockerApp({super.key, this.testMode = false});

  /// Builds the app shell without starting OS hooks or loading production
  /// routes. Intended only for widget smoke tests.
  final bool testMode;

  @override
  State<VpnImageBlockerApp> createState() => _VpnImageBlockerAppState();
}

/// Named boot-stagger delays (see docs/BLOCK_ENGINE_DISORDER_AUDIT_2026-07-05.md
/// §5 — "질서 없음: 부팅 매직 딜레이"). These are still fixed second-counts, not
/// a real boot-complete signal, but naming/grouping them here makes the full
/// set of ~17 values visible and documented in one place instead of scattered
/// unexplained literals through the boot functions below — so a collision
/// (e.g. two unrelated timers both happening to use the same N seconds) is
/// obvious at a glance instead of hidden. Values are unchanged from before
/// this cleanup; reordering/replacing them with a real readiness signal is
/// out of scope for this pass (that's the Phase-7 rewrite, deliberately not
/// undertaken now — see project_enforcement_architecture memory).
abstract final class _BootDelays {
  /// `_bootShortcutRepairImmediate` — let first frame settle before touching
  /// desktop shortcuts.
  static const Duration shortcutRepair = Duration(seconds: 5);

  /// `_bootWindowsServicesStaggered` fresh-install path — gap before starting
  /// the watchdog/keepalive block.
  static const Duration freshInstallWatchdogGap = Duration(seconds: 12);

  /// `_bootBrowserStatusSync` — health probe + ecosystem scan, after
  /// `_bootWindowsServicesStaggered`'s earlier awaits have settled.
  static const Duration browserStatusProbe = Duration(seconds: 18);

  /// `_bootWindowsServicesStaggered` bootstrapped (returning-user) path —
  /// realtime guard start.
  static const Duration returningUserRealtimeGuard = Duration(seconds: 20);

  /// `_bootUsageIngest` — early five-layer sync so URL rules land quickly.
  static const Duration fiveLayerSyncEarly = Duration(seconds: 8);

  /// `_bootUsageIngest` — required-policy check + conditional resync.
  static const Duration requiredPolicyCheck = Duration(seconds: 12);

  /// `_bootUsageIngest` — Chrome URL-block reload orchestrator start.
  static const Duration chromeReloadOrchestrator = Duration(seconds: 28);

  /// `_bootWindowsServicesStaggered` — five-layer catch-up sync (both fresh
  /// and returning paths).
  static const Duration fiveLayerSyncCatchUp = Duration(seconds: 35);

  /// `_bootUsageIngest` — cursor/claude diagnostics snapshot start.
  static const Duration cursorSnapshot = Duration(seconds: 60);

  /// `_bootUsageIngest` — browser block health monitor passive start.
  static const Duration healthMonitorStart = Duration(seconds: 65);

  /// `_bootUsageIngest` — unprotected-browser kill guard start.
  static const Duration killGuardStart = Duration(seconds: 70);

  /// `_bootUsageIngest` — YouTube proactive guard start.
  static const Duration youtubeGuardStart = Duration(seconds: 75);

  /// `_bootWindowsServicesStaggered` fresh-install path — gap before
  /// realtime guard + self-heal start.
  static const Duration freshInstallRealtimeGuard = Duration(seconds: 90);

  /// `_bootWindowsServicesStaggered` — five-layer experiment run (both
  /// fresh and returning paths, latest of the boot-stagger set).
  static const Duration fiveLayerExperiment = Duration(seconds: 95);
}

class _VpnImageBlockerAppState extends State<VpnImageBlockerApp>
    with WidgetsBindingObserver, WindowListener {
  late final GoRouter _router = createAppRouter();
  final PendingShareIngest _shareIngest = PendingShareIngest();
  final LocaleController _localeController = LocaleController.instance;
  Timer? _appBlockTimer;
  Timer? _quickBlockTimer;
  Timer? _backupPulseTimer;
  Timer? _firefoxIntegrityTimer;

  bool get _isTestShell => widget.testMode || _isFlutterTest;
  bool get _windowsTrayShellForThisApp => Platform.isWindows && !_isTestShell;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_windowsTrayShellForThisApp) {
      windowManager.addListener(this);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(WindowsTrayController.instance.init());
      });
    }
    if (!_isTestShell) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _bootDelayedRuleRemovals(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _ingestShares());
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _enforceScheduleLock(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrapBackup());
      WidgetsBinding.instance.addPostFrameCallback((_) => _purgeOldTrash());
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootAppBlock());
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _bootQuickBlockSession(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootUsageTracking());
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootUsageIngest());
      if (!WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // If this launch is an involuntary restart (force-kill → watchdog
          // respawn), explain it with the branded toast, then begin the
          // heartbeat that lets the NEXT launch make the same call.
          unawaited(
            AppForceRestartNoticeService.instance
                .detectAndNotifyOnLaunch()
                .whenComplete(AppForceRestartNoticeService.instance.start),
          );
          // Keep the corrected branded IFEO blocked-browser toast staged so the
          // next elevated apply copies it into ProgramData (the old script there
          // used a suppressed native toast + mojibake → blocked browsers opened
          // nothing with no explanation).
          unawaited(
            BlockedBrowserLaunchNoticeService.instance.deployStagingScript(),
          );
        });
      }
      if (!WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(BlockActivityLogService.instance.start());
          AppBlockUserNoticeService.instance.start();
          // Watches for browser exits NOT initiated by this app — surfaces
          // "외부 원인 종료" notice so users aren't left wondering why their
          // browser disappeared. Cross-checks OwnKillLedger to skip self-
          // inflicted exits. 30 s tick, 1 tasklist.exe per tick (well under
          // the CLAUDE.md performance budget).
          BrowserExitWatcherService.instance.start();
          // Watches for a click on the branded block toast and, when it fires,
          // brings the app to the front + opens the "지금 무엇이 차단 중" dialog so
          // the user instantly sees which block/schedule they just tapped.
          // Event-driven file watch — no polling, no child processes.
          ToastClickWatcherService.instance.start();
          // Steers Windows' default HTTP browser to one we can actually enforce.
          // Without this, clicking a link opens whatever default the user set
          // (often an un-protected browser), the hard-kill guard fires, and the
          // window vanishes — the "엉덩이 풀 본드" failure. 30 min tick, opens
          // Settings only when the ecosystem scan flags the current default as
          // problematic.
          if (!_backgroundLaunch) {
            DefaultBrowserPromoterService.instance.start();
          }
        });
      }
    }
    if (Platform.isWindows &&
        !_isTestShell &&
        !WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_bootWindowsServicesStaggered());
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_backgroundLaunch) {
          unawaited(
            BlockingEcosystemStatusLauncherService.instance.maybeShowIntro(),
          );
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future<void>.delayed(_BootDelays.shortcutRepair, () {
          if (!_backgroundLaunch) unawaited(_bootShortcutRepairImmediate());
        });
      });
    }
    _localeController.init().then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Keeps 「브라우저 차단 현황」 aligned with health + live URL probes after
  /// each app build bump or cold boot.
  Future<void> _bootBrowserStatusSync() async {
    if (!Platform.isWindows) return;
    try {
      final bool buildChanged = await BlockingEcosystemScanService.instance
          .needsPostUpdateScan();
      if (buildChanged) {
        BlockingEcosystemScanService.instance.invalidateCache();
      }
      Future<void>.delayed(_BootDelays.browserStatusProbe, () async {
        await BrowserBlockHealthMonitorService.instance.probe(
          reason: buildChanged ? 'boot_post_update' : 'boot',
        );
        if (buildChanged) {
          await BrowserLiveUrlBlockGateService.instance.runLiveTest(
            applyPolicyFirst: false,
            reason: 'boot_post_update',
          );
        }
        await BlockingEcosystemScanService.instance.scan(
          force: buildChanged,
          postUpdate: buildChanged,
        );
        BrowserEnforcementReadinessService.instance.invalidate();
      });
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> _bootWindowsServicesStaggered() async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
    await RebuildPreferencesService.instance.ensureFlagsSynced();
    // Anchor against NTP early so schedule decisions can't be skipped by
    // the user winding the system clock back. Non-blocking — if all NTP
    // hosts fail we fall back to DateTime.now() with no anchor.
    unawaited(TrustedTimeService.instance.init());
    // Run registry repair is cheap and must run every boot — light post-rebuild
    // bootstrap skips the heavy path that used to call ensureOnBoot.
    unawaited(WindowsOsIntegrationService.ensureOnBoot(silent: true));
    unawaited(WindowsWatchdogService.instance.syncTargetPath());
    await WindowsRebuildMonitor.instance.resumeIfNeeded();
    if (!_backgroundLaunch) {
      await RebuildAutoShowerService.instance.runIfNeeded(reason: 'boot');
    }
    final bool bootstrapped =
        _backgroundLaunch ||
        await PostRebuildBootstrapService.instance.runIfNeeded();
    if (!mounted) return;
    if (!_backgroundLaunch) unawaited(_bootBrowserStatusSync());
    unawaited(WindowsDesktopRebuildService.discoverMobileRoot());
    unawaited(ChatScheduleApplyService.instance.processDuePendingEdits());

    // Orchestrator already scheduled on first frame (see initState).

    Future<void>.delayed(_BootDelays.fiveLayerSyncCatchUp, () {
      if (!mounted) return;
      unawaited(
        WindowsFiveLayerBlockService.instance.syncLayers(reason: 'boot'),
      );
    });
    Future<void>.delayed(_BootDelays.fiveLayerExperiment, () {
      if (!mounted || _backgroundLaunch) return;
      unawaited(
        WindowsFiveLayerExperimentService.instance.run(
          applyFirst: false,
          reason: 'boot',
        ),
      );
    });

    if (bootstrapped) {
      // Returning-user boot: the heavy guards still need to come up, but not
      // all at once during first-frame. Stagger them so the UI is responsive.
      WindowsExtensionPolicyWatchdog.instance.start(
        allowElevation: !_backgroundLaunch,
      );
      ExtensionKeepaliveService.start();
      NewBrowserInstallWatcherService.instance.start();
      BrowserInstallSafetyService.instance.start();
      InstalledBrowsersAutoApplyService.instance.start(
        allowElevation: !_backgroundLaunch,
      );
      AgentTamperWatchdogService.instance.start();
      unawaited(AgentDestructGateService.instance.syncLocalVerifierArtifacts());
      unawaited(ChromeBrowserWatchdogService.instance.syncIfEnabled());
      Future<void>.delayed(_BootDelays.returningUserRealtimeGuard, () {
        if (!mounted) return;
        ProtectedBrowserRealtimeGuardService.instance.start();
      });
      BlockingSelfHealAgentService.instance.start(
        skipInitialBootCycle: true,
        allowBrowserProbes: !_backgroundLaunch,
      );
      unawaited(_bootFirefoxIntegrityGuard());
      return;
    }

    await Future<void>.delayed(_BootDelays.freshInstallWatchdogGap);
    if (!mounted) return;
    if (!mounted) return;
    WindowsExtensionPolicyWatchdog.instance.start();
    ExtensionKeepaliveService.start();
    NewBrowserInstallWatcherService.instance.start();
    BrowserInstallSafetyService.instance.start();
    InstalledBrowsersAutoApplyService.instance.start();
    AgentTamperWatchdogService.instance.start();
    unawaited(AgentDestructGateService.instance.syncLocalVerifierArtifacts());
    unawaited(ChromeBrowserWatchdogService.instance.syncIfEnabled());
    await Future<void>.delayed(_BootDelays.freshInstallRealtimeGuard);
    if (!mounted) return;
    ProtectedBrowserRealtimeGuardService.instance.start();
    unawaited(ProtectionGapResumeNotifier.instance.onAppResumed());
    BlockingSelfHealAgentService.instance.start();
    unawaited(_bootFirefoxIntegrityGuard());
  }

  /// Verifies the Firefox extension is still AMO-signed and matches the
  /// pinned source snapshot, heals a stale ProgramData copy if needed, and
  /// re-checks every 30 minutes for the rest of the session. Cheap (asset
  /// reads + hashing, no child process) so this interval is conservative,
  /// not a performance-budget requirement — see
  /// [FirefoxExtensionIntegrityGuardService] for what "silently broken"
  /// looks like and why it matters here specifically.
  Future<void> _bootFirefoxIntegrityGuard() async {
    if (!Platform.isWindows) return;
    Future<void> tick() async {
      await FirefoxExtensionIntegrityGuardService.instance.verify();
      await FirefoxExtensionIntegrityGuardService.instance.healIfNeeded();
    }

    await tick();
    _firefoxIntegrityTimer?.cancel();
    _firefoxIntegrityTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => unawaited(tick()),
    );
  }

  /// Bootstraps the backup pipeline.
  ///
  /// Order is **critical**:
  ///   1. `ensureBootstrapped` creates the folder if missing — never writes.
  ///   2. `autoRestoreIfFresh` checks whether this is a fresh install with
  ///      a usable backup. If so, it restores from disk BEFORE any sync.
  ///      Without this gating, the (empty) fresh DB would be flushed back
  ///      to disk and obliterate the user's only copy of their data.
  ///   3. After the restore decision, the safety gate inside BackupService
  ///      opens and we trigger one sync so the timestamp on `current.json`
  ///      is refreshed.
  Future<void> _bootstrapBackup() async {
    await BackupService.instance.ensureBootstrapped();
    final RestoreResult? restored = await BackupService.instance
        .autoRestoreIfFresh();
    if (restored != null && restored.ok && mounted) {
      // Notify the running widget tree to refresh — restored data shows up
      // on the next frame. Riverpod providers re-read on rebuild.
      setState(() {});
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            '백업에서 복원됨 · 스케줄 ${restored.counts!.schedules}개, '
            '사이트 ${restored.counts!.domains}개, '
            '키워드 ${restored.counts!.keywords}개, '
            '앱 ${restored.counts!.blockedApps}개',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
    BackupService.instance.scheduleSync();
    // Run BlueCloud sync only after backup auto-restore has made the local DB safe
    // to merge, so a fresh empty install can never overwrite the user's cloud list.
    BrainwireBlocklistSyncService.instance.startAutoSync();
    _backupPulseTimer?.cancel();
    _backupPulseTimer = Timer.periodic(const Duration(seconds: 120), (_) {
      unawaited(BackupService.instance.syncNow());
    });
    if (Platform.isMacOS || Platform.isWindows) {
      BlockSyncService.instance.requestApply();
    }
  }

  Future<void> _purgeOldTrash() async {
    await LocalDatabase.instance.purgeOldTrash();
  }

  /// Push the current "active right now" app-block target list to the native
  /// enforcer at launch and every minute thereafter. Without the periodic
  /// re-push, a schedule whose window crosses 22:00 wouldn't start blocking
  /// until the user touched the UI.
  Future<void> _bootAppBlock() async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
    if (!Platform.isMacOS && !Platform.isWindows) return;
    Future<void> pushNow() async {
      BlockSyncService.instance.syncAppTargetsNow();
    }

    await pushNow();
    _appBlockTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => pushNow(),
    );
  }

  Future<void> _bootQuickBlockSession() async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
    _quickBlockTimer?.cancel();
    await QuickBlockSessionService.instance.tickSession();
    final Duration quickTick = Platform.isWindows
        ? const Duration(seconds: 60)
        : const Duration(seconds: 30);
    _quickBlockTimer = Timer.periodic(quickTick, (_) {
      unawaited(QuickBlockSessionService.instance.tickSession());
    });
  }

  void _bootUsageIngest() {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    UsageIngestServer.instance.start();
    // Quiet launches preserve core guards while deferring interactive repair.
    // Keep authenticated CLI control reachable while blocking is OFF.
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
    // Lag detector — pings the UI loop every second, logs stalls > 300ms
    // with a child-process census so we know which spawn-storm is the
    // culprit. Cheap (1 await/sec) so it's safe to keep on always.
    AppLagDetectorService.instance.start();

    // CPU spike detector — uses Win32 GetProcessTimes via FFI (no child
    // process spawn) to sample our own CPU every 6 seconds. When the
    // current sample exceeds 50%/core or 3× the rolling baseline, it
    // captures: current child-process census, the last 50 in-memory log
    // lines, and any "noteActivity" labels services have registered.
    // Outputs to `%LOCALAPPDATA%\SixVPNBlocker\debug\cpu_spikes.jsonl`
    // and `cpu_spike_last.json` — agent-readable.
    CpuSpikeDetectorService.instance.noteAppStart();
    CpuSpikeDetectorService.instance.start();

    // Heavy diagnostics staggered — keeps first paint responsive.
    Future<void>.delayed(_BootDelays.cursorSnapshot, () {
      CursorAgentSnapshotService.instance.start();
    });
    // Live per-browser block health monitor: probes every 90s, writes a
    // structured report + cursor/claude prompt + user-facing nudge whenever
    // any browser's block stops working (locked HKCU, missing blocklist,
    // process predates policy, etc.). See
    // mobile/lib/services/browser_block_health_monitor_service.dart.
    Future<void>.delayed(_BootDelays.healthMonitorStart, () {
      BrowserBlockHealthMonitorService.instance.start();
    });
    Future<void>.delayed(_BootDelays.killGuardStart, () {
      UnprotectedBrowserKillGuardService.instance.start();
    });
    Future<void>.delayed(_BootDelays.chromeReloadOrchestrator, () {
      if (!_backgroundLaunch) {
        ChromeUrlBlockReloadOrchestratorService.instance.start();
      }
    });
    Future<void>.delayed(_BootDelays.youtubeGuardStart, () {
      YoutubeProactiveGuardService.instance.start(
        allowBrowserExperiments: !_backgroundLaunch,
      );
    });
    if (Platform.isWindows) {
      unawaited(ExtensionRulesSnapshotService.instance.writeToChromePayload());
      Future<void>.delayed(_BootDelays.fiveLayerSyncEarly, () {
        unawaited(
          WindowsFiveLayerBlockService.instance.syncLayers(reason: 'boot'),
        );
      });
      Future<void>.delayed(_BootDelays.requiredPolicyCheck, () async {
        if (!await WindowsHkcuPolicyService.instance
            .hasRequiredBrowserPolicies()) {
          await UniversalBrowserBlockService.instance.syncNow(
            reason: 'launch_required_browser_policy_missing',
          );
        }
        await WindowsFiveLayerBlockService.instance.syncLayers(
          reason: 'launch_required_browser_policy_missing',
        );
      });
    }
  }

  void _bootUsageTracking() {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
    UsageTrackingService.instance.start();
    UsageQuotaEnforcerService.instance.start();
  }

  @override
  void onWindowClose() {
    if (_windowsTrayShellForThisApp) {
      unawaited(windowManager.hide());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_windowsTrayShellForThisApp) {
      windowManager.removeListener(this);
    }
    _appBlockTimer?.cancel();
    _quickBlockTimer?.cancel();
    _backupPulseTimer?.cancel();
    _firefoxIntegrityTimer?.cancel();
    if (!_isTestShell) {
      // Graceful teardown — mark a clean exit so the next launch doesn't mistake
      // it for a force-kill and show the recovery toast.
      AppForceRestartNoticeService.instance.markCleanExit();
      AppForceRestartNoticeService.instance.stop();
      AppBlockUserNoticeService.instance.stop();
      BrowserExitWatcherService.instance.stop();
      ToastClickWatcherService.instance.stop();
      BlockActivityLogService.instance.stop();
      BlockingSelfHealAgentService.instance.stop();
      WindowsExtensionPolicyWatchdog.instance.stop();
      ExtensionKeepaliveService.stop();
      NewBrowserInstallWatcherService.instance.stop();
      BrowserInstallSafetyService.instance.stop();
      InstalledBrowsersAutoApplyService.instance.stop();
      AgentTamperWatchdogService.instance.stop();
      UsageTrackingService.instance.stop();
      UsageQuotaEnforcerService.instance.stop();
      UsageIngestServer.instance.stop();
      CursorAgentSnapshotService.instance.stop();
      BrowserBlockHealthMonitorService.instance.stop();
      UnprotectedBrowserKillGuardService.instance.stop();
      ChromeUrlBlockReloadOrchestratorService.instance.stop();
      AppLagDetectorService.instance.stop();
      CpuSpikeDetectorService.instance.stop();
      SevereLagSessionService.instance.stop();
      YoutubeProactiveGuardService.instance.stop();
      ProtectedBrowserRealtimeGuardService.instance.stop();
      EnforcementController.instance.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isTestShell) return;
    if (_backgroundLaunch) return;
    if (state == AppLifecycleState.resumed) {
      if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
      unawaited(_resumeDelayedRuleRemovals());
      _ingestShares();
      if (Platform.isWindows || Platform.isMacOS) {
        unawaited(ProtectionGapResumeNotifier.instance.onAppResumed());
      }
      if (Platform.isWindows && !_isFlutterTest) {
        unawaited(_reapplyChromeShortcutsOnResume());
      }
    }
  }

  Future<void> _bootDelayedRuleRemovals() async {
    await _enforceScheduleLock();
    await DelayedRuleRemovalService.instance.start();
  }

  Future<void> _resumeDelayedRuleRemovals() async {
    await _enforceScheduleLock();
    await DelayedRuleRemovalService.instance.processDueRemovals();
  }

  Future<void> _enforceScheduleLock() async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
    await enforceLockScheduleIfNeeded();
  }

  static DateTime? _lastTier3ResumeAt;

  void _maybeRunTier3OnResume() {
    final DateTime now = DateTime.now();
    if (_lastTier3ResumeAt != null &&
        now.difference(_lastTier3ResumeAt!) < const Duration(minutes: 15)) {
      return;
    }
    _lastTier3ResumeAt = now;
    unawaited(TierEnforcementService.instance.runTier3Once());
    unawaited(
      ChromeBlockAutonomyService.instance.runOnce(
        reason: 'resume',
        repair: false,
      ),
    );
  }

  Future<void> _bootShortcutRepairImmediate() async {
    if (!mounted) return;
    final ShortcutBootRepairResult r = await ChromeShortcutBootRepairService
        .instance
        .runOnLaunch(force: true);
    if (!mounted) return;
    ChromeShortcutBootRepairService.instance.notifyUser(r);
  }

  Future<void> _maybeHandoffOnResume() async {
    final BootApplySkipVerdict skip = await BootApplyIdempotencyService.instance
        .evaluateSkip(reason: 'resume');
    if (skip.skip) return;
    await AutomatedBrowserHandoffService.instance.runZeroTouch(
      reason: 'resume',
    );
  }

  Future<void> _reapplyChromeShortcutsOnResume() async {
    if (await EasySetupBulletproofPrefs.instance.hijackShortcuts()) {
      final ShortcutBootRepairResult r = await ChromeShortcutBootRepairService
          .instance
          .runOnLaunch();
      if (mounted) ChromeShortcutBootRepairService.instance.notifyUser(r);
    }
    if (await EasySetupBulletproofPrefs.instance.realtimeBrowserGuard()) {
      unawaited(ProtectedBrowserRealtimeGuardService.instance.runOnce());
    }
    _maybeRunTier3OnResume();
    AutonomousApplyOrchestratorService.instance.scheduleOnResume();
    unawaited(_maybeHandoffOnResume());
  }

  Future<void> _ingestShares() async {
    final n = await _shareIngest.ingestIfNeeded();
    if (n > 0 && mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('공유로 받은 사이트 $n개를 차단 목록에 넣었습니다.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.testMode) {
      return AnimatedBuilder(
        animation: _localeController,
        builder: (BuildContext context, Widget? child) {
          return MaterialApp(
            title: 'Focus Fense',
            debugShowCheckedModeBanner: false,
            theme: Platform.isMacOS ? AppTheme.macDark() : AppTheme.light(),
            locale: _localeController.locale,
            supportedLocales: AppI18n.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            home: const SizedBox.shrink(),
          );
        },
      );
    }
    return AnimatedBuilder(
      animation: _localeController,
      builder: (BuildContext context, Widget? child) {
        return PostRebuildActivationListener(
          child: SevereLagOverlay(
            child: WindowsRebuildProgressOverlay(
              child: MaterialApp.router(
                title: 'Focus Fense',
                debugShowCheckedModeBanner: false,
                theme: Platform.isMacOS ? AppTheme.macDark() : AppTheme.light(),
                routerConfig: _router,
                locale: _localeController.locale,
                supportedLocales: AppI18n.supportedLocales,
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
