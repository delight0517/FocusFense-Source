import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../router/app_router.dart';
import '../screens/easy_setup_wizard_screen.dart';
import 'autonomous_browser_protection_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'extension_easy_setup_prefs.dart';
import 'windows_extension_guard_service.dart';

/// Browser setup: one-tap Chrome on Windows (no wizard maze).
final class ExtensionEasySetupLauncher {
  ExtensionEasySetupLauncher._();

  static Future<void> maybeShow() async {
    if (!Platform.isWindows) return;

    if (await BlockingSelfHealPrefs.instance.autoEasySetup()) {
      unawaited(
        AutonomousBrowserProtectionService.instance.ensureAllBrowsersProtected(
          reason: 'first_run',
          force: false,
        ),
      );
      return;
    }

    final ExtensionPolicyVerifyResult v =
        await WindowsExtensionGuardService.verifyAllPolicies();
    if (v.protectionOk) {
      await ExtensionEasySetupPrefs.instance.markComplete();
      return;
    }

    if (!await ExtensionEasySetupPrefs.instance.shouldShowWizard()) return;

    await Future<void>.delayed(const Duration(milliseconds: 600));
    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;

    await Navigator.of(ctx).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const EasySetupWizardScreen(),
      ),
    );
  }

  /// Settings / gaps: one button path — no multi-step wizard on Windows.
  static Future<void> showAgain(BuildContext context) async {
    await ExtensionEasySetupPrefs.instance.reset();
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const EasySetupWizardScreen(),
      ),
    );
  }
}
