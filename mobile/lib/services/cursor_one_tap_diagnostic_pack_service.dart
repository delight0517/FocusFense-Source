import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'app_operation_progress_service.dart';
import 'block_activity_log_service.dart';
import 'browser_block_enforcement_health_service.dart';
import 'browser_block_health_monitor_service.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';
import 'cursor_agent_snapshot_service.dart';
import 'lag_diagnostic_bundle_service.dart';

/// One button → full freeze/lag/block/plugin state for Cursor / Claude.
///
/// Output (stable paths under Documents debug folder):
///   * `cursor_full_diagnostic_pack.json` — machine-readable bundle
///   * `cursor_agent_handoff_prompt.txt` — paste into Cursor chat
///
/// Live fetch (app running): `GET http://127.0.0.1:17361/agent/full-pack`
/// Shell: `mobile/tools/Read-CursorFullDiagnosticPack.ps1`
final class CursorOneTapDiagnosticPackService {
  CursorOneTapDiagnosticPackService._();
  static final CursorOneTapDiagnosticPackService instance =
      CursorOneTapDiagnosticPackService._();

  bool _busy = false;
  String? _progressId;

  String get debugFolder => CrashJournalService.instance.debugFolderPath;

  String get packJsonPath =>
      p.join(debugFolder, 'cursor_full_diagnostic_pack.json');

  String get promptPath =>
      p.join(debugFolder, 'cursor_agent_handoff_prompt.txt');

  String get severeFreezePath =>
      p.join(debugFolder, 'severe_freeze_last.json');

  bool get isBusy => _busy;

  Future<Map<String, Object?>> runFullPack({
    String reason = 'manual',
    bool probeBrowsers = true,
  }) async {
    if (_busy) {
      return _readPackJson() ??
          <String, Object?>{'busy': true, 'message': 'pack build in flight'};
    }
    _busy = true;
    _progressId = AppOperationProgressService.instance.begin(
      title: 'Cursor 원탭 진단',
      step: '준비',
      fraction: 0.05,
      estimatedTotal: const Duration(minutes: 2),
      id: 'cursor_full_pack',
    );
    try {
      await CrashJournalService.instance.warmup();
      _setProgress('준비', 0.05);

      final String build = await BuildIdentityService.instance.summaryLine();
      _setProgress('차단 활동 스냅샷', 0.15);
      await BlockActivityLogService.instance.refreshSnapshot(
        reason: 'full_pack_$reason',
      );

      _setProgress('에이전트 스냅샷 (플러그인·규칙)', 0.35);
      final Map<String, Object?> snapshot =
          await CursorAgentSnapshotService.instance.refresh(
        reason: 'full_pack_$reason',
        light: false,
      );

      Map<String, Object?>? browserHealthJson;
      List<Map<String, Object?>> blockFailures = <Map<String, Object?>>[];
      if (Platform.isWindows && probeBrowsers) {
        _setProgress('브라우저 URL 차단 실측', 0.55);
        final BrowserBlockHealthReport report =
            await BrowserBlockHealthMonitorService.instance.probe(
          reason: 'full_pack_$reason',
        );
        browserHealthJson = report.toJson();
        blockFailures = _blockFailuresFromHealth(report);
      }

      _setProgress('확장·규칙 연결 상태', 0.7);
      final BrowserEnforcementHealth enforce =
          await BrowserBlockEnforcementHealthService.instance.analyze(
        force: true,
      );
      if (enforce.needsUserAction) {
        blockFailures.add(<String, Object?>{
          'source': 'enforcement_health',
          'headline': enforce.headline,
          'explanation': enforce.explanation,
          'phase': enforce.phase.name,
          'chromeUnprotectedRunning': enforce.chromeUnprotectedRunning,
        });
      }

      _setProgress('렉·프리즈 로그 수집', 0.85);
      final Map<String, Object?> lagBundle = await _collectLagSection();
      final Map<String, Object?>? blockSummary =
          await _readJsonFile(BlockActivityLogService.instance.summaryPath);

      final Map<String, Object?> pack = <String, Object?>{
        'schemaVersion': 1,
        'reportKind': 'six_vpn_cursor_full_pack',
        'generatedAt': DateTime.now().toIso8601String(),
        'reason': reason,
        'buildIdentity': build,
        'cursorReadme': 'mobile/tools/Read-CursorFullDiagnosticPack.ps1',
        'liveApi': <String, String>{
          'fullPack': 'GET http://127.0.0.1:17361/agent/full-pack',
          'snapshot': 'GET http://127.0.0.1:17361/agent/snapshot',
        },
        'paths': <String, String>{
          'packJson': packJsonPath,
          'handoffPrompt': promptPath,
          'lagSummary': LagDiagnosticBundleService.instance.summaryPath,
          'lagLast': LagDiagnosticBundleService.instance.lastJsonPath,
          'browserHealth': BrowserBlockHealthMonitorService.instance.reportPath,
          'blockSummary': BlockActivityLogService.instance.summaryPath,
          'blockJsonl': BlockActivityLogService.instance.jsonlPath,
          'severeFreeze': severeFreezePath,
          'snapshot': CursorAgentSnapshotService.instance.snapshotPath,
        },
        'agentInstructions': <String, Object?>{
          'role':
              'Fix Focus Fense freeze/lag/block failures. Read this pack first.',
          'readOrder': <String>[
            'cursor_full_diagnostic_pack.json',
            'lag_diagnostic_last.json',
            'severe_freeze_last.json (if present)',
            'browser_block_health.json',
            'block_activity_summary.json',
            'cursor_agent_snapshot.json',
          ],
          'freezeHints': <String>[
            'severeFreezes → check lag.activeWork + recentLogLines for spawn-storm',
            'High reg/powershell counts → stagger or debounce background probes',
            '30s+ UI freeze without snackbar → see severe_freeze_last.json',
          ],
          'blockHints': <String>[
            'blockFailures → URLBlocklist / extension / Firefox WebsiteFilter per browser',
            'chromeUnprotectedRunning → BrowserOneTapService protected Chrome',
            'effectivelyBlockActive false → kill guard + policy re-apply',
          ],
        },
        'lag': lagBundle,
        'blocking': <String, Object?>{
          'failures': blockFailures,
          'failureCount': blockFailures.length,
          'enforcement': <String, Object?>{
            'phase': enforce.phase.name,
            'needsUserAction': enforce.needsUserAction,
            'headline': enforce.headline,
            'explanation': enforce.explanation,
            'youtubeRuleCount': enforce.youtubeRuleCount,
            'recentBlockCount': enforce.recentBlockCount,
            'rulesFetchSeen': enforce.rulesFetchSeen,
            'browserInstallOk': enforce.browserInstallOk,
            'rulesApiRunning': enforce.rulesApiRunning,
            'chromeUnprotectedRunning': enforce.chromeUnprotectedRunning,
          },
          if (browserHealthJson != null) 'browserHealth': browserHealthJson,
          if (blockSummary != null) 'activitySummary': blockSummary,
        },
        'pluginsAndRules': <String, Object?>{
          'snapshot': snapshot,
        },
        'verdict': <String, Object?>{
          'hasBlockFailures': blockFailures.isNotEmpty,
          'failureCount': blockFailures.length,
          'hasSevereFreeze': lagBundle['severeFreeze'] != null,
          'lagEventTotal': (lagBundle['counts'] as Map?)?['total'] ?? 0,
        },
      };

      _setProgress('파일 저장', 0.95);
      final String prompt = _buildHandoffPrompt(pack);
      final Directory dir = Directory(debugFolder);
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(packJsonPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(pack),
        flush: true,
      );
      await File(promptPath).writeAsString(prompt, flush: true);

      final int lagTotal = (lagBundle['counts'] is Map)
          ? int.tryParse('${(lagBundle['counts'] as Map)['total']}') ?? 0
          : 0;
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.snapshot,
        message:
            'Cursor 원탭 진단 팩 생성 — blockFailures=${blockFailures.length} '
            'lagTotal=$lagTotal',
        data: <String, Object?>{
          'packPath': packJsonPath,
          'promptPath': promptPath,
          'failureCount': blockFailures.length,
        },
        debounceKey: 'cursor_full_pack',
      );
      AppLogger.instance.info(
        'cursor_full_pack [$reason] failures=${blockFailures.length} '
        'path=$packJsonPath',
      );
      _setProgress('완료', 1.0);
      return pack;
    } catch (e, st) {
      AppLogger.instance.error('cursor_full_pack failed', error: e, stack: st);
      rethrow;
    } finally {
      if (_progressId != null) {
        AppOperationProgressService.instance.end(_progressId!);
        _progressId = null;
      }
      _busy = false;
    }
  }

  void _setProgress(String step, double fraction) {
    final String? id = _progressId;
    if (id == null) return;
    AppOperationProgressService.instance.update(
      id,
      step: step,
      fraction: fraction,
    );
  }

  Future<Map<String, Object?>> _collectLagSection() async {
    final LagDiagnosticBundleService bundle = LagDiagnosticBundleService.instance;
    final Map<String, Object?>? summary =
        await _readJsonFile(bundle.summaryPath);
    final Map<String, Object?>? last = await _readJsonFile(bundle.lastJsonPath);
    final Map<String, Object?>? severe =
        await _readJsonFile(severeFreezePath);
    final Map<String, Object?>? cpuSpike = await _readJsonFile(
      p.join(debugFolder, 'cpu_spike_last.json'),
    );
    final Map<String, Object?>? appLag = await _readJsonFile(
      p.join(debugFolder, 'app_lag_last.json'),
    );
    final List<String> freezeTail = await _readJsonlTail(
      p.join(debugFolder, 'freeze_log.jsonl'),
      limit: 5,
    );
    return <String, Object?>{
      'counts': summary?['counts'],
      'lastEvent': summary?['lastEvent'],
      'summary': summary,
      'last': last,
      'severeFreeze': severe,
      'cpuSpikeLast': cpuSpike,
      'appLagLast': appLag,
      'freezeLogTail': freezeTail,
    };
  }

  List<Map<String, Object?>> _blockFailuresFromHealth(
    BrowserBlockHealthReport report,
  ) {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final BrowserHealth b in report.browsers) {
      if (!b.installed) continue;
      if (b.effectivelyBlockActive && b.blockActive) continue;
      out.add(<String, Object?>{
        'source': 'browser_block_health',
        'browserId': b.id,
        'displayName': b.displayName,
        'running': b.running,
        'blockActive': b.blockActive,
        'effectivelyBlockActive': b.effectivelyBlockActive,
        'reasons': b.reasons,
        'remedy': b.remedy?.toJson(),
      });
    }
    return out;
  }

  String _buildHandoffPrompt(Map<String, Object?> pack) {
    final StringBuffer sb = StringBuffer()
      ..writeln('=== Focus Fense — Cursor / Claude Handoff Pack ===')
      ..writeln('Generated: ${pack['generatedAt']}')
      ..writeln('Build: ${pack['buildIdentity']}')
      ..writeln('')
      ..writeln('## Your job')
      ..writeln(
        'Diagnose and fix freeze/lag OR block-not-working issues in this Flutter '
        'Windows app. Use the JSON paths below — do not guess.',
      )
      ..writeln('')
      ..writeln('## Read order')
      ..writeln('1. cursor_full_diagnostic_pack.json (full bundle)')
      ..writeln('2. lag_diagnostic_last.json + severe_freeze_last.json')
      ..writeln('3. browser_block_health.json')
      ..writeln('4. block_activity_summary.json')
      ..writeln('')
      ..writeln('## Paths')
      ..writeln('Folder: $debugFolder');
    final Object? paths = pack['paths'];
    if (paths is Map) {
      for (final MapEntry<Object?, Object?> e in paths.entries) {
        sb.writeln('  ${e.key}: ${e.value}');
      }
    }
    sb.writeln('');
    final Object? verdict = pack['verdict'];
    if (verdict is Map) {
      sb.writeln('## Verdict');
      sb.writeln(const JsonEncoder.withIndent('  ').convert(verdict));
      sb.writeln('');
    }
    final Object? blocking = pack['blocking'];
    if (blocking is Map) {
      final Object? failures = blocking['failures'];
      if (failures is List && failures.isNotEmpty) {
        sb.writeln('## Block failures (fix these)');
        for (final Object f in failures) {
          sb.writeln(const JsonEncoder.withIndent('  ').convert(f));
        }
        sb.writeln('');
      }
      final Object? enf = blocking['enforcement'];
      if (enf is Map && enf['needsUserAction'] == true) {
        sb.writeln('## Enforcement needs action');
        sb.writeln('${enf['headline']}\n${enf['explanation']}');
        sb.writeln('');
      }
    }
    final Object? lag = pack['lag'];
    if (lag is Map && lag['severeFreeze'] != null) {
      sb.writeln('## CRITICAL: 30s+ UI freeze detected');
      sb.writeln(const JsonEncoder.withIndent('  ').convert(lag['severeFreeze']));
      sb.writeln('');
    }
    sb.writeln('## Full pack JSON (embedded)');
    sb.writeln(const JsonEncoder.withIndent('  ').convert(pack));
    return sb.toString();
  }

  Future<String> readPromptForClipboard() async {
    final File f = File(promptPath);
    if (await f.exists()) return f.readAsString();
    final Map<String, Object?>? existing = _readPackJson();
    if (existing != null) return _buildHandoffPrompt(existing);
    return '진단 팩이 아직 없습니다 — 설정→진단에서 「Cursor 원탭 진단」을 실행하세요.';
  }

  Map<String, Object?>? _readPackJson() {
    try {
      final File f = File(packJsonPath);
      if (!f.existsSync()) return null;
      final Object? j = jsonDecode(f.readAsStringSync());
      if (j is Map) return Map<String, Object?>.from(j);
    } catch (_) {}
    return null;
  }

  Future<Map<String, Object?>?> _readJsonFile(String path) async {
    try {
      final File f = File(path);
      if (!await f.exists()) return null;
      final Object? j = jsonDecode(await f.readAsString());
      if (j is Map) return Map<String, Object?>.from(j);
    } catch (_) {}
    return null;
  }

  Future<List<String>> _readJsonlTail(String path, {int limit = 5}) async {
    try {
      final File f = File(path);
      if (!await f.exists()) return const <String>[];
      final List<String> lines = await f.readAsLines();
      if (lines.isEmpty) return const <String>[];
      final int start = lines.length > limit ? lines.length - limit : 0;
      return lines.sublist(start);
    } catch (_) {
      return const <String>[];
    }
  }
}
