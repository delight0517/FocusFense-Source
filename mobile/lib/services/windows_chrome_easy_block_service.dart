import 'dart:async';
import 'dart:io';

import 'app_logger.dart';
import 'automated_browser_handoff_service.dart';
import 'block_activity_log_service.dart';
import 'browser_one_tap_service.dart';
import 'protected_browser_realtime_guard_service.dart';

/// One-shot: make Chrome actually block YouTube **without** UAC or manual steps.
final class WindowsChromeEasyBlockService {
  WindowsChromeEasyBlockService._();
  static final WindowsChromeEasyBlockService instance =
      WindowsChromeEasyBlockService._();

  static const Duration _handoffCooldown = Duration(seconds: 45);
  DateTime? _lastHandoffAt;
  BrowserOneTapResult? lastResult;

  /// Kills plain chrome.exe, applies policy flag, launches protected Chrome.
  Future<BrowserOneTapResult> ensureChromeBlocksYoutube({
    String reason = 'easy_apply',
    bool force = true,
  }) async {
    if (!Platform.isWindows) {
      return const BrowserOneTapResult(
        ok: false,
        launched: false,
        userMessage: 'Windows 전용',
      );
    }
    if (!force &&
        _lastHandoffAt != null &&
        DateTime.now().difference(_lastHandoffAt!) < _handoffCooldown) {
      return lastResult ??
          const BrowserOneTapResult(
            ok: true,
            launched: false,
            userMessage: '최근에 Chrome 전환을 했습니다.',
          );
    }

    await ProtectedBrowserRealtimeGuardService.instance.syncScriptOnly();

    final BrowserProcessProbe before =
        await AutomatedBrowserHandoffService.probeBrowsers();
    if (before.chromeUnprotected) {
      await AutomatedBrowserHandoffService.closeUnprotectedChrome();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    final BrowserOneTapResult r =
        await BrowserOneTapService.openProtectedChrome(repair: true);
    _lastHandoffAt = DateTime.now();
    lastResult = r;

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: r.userMessage,
      data: <String, Object?>{
        'reason': reason,
        'ok': r.ok,
        'launched': r.launched,
        'chromeUnprotectedBefore': before.chromeUnprotected,
      },
      debounceKey: 'chrome_easy_block',
    );
    AppLogger.instance.info(
      'chrome_easy_block [$reason] ok=${r.ok} launched=${r.launched}',
    );
    return r;
  }
}
