import 'dart:io';

import '../models/apply_activation_report.dart';
import 'app_logger.dart';
import 'app_operation_progress_service.dart';
import 'block_sync_service.dart';
import 'blocking_repair_failure_tracker_service.dart';
import 'cursor_agent_fix_log_service.dart';
import 'mac_system_block_service.dart';
import 'windows_apply_status_service.dart';

/// Autonomous hosts/PAC apply **without** blocking [showApplyActivationDialog].
///
/// Windows UAC may still appear (OS-level) once for hosts — but the app UI
/// stays usable. Progress is logged to disk for Cursor, not shown as a modal.
final class BackgroundApplyService {
  BackgroundApplyService._();
  static final BackgroundApplyService instance = BackgroundApplyService._();

  /// Silent apply — no modal, no footer strip (explicit progress off).
  Future<MacBlockResult> runHostsRepair({
    required String reason,
    String component = 'background_apply',
    bool easyMode = false,
    String? verifyHost,
    bool showFooterProgress = false,
  }) async {
    if (!Platform.isWindows) {
      return MacBlockResult.unsupported();
    }

    String? progressId;
    if (showFooterProgress) {
      progressId = AppOperationProgressService.instance.begin(
        title: '백그라운드 차단 적용',
        step: '준비…',
        fraction: 0.05,
        id: 'bg_apply_$reason',
      );
    }

    MacBlockResult out = MacBlockResult.failure('not started');
    ApplyActivationReport? report;
    try {
      report = await WindowsApplyStatusService.instance.applyAndVerify(
        easyMode: easyMode,
        verifyHost: verifyHost,
        onPhase: (String label) {
          if (progressId != null) {
            AppOperationProgressService.instance.update(
              progressId,
              step: label,
              fraction: 0.35,
            );
          }
          AppLogger.instance.info('bg_apply [$reason]: $label');
        },
      );
      final MacBlockResult? last = BlockSyncService.instance.lastResult;
      out = last ??
          (report.success
              ? MacBlockResult.success(stdout: report.summary)
              : MacBlockResult.failure(report.summary));

      await BlockingRepairFailureTrackerService.instance.record(
        component: component,
        action: 'background_hosts_apply',
        ok: report.success && out.status == MacBlockStatus.success,
        verdict: report.summary,
        reason: reason,
        details: <String, Object?>{
          'verifyHost': verifyHost,
          'easyMode': easyMode,
          'steps': report.steps
              .map(
                (ApplyActivationStep s) => <String, Object?>{
                  'id': s.id,
                  'label': s.label,
                  'ok': s.ok,
                  'detail': s.detail,
                },
              )
              .toList(),
        },
        failedLayers: report.success ? const <String>[] : <String>['hosts_apply'],
        appliedLayers:
            report.success ? <String>['hosts_apply'] : const <String>[],
      );

      return out;
    } catch (e, st) {
      AppLogger.instance.warn('bg_apply failed: $e\n$st');
      out = MacBlockResult.failure('$e');
      await BlockingRepairFailureTrackerService.instance.record(
        component: component,
        action: 'background_hosts_apply',
        ok: false,
        verdict: 'background apply error: $e',
        reason: reason,
        details: <String, Object?>{'error': '$e'},
        failedLayers: <String>['hosts_apply_error'],
      );
      return out;
    } finally {
      if (progressId != null) {
        AppOperationProgressService.instance.end(progressId);
      }
    }
  }
}
