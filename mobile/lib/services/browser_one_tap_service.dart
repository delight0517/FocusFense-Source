import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'automated_browser_handoff_service.dart';
import 'chrome_block_autonomy_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'easy_setup_bulletproof_prefs.dart';
import 'extension_rules_builder.dart';
import 'network_url_block_service.dart';

/// Single user action: open Chrome with blocking enabled. Everything else is automatic.
final class BrowserOneTapService {
  BrowserOneTapService._();

  static Future<BrowserOneTapResult> openProtectedChrome({
    bool repair = true,
  }) async {
    if (!Platform.isWindows) {
      return const BrowserOneTapResult(
        ok: false,
        launched: false,
        userMessage: 'Windows에서 Chrome 보호를 사용할 수 있습니다.',
      );
    }

    final ChromeBlockStatus status =
        await ChromeBlockAutonomyService.instance.runOnce(
      reason: 'one_tap',
      repair: repair,
    );

    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    if (rules.hasYoutubeChannelBlocks) {
      // Non-destructive: shortcut hijack + watchdog only, NO realtime kill loop.
      await EasySetupBulletproofPrefs.instance.setAll(
        hijackShortcuts: true,
        browserWatchdog: true,
        forceEnterprisePolicies: true,
        realtimeBrowserGuard: false,
      );
    }

    await ChromeLoadExtensionLauncher.refreshChromiumLaunchersFromDisk();
    if (await AutomatedBrowserHandoffService.probeBrowsers().then(
      (BrowserProcessProbe p) => p.chromeRunning,
    )) {
      await AutomatedBrowserHandoffService.forceStopAllChrome();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }

    final NetworkUrlBlockResult net =
        await NetworkUrlBlockService.instance.enforceNow(reason: 'one_tap');

    final bool launched = await ChromeLoadExtensionLauncher.launchChromeDirect();

    if (launched) {
      bool protectedNow = false;
      for (int i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        protectedNow =
            await AutomatedBrowserHandoffService.isChromeEffectivelyProtected();
        if (protectedNow) break;
      }
      final String msg;
      if (protectedNow) {
        msg =
            'Chrome 보호 모드 + 네트워크(PAC) 차단 적용됨. '
            '유튜브 주소를 다시 열면 차단됩니다.';
      } else if (net.ok) {
        msg =
            '네트워크(PAC·URL목록) 차단은 적용됐습니다. '
            'Chrome을 닫았다가 다시 열고 같은 주소를 열어 보세요.';
      } else {
        msg =
            '보호 Chrome을 실행했지만 확장 확인이 안 됩니다. '
            'Chrome을 완전히 닫은 뒤 앱에서 한 번 더 「보호 Chrome으로 전환」을 눌러 주세요.';
      }
      return BrowserOneTapResult(
        ok: protectedNow,
        launched: true,
        userMessage: msg,
      );
    }

    return BrowserOneTapResult(
      ok: status.blockingOk,
      launched: false,
      userMessage: status.blockingOk
          ? '준비됨. 바탕화면 「Focus Fense (Chrome)」 아이콘을 눌러 주세요.'
          : status.userMessage,
    );
  }

  static Future<void> openWithFeedback(BuildContext context) async {
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Chrome 준비 중…'),
        duration: Duration(seconds: 3),
      ),
    );

    final BrowserOneTapResult r = await openProtectedChrome(repair: true);
    if (!context.mounted) return;
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(r.userMessage),
        duration: Duration(seconds: r.ok ? 5 : 8),
      ),
    );
  }
}

final class BrowserOneTapResult {
  const BrowserOneTapResult({
    required this.ok,
    required this.launched,
    required this.userMessage,
  });

  final bool ok;
  final bool launched;
  final String userMessage;
}
