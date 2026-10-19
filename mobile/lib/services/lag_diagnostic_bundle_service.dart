import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';
import 'lag_process_census.dart';
import 'lag_work_classifier.dart';
import 'work_context_tracker.dart';

/// Unified lag / CPU spike / UI freeze recorder for Cursor & Claude agents.
///
/// All detectors call [record] with their metrics. Output lives under
/// `Documents/SixVPN_Blocker_Debug/`:
///   * `lag_events.jsonl` — append-only timeline (rotated at 512KB)
///   * `lag_diagnostic_last.json` — full context of the most recent severe event
///   * `lag_diagnostic_summary.json` — counts + paths for quick agent triage
final class LagDiagnosticBundleService {
  LagDiagnosticBundleService._();
  static final LagDiagnosticBundleService instance =
      LagDiagnosticBundleService._();

  static const int _kMaxJsonlBytes = 512 * 1024;

  int _cpuSpikeCount = 0;
  int _uiStallCount = 0;
  int _uiFreezeCount = 0;
  int _severeFreezeCount = 0;
  int _severeLagSessionCount = 0;
  DateTime? _lastEventAt;
  String? _lastKind;

  String get debugFolder => CrashJournalService.instance.debugFolderPath;

  String get eventsJsonlPath => p.join(debugFolder, 'lag_events.jsonl');

  String get lastJsonPath => p.join(debugFolder, 'lag_diagnostic_last.json');

  String get summaryPath => p.join(debugFolder, 'lag_diagnostic_summary.json');

  /// Live revision for diagnostics UI.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void> record({
    required String kind,
    required String severity,
    required Map<String, Object?> metrics,
    Map<String, int>? childProcesses,
  }) async {
    final DateTime at = DateTime.now();
    if (kind == 'cpu_spike') {
      _cpuSpikeCount++;
    } else if (kind == 'ui_stall') {
      _uiStallCount++;
    } else if (kind == 'ui_freeze') {
      _uiFreezeCount++;
    } else if (kind == 'severe_ui_freeze') {
      _severeFreezeCount++;
    } else if (kind == 'severe_lag_session_bug' ||
        kind == 'severe_lag_session_expected') {
      _severeLagSessionCount++;
    }
    _lastEventAt = at;
    _lastKind = kind;

    final Map<String, int> census =
        childProcesses ?? await LagProcessCensus.countWindows();
    String buildLine = '';
    try {
      buildLine = await BuildIdentityService.instance.summaryLine();
    } catch (_) {}

    final LagWorkClassification classification = LagWorkClassifier.classify(
      activeLabels: WorkContextTracker.instance.activeLabels(),
      triggerKind: kind,
      highChildProcessStorm: (census['reg'] ?? 0) >= 12 ||
          (census['powershell'] ?? 0) >= 8,
    );

    final Map<String, Object?> event = <String, Object?>{
      'schemaVersion': 2,
      'reportKind': 'six_vpn_lag_diagnostic',
      'at': at.toIso8601String(),
      'kind': kind,
      'severity': severity,
      'buildIdentity': buildLine,
      'classification': classification.toJson(),
      'metrics': metrics,
      'activeWork': WorkContextTracker.instance.activeStackJson(),
      'recentWork': WorkContextTracker.instance.recentCompletedJson(),
      'recentLogLines': AppLogger.instance.recentLines(60),
      'childProcesses': census,
      'memoryMb': <String, Object?>{
        'currentRss': ProcessInfo.currentRss / (1024 * 1024),
        'peakRss': ProcessInfo.maxRss / (1024 * 1024),
      },
      'agentHints': <String, Object?>{
        'readme':
            'High reg/powershell/conhost counts → spawn-storm from a background '
            'probe. Check activeWork + recentWork + recentLogLines for the '
            'exact service label. Primary suspects: boot_browser_autofix, '
            'universal_browser_block.syncNow, browser_block_health_monitor, '
            'live_block_status_card refresh.',
        'readOrder': <String>[
          'lag_diagnostic_last.json',
          'lag_events.jsonl (tail)',
          'cpu_spike_last.json',
          'app_lag_last.json',
          'freeze_log.jsonl',
          '6vpn_logs/app.log',
        ],
        'powershell':
            'mobile/tools/Read-LagDiagnostics.ps1',
      },
    };

    try {
      final Directory dir = Directory(debugFolder);
      if (!await dir.exists()) await dir.create(recursive: true);

      await _appendJsonl(event);
      await File(lastJsonPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(event),
        flush: true,
      );
      await _writeSummary(at);
      revision.value++;
    } catch (e) {
      AppLogger.instance.warn('lag_diagnostic_bundle persist failed: $e');
    }
  }

  Future<void> _appendJsonl(Map<String, Object?> event) async {
    final File jsonl = File(eventsJsonlPath);
    if (await jsonl.exists() && await jsonl.length() > _kMaxJsonlBytes) {
      final File rotated = File('${jsonl.path}.1');
      if (await rotated.exists()) await rotated.delete();
      await jsonl.rename(rotated.path);
    }
    await jsonl.writeAsString(
      '${jsonEncode(event)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> _writeSummary(DateTime at) async {
    final Map<String, Object?> summary = <String, Object?>{
      'schemaVersion': 1,
      'updatedAt': at.toIso8601String(),
      'counts': <String, int>{
        'cpuSpike': _cpuSpikeCount,
        'uiStall': _uiStallCount,
        'uiFreeze': _uiFreezeCount,
        'severeUiFreeze': _severeFreezeCount,
        'severeLagSession': _severeLagSessionCount,
        'total': _cpuSpikeCount +
            _uiStallCount +
            _uiFreezeCount +
            _severeFreezeCount +
            _severeLagSessionCount,
      },
      'lastEvent': <String, Object?>{
        'at': _lastEventAt?.toIso8601String(),
        'kind': _lastKind,
      },
      'paths': <String, String>{
        'debugFolder': debugFolder,
        'lagEventsJsonl': eventsJsonlPath,
        'lagDiagnosticLast': lastJsonPath,
        'cpuSpikeLast': p.join(debugFolder, 'cpu_spike_last.json'),
        'appLagLast': p.join(debugFolder, 'app_lag_last.json'),
        'freezeLog': p.join(debugFolder, 'freeze_log.jsonl'),
        'severeFreezeLast': p.join(debugFolder, 'severe_freeze_last.json'),
        'severeLagSessionLast': p.join(debugFolder, 'severe_lag_session_last.json'),
        'cursorFullPack': p.join(debugFolder, 'cursor_full_diagnostic_pack.json'),
        'appLog': p.join(
          Platform.environment['LOCALAPPDATA'] ?? '',
          'SixVPNBlocker',
          '6vpn_logs',
          'app.log',
        ),
      },
    };
    await File(summaryPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(summary),
      flush: true,
    );
  }

  /// Agent-ready text block for clipboard / Cursor chat.
  Future<String> agentPrompt({int tailEvents = 5}) async {
    final StringBuffer sb = StringBuffer()
      ..writeln('=== Focus Fense — Lag diagnostic bundle ===')
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln('Folder: $debugFolder')
      ..writeln('');

    try {
      final File summary = File(summaryPath);
      if (await summary.exists()) {
        sb.writeln('--- lag_diagnostic_summary.json ---');
        sb.writeln(await summary.readAsString());
        sb.writeln('');
      }
    } catch (_) {}

    try {
      final File last = File(lastJsonPath);
      if (await last.exists()) {
        sb.writeln('--- lag_diagnostic_last.json ---');
        sb.writeln(await last.readAsString());
        sb.writeln('');
      }
    } catch (_) {}

    try {
      final File session = File(p.join(debugFolder, 'severe_lag_session_last.json'));
      if (await session.exists()) {
        sb.writeln('--- severe_lag_session_last.json (elapsed + legitimacy) ---');
        sb.writeln(await session.readAsString());
        sb.writeln('');
      }
    } catch (_) {}

    try {
      final File jsonl = File(eventsJsonlPath);
      if (await jsonl.exists()) {
        final List<String> lines = await jsonl.readAsLines();
        final Iterable<String> tail =
            lines.length <= tailEvents ? lines : lines.sublist(lines.length - tailEvents);
        sb.writeln('--- lag_events.jsonl (last $tailEvents) ---');
        for (final String line in tail) {
          sb.writeln(line);
        }
      }
    } catch (_) {}

    if (!Platform.isWindows && !Platform.isMacOS) {
      sb.writeln('');
      sb.writeln(
        'iOS/Android: copy this entire block → paste into Cursor on your PC.',
      );
    }

    return sb.toString();
  }
}
