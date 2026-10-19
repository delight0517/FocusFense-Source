import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../router/app_router.dart';
import '../widgets/protection_gaps_banner.dart';
import 'browser_block_enforcement_health_service.dart';
import 'autonomous_browser_protection_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'browser_one_tap_service.dart';
import 'extension_easy_setup_prefs.dart';
import 'protection_coverage_service.dart';
import 'boot_apply_idempotency_service.dart';
import 'silent_bootstrap_context.dart';
import 'windows_extension_guard_service.dart';

/// On resume: snackbar when rules exist but enforcement layers are missing.
final class ProtectionGapResumeNotifier {
  ProtectionGapResumeNotifier._();
  static final ProtectionGapResumeNotifier instance =
      ProtectionGapResumeNotifier._();

  DateTime? _lastSnackAt;
  static const Duration _cooldown = Duration(minutes: 20);

  Future<void> onAppResumed() async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    if (SilentBootstrapContext.suppressUserPrompts) return;
    final DateTime now = DateTime.now();
    if (_lastSnackAt != null &&
        now.difference(_lastSnackAt!) < _cooldown) {
      return;
    }

    final BootApplySkipVerdict steady =
        await BootApplyIdempotencyService.instance.evaluateSkip(
      reason: 'resume',
    );

    final ProtectionCoverageReport report =
        await ProtectionCoverageService.instance.analyze(force: false);
    final BrowserEnforcementHealth enforce =
        await BrowserBlockEnforcementHealthService.instance.analyze();
    if (Platform.isWindows &&
        report.chromeExtensionOk &&
        report.edgeExtensionOk &&
        report.firefoxExtensionOk &&
        !enforce.needsUserAction &&
        !enforce.chromeUnprotectedRunning) {
      return;
    }

    if (steady.skip &&
        !enforce.chromeUnprotectedRunning &&
        report.chromeExtensionOk &&
        report.edgeExtensionOk &&
        report.firefoxExtensionOk) {
      return;
    }

    if (Platform.isWindows &&
        await BlockingSelfHealPrefs.instance.autoEasySetup() &&
        !steady.skip &&
        (!report.chromeExtensionOk ||
            !report.edgeExtensionOk ||
            !report.firefoxExtensionOk ||
            enforce.chromeUnprotectedRunning)) {
      unawaited(
        AutonomousBrowserProtectionService.instance.ensureAllBrowsersProtected(
          reason: 'resume',
        ),
      );
    }

    if (Platform.isWindows && report.inventory.needsExtension) {
      final bool markedDone = await ExtensionEasySetupPrefs.instance.isComplete();
      if (markedDone) {
        final ExtensionPolicyVerifyResult v =
            await WindowsExtensionGuardService.verifyAllPolicies();
        if (!v.protectionOk) {
          await ExtensionEasySetupPrefs.instance.clearComplete();
        }
      }
    }

    final List<ProtectionGap> actionable = report.gaps
        .where((ProtectionGap g) => g.severity != ProtectionGapSeverity.info)
        .toList();
    if (actionable.isEmpty && !enforce.needsUserAction) return;

    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;

    _lastSnackAt = now;
    if (enforce.chromeUnprotectedRunning) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('${enforce.headline}\n${enforce.explanation}'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: '보호 Chrome',
            onPressed: () =>
                unawaited(BrowserOneTapService.openWithFeedback(ctx)),
          ),
        ),
      );
      return;
    }
    if (enforce.needsUserAction) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('${enforce.headline}\n${enforce.explanation}'),
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }

    final ProtectionGap top = actionable.first;
    final String snippet = top.detail.split('\n').first;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('${top.title}\n$snippet'),
        duration: const Duration(seconds: 9),
        action: SnackBarAction(
          label: Platform.isWindows ? 'Chrome 열기' : '점검',
          onPressed: () {
            if (Platform.isWindows) {
              unawaited(BrowserOneTapService.openWithFeedback(ctx));
            } else {
              unawaited(showProtectionCoverageSheet(ctx));
            }
          },
        ),
      ),
    );
  }
}
