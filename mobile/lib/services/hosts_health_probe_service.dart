import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'cursor_agent_fix_log_service.dart';
import 'block_activity_log_service.dart';
import 'block_sync_service.dart';
import 'local_database.dart';
import 'mac_system_block_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_system_block_service.dart';

/// Detects truncated / missing managed `hosts` regions (e.g. after a bad patch).
final class HostsHealthStatus {
  const HostsHealthStatus({
    required this.ok,
    required this.managedSinkholeLines,
    required this.expectedHostCount,
    required this.hasMarkers,
    required this.rescueMergedBytes,
    this.issue,
  });

  final bool ok;
  final int managedSinkholeLines;
  final int expectedHostCount;
  final bool hasMarkers;
  final int rescueMergedBytes;
  final String? issue;

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'managedSinkholeLines': managedSinkholeLines,
        'expectedHostCount': expectedHostCount,
        'hasMarkers': hasMarkers,
        'rescueMergedBytes': rescueMergedBytes,
        'issue': issue,
      };
}

final class HostsHealthProbeService {
  HostsHealthProbeService._();
  static final HostsHealthProbeService instance = HostsHealthProbeService._();

  static const int _kTruncatedManagedLines = 60;

  Future<HostsHealthStatus> probe() async {
    if (!Platform.isWindows) {
      return const HostsHealthStatus(
        ok: true,
        managedSinkholeLines: 0,
        expectedHostCount: 0,
        hasMarkers: true,
        rescueMergedBytes: 0,
      );
    }

    final RuleCounts counts = await LocalDatabase.instance.ruleCounts();
    final int expected =
        (await MacSystemBlockService.instance.enabledHostsExpanded()).length;
    final String? all =
        await WindowsSystemBlockService.tryReadSystemHostsNormalized();
    final bool hasMarkers = all != null &&
        all.contains(MacSystemBlockService.kMarkerStart) &&
        all.contains(MacSystemBlockService.kMarkerEnd);
    final int managed =
        all == null ? 0 : _countManagedSinkholeLines(all);
    final int rescueBytes = await _rescueMergedBytes();

    String? issue;
    if (!hasMarkers && counts.domainsEnabled > 0) {
      issue = 'managed_markers_missing';
    } else if (counts.domainsEnabled >= 3 &&
        managed < _kTruncatedManagedLines) {
      issue = 'managed_region_truncated';
    } else if (expected > 120 && managed < expected ~/ 3) {
      issue = 'managed_far_below_expected';
    }

    return HostsHealthStatus(
      ok: issue == null,
      managedSinkholeLines: managed,
      expectedHostCount: expected,
      hasMarkers: hasMarkers,
      rescueMergedBytes: rescueBytes,
      issue: issue,
    );
  }

  /// Regenerates managed hosts from DB when corruption is detected. May show UAC once.
  Future<bool> repairIfNeeded({required String reason}) async {
    if (!Platform.isWindows) return false;
    final HostsHealthStatus status = await probe();
    if (status.ok) return false;

    AppLogger.instance.warn(
      'hosts_health: repair needed issue=${status.issue} '
      'managed=${status.managedSinkholeLines} expected≈${status.expectedHostCount}',
    );
    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.hostsApply,
      message: 'hosts 자동 복구 (${status.issue})',
      data: status.toJson(),
      level: 'warn',
      debounceKey: 'hosts_health_repair',
    );

    final MacBlockResult r = await BlockSyncService.instance.applyNow();
    final bool ok = r.status == MacBlockStatus.success;
    if (ok) {
      AppLogger.instance.info('hosts_health: repair OK ($reason)');
    } else {
      AppLogger.instance.warn(
        'hosts_health: repair failed ($reason) — ${r.message ?? r.status.name}',
      );
    }
    await CursorAgentFixLogService.instance.record(
      CursorAgentFixEntry(
        component: 'hosts_health_probe',
        action: 'repair_if_needed',
        ok: ok,
        verdict: ok
            ? 'hosts managed region regenerated'
            : 'hosts repair failed: ${r.message ?? r.status.name}',
        reason: reason,
        details: status.toJson(),
        failedLayers: ok ? const <String>[] : <String>['hosts:${status.issue}'],
        appliedLayers: ok ? <String>['hosts_regenerate'] : const <String>[],
        fixesAttempted: <String>[status.issue ?? 'unknown'],
      ),
    );
    return ok;
  }

  int _countManagedSinkholeLines(String hosts) {
    const String start = MacSystemBlockService.kMarkerStart;
    const String end = MacSystemBlockService.kMarkerEnd;
    final int i = hosts.indexOf(start);
    final int j = hosts.indexOf(end);
    if (i < 0 || j <= i) return 0;
    final String region = hosts.substring(i, j);
    int n = 0;
    for (final String line in region.split('\n')) {
      final String t = line.trim();
      if (t.startsWith('0.0.0.0 ') || t.startsWith(':: ')) {
        n++;
      }
    }
    return n;
  }

  Future<int> _rescueMergedBytes() async {
    try {
      final String dir = WindowsEmergencyBlockService.programDataDir();
      final File f = File(p.join(dir, 'hosts_merged.txt'));
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }
}
