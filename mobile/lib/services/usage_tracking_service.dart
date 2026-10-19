import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logger.dart';
import '../router/app_router.dart';
import 'frontmost_app_channel.dart';
import 'game_daily_budget_service.dart';
import 'game_budget_overlay_service.dart';
import 'local_database.dart';
import 'locale_controller.dart';
import 'usage_bucket_config_service.dart';
import 'usage_quota_enforcer_service.dart';

/// Polls the macOS frontmost app into period buckets; web hosts via ingest server.
final class UsageTrackingService {
  UsageTrackingService._();
  static final UsageTrackingService instance = UsageTrackingService._();

  static const String _kHostBundleId = 'com.sixcleanroom.sixCleanRoom';

  Timer? _timer;
  DateTime? _lastTick;
  FrontmostAppSnapshot? _previous;
  bool _pulsing = false;
  int _foregroundRemainderMs = 0;

  static int verifiedForegroundSeconds({
    required FrontmostAppSnapshot? previous,
    required FrontmostAppSnapshot? current,
    required int elapsedSeconds,
    int maxGapSeconds = 15,
  }) {
    if (previous == null ||
        current == null ||
        elapsedSeconds < 1 ||
        elapsedSeconds > maxGapSeconds ||
        previous.processIdentifier != current.processIdentifier ||
        previous.bundleId != current.bundleId) {
      return 0;
    }
    return elapsedSeconds;
  }

  void start() {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    _timer?.cancel();
    _lastTick = DateTime.now();
    // Foreground accounting, not a diagnostic probe: one in-process native read,
    // no subprocess/network. Five seconds bounds game-cap overshoot; no catch-up.
    final Duration tick = Platform.isWindows
        ? const Duration(seconds: 5)
        : const Duration(seconds: 15);
    _timer = Timer.periodic(tick, (_) => _pulse());
    AppLogger.instance.info(
      'usage_tracking: started (${tick.inSeconds}s poll)',
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastTick = null;
    _previous = null;
    _foregroundRemainderMs = 0;
  }

  Future<void> _pulse() async {
    if (_pulsing) return;
    _pulsing = true;
    try {
      final DateTime now = DateTime.now();
      final DateTime last = _lastTick ?? now;
      _lastTick = now;
      int dt = now.difference(last).inSeconds;
      if (dt < 1) return;
      // Sleep / debugger pauses should not credit minutes of arbitrary app time.
      if (dt > (Platform.isWindows ? 15 : 45)) {
        _previous = null;
        _foregroundRemainderMs = 0;
        return;
      }

      final FrontmostAppSnapshot? snap = await FrontmostAppChannel.instance
          .getFrontmost();
      final FrontmostAppSnapshot? previous = _previous;
      _previous = snap;
      if (snap == null) {
        _foregroundRemainderMs = 0;
        return;
      }
      // A sampled app switch has unknown timing: never assign the full interval
      // to the newly focused game or count a minimized/background application.
      dt = verifiedForegroundSeconds(
        previous: previous,
        current: snap,
        elapsedSeconds: dt,
        maxGapSeconds: Platform.isWindows ? 15 : 45,
      );
      if (dt == 0) {
        _foregroundRemainderMs = 0;
        return;
      }
      final int elapsedMs =
          now.difference(last).inMilliseconds + _foregroundRemainderMs;
      dt = elapsedMs ~/ 1000;
      _foregroundRemainderMs = elapsedMs % 1000;
      if (snap.bundleId == _kHostBundleId) return;

      final String subject = LocalDatabase.usageSubjectForApp(
        snap.bundleId,
        snap.localizedName,
      );
      try {
        final bool pooledGame = await GameDailyBudgetService.instance
            .onForegroundUsage(
              bundleId: snap.bundleId,
              seconds: dt,
              observedAt: now,
            );
        if (pooledGame) {
          if (Platform.isWindows) {
            final Map<String, Object?> budget = await GameDailyBudgetService
                .instance
                .status();
            final bool korean =
                LocaleController.instance.locale.languageCode == 'ko';
            await GameBudgetOverlayService.instance.show(
              processId: snap.processIdentifier,
              remainingSeconds: budget['remainingSeconds']! as int,
              label: korean ? '남은 게임 시간  ' : 'Game time left  ',
            );
          }
          return;
        }
        if (Platform.isWindows) {
          await GameBudgetOverlayService.instance.hide();
          // Use the process identity (for example UnrealEditor.exe), not its
          // localized display label, so the first-run choice is saved per app.
          await _askToIncludeFirstRunGame(
            snap.bundleId,
            executablePath: snap.executablePath,
          );
          return;
        }
        // Windows previously had no ordinary per-app recording. Keep browser
        // ingest/global-cap semantics unchanged; only the new game pool is added.
        final int ph = await UsageBucketConfigService.instance.getPeriodHours();
        await LocalDatabase.instance.addUsageSeconds(
          subject,
          dt,
          now,
          periodHours: ph,
          background: false,
        );
        await UsageQuotaEnforcerService.instance.onUsageRecorded(subject, dt);
      } catch (e) {
        AppLogger.instance.warn('usage_tracking write failed: $e');
      }
    } finally {
      _pulsing = false;
    }
  }

  Future<void> _askToIncludeFirstRunGame(
    String executable, {
    String? executablePath,
  }) async {
    final NavigatorState? navigator = appRootNavigatorKey.currentState;
    if (navigator == null || !navigator.mounted) return;
    final BuildContext dialogContext = navigator.context;
    final GameDailyBudgetService games = GameDailyBudgetService.instance;
    final bool shouldAsk = await games.claimFirstRunQuestion(
      executable,
      executablePath: executablePath,
    );
    if (!shouldAsk || !navigator.mounted || !dialogContext.mounted) return;

    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // In-app dialog remains available when the tray window cannot be raised.
    }
    if (!navigator.mounted || !dialogContext.mounted) return;
    final String exe = GameDailyBudgetService.canonicalExe(executable);
    final bool korean = LocaleController.instance.locale.languageCode == 'ko';
    final bool? include = await showDialog<bool>(
      context: dialogContext,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: Text(korean ? '게임 후보를 찾았습니다' : 'Possible game detected'),
        content: Text(
          korean
              ? '$exe 를 게임 시간 제한에 포함할까요?\n\n포함을 선택한 프로그램만 게임 시간으로 계산합니다.'
              : 'Include $exe in your game time limit?\n\nOnly programs you include are counted as game time.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(korean ? '포함하지 않음' : 'Do not include'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(korean ? '게임에 포함' : 'Include game'),
          ),
        ],
      ),
    );
    if (include == true) {
      await games.includeFirstRunGame(exe);
    }
  }
}
