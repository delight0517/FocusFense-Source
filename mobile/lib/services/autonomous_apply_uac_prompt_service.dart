import 'dart:io';

import 'app_logger.dart';
import 'blocking_repair_failure_tracker_service.dart';
import 'mac_system_block_service.dart';

/// Autonomous hosts repair — **background only** (no blocking apply modal).
///
/// Windows may still show the OS UAC prompt once for elevated hosts writes.
final class AutonomousApplyUacPromptService {
  AutonomousApplyUacPromptService._();
  static final AutonomousApplyUacPromptService instance =
      AutonomousApplyUacPromptService._();

  DateTime? _lastPromptAt;

  /// Numeric-evasion apex (`mingky01.live`) must sinkhole via hosts.
  Future<MacBlockResult?> promptForNumericApexDnsRepair({
    required String reason,
    int contextWaitSec = 15,
  }) async {
    return _runBackgroundIfAllowed(
      reason: reason,
      component: 'numeric_apex_dns',
      verifyHost: 'mingky01.live',
      easyMode: false,
    );
  }

  /// YouTube DNS repair — strip accidental youtube.com apex from hosts.
  Future<MacBlockResult?> promptForYoutubeDnsRepair({
    required String reason,
    int contextWaitSec = 15,
  }) async {
    return _runBackgroundIfAllowed(
      reason: reason,
      component: 'youtube_dns',
      verifyHost: 'youtube.com',
      easyMode: false,
    );
  }

  Future<MacBlockResult?> _runBackgroundIfAllowed({
    required String reason,
    required String component,
    String? verifyHost,
    required bool easyMode,
  }) async {
    if (!Platform.isWindows) return null;
    final DateTime now = DateTime.now();
    if (_lastPromptAt != null &&
        now.difference(_lastPromptAt!) < const Duration(minutes: 30)) {
      AppLogger.instance.info(
        'autonomous_uac: suppressed by cooldown ($component / $reason)',
      );
      return null;
    }
    _lastPromptAt = now;

    AppLogger.instance.info(
      'autonomous_uac: admin repair needed but not auto-prompted ($component / $reason)',
    );
    await BlockingRepairFailureTrackerService.instance.record(
      component: component,
      action: 'admin_repair_deferred',
      ok: false,
      verdict: '관리자 권한 적용이 필요하지만 자동 UAC는 띄우지 않았습니다.',
      reason: reason,
      details: <String, Object?>{
        'verifyHost': verifyHost,
        'easyMode': easyMode,
        'suppressedAutoUac': true,
      },
      failedLayers: const <String>['admin_repair_needed'],
    );
    return null;
  }
}
