import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/browser_extensions_screen.dart';
import '../screens/diagnostics_screen.dart';
import '../screens/youtube_feed_block_screen.dart';
import '../widgets/apply_activation_dialog.dart';
import 'browser_one_tap_service.dart';
import 'extension_easy_setup_launcher.dart';
import 'protection_coverage_service.dart';
import 'windows_apply_status_service.dart';

/// Navigation from protection-gap UI (banner, sheet, snackbars).
abstract final class ProtectionGapActions {
  static Future<void> apply(
    BuildContext context,
    ProtectionGapFix fix, {
    bool showSnackbars = true,
  }) async {
    switch (fix) {
      case ProtectionGapFix.easySetup:
        if (Platform.isWindows) {
          await BrowserOneTapService.openWithFeedback(context);
        } else {
          await ExtensionEasySetupLauncher.showAgain(context);
        }
      case ProtectionGapFix.browserExtensions:
        if (Platform.isWindows) {
          await BrowserOneTapService.openWithFeedback(context);
        } else {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const BrowserExtensionsScreen(),
            ),
          );
        }
      case ProtectionGapFix.applyHosts:
        if (Platform.isWindows) {
          await showApplyActivationDialog(
            context,
            runApply: (onPhase) =>
                WindowsApplyStatusService.instance.applyAndVerify(
                  onPhase: onPhase,
                ),
          );
        } else if (showSnackbars && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('macOS는 스케줄 화면 또는 진단에서 hosts 적용을 사용하세요.'),
            ),
          );
        }
      case ProtectionGapFix.settings:
        if (context.mounted) context.push('/settings');
      case ProtectionGapFix.diagnostics:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const DiagnosticsScreen(),
          ),
        );
      case ProtectionGapFix.youtubeRules:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const YouTubeFeedBlockScreen(),
          ),
        );
      case ProtectionGapFix.connectBrowsers:
        await BrowserOneTapService.openWithFeedback(context);
    }
    ProtectionCoverageService.instance.invalidateCache();
  }
}
