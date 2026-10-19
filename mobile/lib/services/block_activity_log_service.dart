import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'backup_service.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';
import 'extension_rules_builder.dart';
import 'local_database.dart';
import 'protection_coverage_service.dart';
import 'recent_site_events.dart';
import 'usage_ingest_server.dart';
import 'schedule_block_stats_service.dart';
import 'windows_apply_status_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_system_block_service.dart';

/// Structured block / sync / browser activity for in-app UI + Cursor agents.
///
/// Files (same folder as crash journal):
///   * `block_activity.jsonl` — append-only event stream
///   * `block_activity_summary.json` — latest snapshot (one read for agents)
final class BlockActivityLogService {
  BlockActivityLogService._();
  static final BlockActivityLogService instance = BlockActivityLogService._();

  static const int _kMaxMem = 120;
  static const int _kMaxJsonlBytes = 768 * 1024;
  static const Duration _kSnapshotInterval = Duration(seconds: 120);
  static const Duration _kRulesFetchDebounce = Duration(seconds: 8);

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final List<BlockActivityEvent> _events = <BlockActivityEvent>[];

  Timer? _snapshotTimer;
  DateTime? _lastRulesFetchLog;
  String? _buildTag;
  bool _started = false;
  // Queue of JSONL lines pending append. Drained by an async writer so the
  // hot record() path never blocks the UI isolate on file I/O — previously
  // every block hit / browser visit / boot event did a full sync open + write
  // + flush + close on the UI thread, which adds up fast.
  final List<String> _jsonlPending = <String>[];
  bool _jsonlDraining = false;

  List<BlockActivityEvent> get events =>
      List<BlockActivityEvent>.unmodifiable(_events);

  String get jsonlPath =>
      p.join(CrashJournalService.instance.debugFolderPath, 'block_activity.jsonl');

  String get summaryPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'block_activity_summary.json',
      );

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await CrashJournalService.instance.warmup();
    try {
      _buildTag = await BuildIdentityService.instance.summaryLine();
    } catch (_) {}
    BackupService.instance.status.addListener(_onBackupStatus);
    record(
      kind: BlockActivityKind.boot,
      message: '차단 활동 로그 시작',
      data: <String, Object?>{
        'jsonl': jsonlPath,
        'summary': summaryPath,
      },
    );
    unawaited(refreshSnapshot(reason: 'boot'));
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer.periodic(_kSnapshotInterval, (_) {
      unawaited(refreshSnapshot(reason: 'periodic', light: true));
    });
  }

  void stop() {
    _snapshotTimer?.cancel();
    BackupService.instance.status.removeListener(_onBackupStatus);
    _started = false;
  }

  void _onBackupStatus() {
    final BackupStatus s = BackupService.instance.status.value;
    switch (s.kind) {
      case BackupStatusKind.synced:
        record(
          kind: BlockActivityKind.autoSave,
          message: '자동 저장 완료',
          data: <String, Object?>{
            'when': s.when?.toIso8601String(),
            'path': s.path,
          },
        );
      case BackupStatusKind.error:
        record(
          kind: BlockActivityKind.autoSave,
          message: '자동 저장 실패',
          data: <String, Object?>{
            'error': s.error,
          },
          level: 'warn',
        );
      case BackupStatusKind.saving:
        record(
          kind: BlockActivityKind.autoSave,
          message: '자동 저장 중…',
          debounceKey: 'auto_save_saving',
        );
      default:
        break;
    }
  }

  void record({
    required BlockActivityKind kind,
    required String message,
    Map<String, Object?>? data,
    String level = 'info',
    String? debounceKey,
  }) {
    if (debounceKey != null) {
      final BlockActivityEvent? last = _events.isEmpty ? null : _events.first;
      if (last != null &&
          last.debounceKey == debounceKey &&
          DateTime.now().difference(last.at) < const Duration(seconds: 3)) {
        return;
      }
    }
    final BlockActivityEvent ev = BlockActivityEvent(
      at: DateTime.now(),
      kind: kind,
      message: message,
      data: data,
      level: level,
      debounceKey: debounceKey,
    );
    _events.insert(0, ev);
    if (_events.length > _kMaxMem) {
      _events.removeRange(_kMaxMem, _events.length);
    }
    revision.value++;
    _appendJsonl(ev);
    AppLogger.instance.info('[block_activity] ${kind.name}: $message');
  }

  void recordRulesFetch({
    required int keywordCount,
    required int domainCount,
    required int searchQueryCount,
    String? userAgent,
  }) {
    final DateTime now = DateTime.now();
    if (_lastRulesFetchLog != null &&
        now.difference(_lastRulesFetchLog!) < _kRulesFetchDebounce) {
      return;
    }
    _lastRulesFetchLog = now;
    record(
      kind: BlockActivityKind.rulesFetch,
      message:
          '확장 규칙 요청 — 키워드 $keywordCount · 도메인 $domainCount · 검색어 $searchQueryCount',
      data: <String, Object?>{
        'keywords': keywordCount,
        'domains': domainCount,
        'searchQueries': searchQueryCount,
        if (userAgent != null) 'ua': userAgent,
      },
    );
  }

  /// True when extension reported `/block` for [videoId] after [since].
  bool hasRecentBlockForVideo(
    String videoId, {
    required DateTime since,
    String? browser,
  }) {
    final String id = videoId.trim().toLowerCase();
    if (id.isEmpty) return false;
    for (final BlockActivityEvent e in _events.reversed) {
      if (e.at.isBefore(since)) break;
      if (e.kind != BlockActivityKind.blockHit) continue;
      final String url = '${e.data?['url'] ?? ''}';
      if (!url.toLowerCase().contains(id)) continue;
      if (browser != null &&
          '${e.data?['browser'] ?? ''}'.toLowerCase() != browser) {
        continue;
      }
      return true;
    }
    return false;
  }

  bool hasRecentBlockForUrl(
    String url, {
    required DateTime since,
    String? browser,
  }) {
    final String u = url.trim().toLowerCase();
    if (u.isEmpty) return false;
    for (final BlockActivityEvent e in _events.reversed) {
      if (e.at.isBefore(since)) break;
      if (e.kind != BlockActivityKind.blockHit) continue;
      final String hit = '${e.data?['url'] ?? ''}'.toLowerCase();
      if (!hit.contains(u) && !u.contains(hit)) continue;
      if (browser != null &&
          '${e.data?['browser'] ?? ''}'.toLowerCase() != browser) {
        continue;
      }
      return true;
    }
    return false;
  }

  void recordBrowserBlock({
    required String rule,
    required String url,
    String kind = 'navigation',
    String? browser,
  }) {
    record(
      kind: BlockActivityKind.blockHit,
      message: '차단됨: $rule',
      data: <String, Object?>{
        'rule': rule,
        'url': url,
        'blockKind': kind,
        if (browser != null) 'browser': browser,
      },
      level: 'block',
    );
    // Update per-schedule stats asynchronously (fire-and-forget).
    unawaited(ScheduleBlockStatsService.instance.recordBlockHit(
      rule: rule,
      url: url,
    ));
  }

  void recordBrowserVisit(String host, {int seconds = 0}) {
    record(
      kind: BlockActivityKind.browserVisit,
      message: '브라우저 활동: $host (${seconds}s)',
      data: <String, Object?>{'host': host, 'seconds': seconds},
      debounceKey: 'visit_$host',
    );
  }

  Future<void> refreshSnapshot({
    String reason = 'manual',
    bool light = false,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    try {
      final ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildActiveNow();
      final List<Map<String, Object?>> activeSchedules =
          await LocalDatabase.instance.schedulesActiveNow(DateTime.now());
      final bool hostsActive = Platform.isWindows
          ? await WindowsSystemBlockService.instance.isActive()
          : false;
      final bool browserOk = light
          ? false
          : Platform.isWindows
              ? await WindowsApplyStatusService.isBrowserProtectionSufficient()
              : false;
      final ProtectionCoverageReport? coverage = light
          ? null
          : Platform.isWindows || Platform.isMacOS
              ? await ProtectionCoverageService.instance.analyze(force: false)
              : null;
      final bool browserOkResolved = light && Platform.isWindows
          ? (await WindowsExtensionGuardService.verifyAllPolicies())
              .protectionOk
          : browserOk;

      final Map<String, Object?> summary = <String, Object?>{
        'updatedAt': DateTime.now().toIso8601String(),
        'reason': reason,
        if (_buildTag != null) 'build': _buildTag,
        'rulesApi': <String, Object?>{
          'running': UsageIngestServer.instance.isRunning,
          'port': UsageIngestServer.instance.boundPort,
        },
        'activeRules': <String, Object?>{
          'schedulesActiveNow': activeSchedules.length,
          'keywords': rules.keywords.length,
          'domains': rules.blockedDomains.length,
          'searchQueries': rules.searchQueries.length,
          'keywordSample': rules.keywords.take(8).toList(),
          'domainSample': rules.blockedDomains.take(8).toList(),
        },
        'protection': <String, Object?>{
          'hostsActive': hostsActive,
          'browserProtectionOk': browserOkResolved,
          if (coverage != null) ...<String, Object?>{
            'chromeExtensionOk': coverage.chromeExtensionOk,
            'edgeExtensionOk': coverage.edgeExtensionOk,
            'firefoxExtensionOk': coverage.firefoxExtensionOk,
            'rulesApiRunning': coverage.rulesApiRunning,
            'gapCount': coverage.gaps.length,
            'topGap': coverage.gaps.isEmpty ? null : coverage.gaps.first.title,
          },
        },
        'autoSave': _backupStatusLabel(),
        'recentBlocks': _events
            .where((BlockActivityEvent e) => e.kind == BlockActivityKind.blockHit)
            .take(10)
            .map((BlockActivityEvent e) => e.toJson())
            .toList(),
        'recentVisits': RecentSiteEvents.instance
            .snapshot()
            .take(8)
            .map(
              (RecentSiteEvent e) => <String, Object?>{
                'host': e.host,
                'at': e.at.toIso8601String(),
                'seconds': e.seconds,
              },
            )
            .toList(),
        'recentEvents': _events
            .take(25)
            .map((BlockActivityEvent e) => e.toJson())
            .toList(),
      };

      record(
        kind: BlockActivityKind.snapshot,
        message:
            '규칙 스냅샷 — 스케줄 ${activeSchedules.length} · 키워드 ${rules.keywords.length} · 도메인 ${rules.blockedDomains.length}',
        data: summary['activeRules'] as Map<String, Object?>?,
        debounceKey: 'snapshot_$reason',
      );

      final Directory dir =
          Directory(CrashJournalService.instance.debugFolderPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(summaryPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(summary),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('block_activity snapshot failed', error: e);
    }
  }

  String _backupStatusLabel() {
    final BackupStatus s = BackupService.instance.status.value;
    switch (s.kind) {
      case BackupStatusKind.synced:
        return '완료';
      case BackupStatusKind.saving:
        return '저장 중';
      case BackupStatusKind.queued:
        return '예약';
      case BackupStatusKind.error:
        return '실패';
      case BackupStatusKind.idle:
        return '대기';
    }
  }

  void _appendJsonl(BlockActivityEvent ev) {
    // Enqueue; an async drainer batches writes off the UI thread so a busy
    // browser (many block hits) never stalls the app.
    _jsonlPending.add('${jsonEncode(ev.toJson())}\n');
    if (!_jsonlDraining) {
      _jsonlDraining = true;
      unawaited(_drainJsonl());
    }
  }

  Future<void> _drainJsonl() async {
    try {
      while (_jsonlPending.isNotEmpty) {
        // Batch everything queued right now into one append so each I/O burst
        // covers many events instead of one-per-write.
        final List<String> batch = List<String>.from(_jsonlPending);
        _jsonlPending.clear();
        try {
          final Directory root =
              Directory(CrashJournalService.instance.debugFolderPath);
          if (!await root.exists()) {
            await root.create(recursive: true);
          }
          final File f = File(jsonlPath);
          if (await f.exists() && await f.length() > _kMaxJsonlBytes) {
            final File bak = File('$jsonlPath.bak');
            if (await bak.exists()) await bak.delete();
            await f.rename(bak.path);
          }
          await f.writeAsString(
            batch.join(),
            mode: FileMode.append,
            flush: true,
          );
        } catch (_) {/* best-effort */}
        // Yield so a flood of events can re-coalesce instead of starving the UI.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      _jsonlDraining = false;
    }
  }

  Future<String> exportForCursor({int maxLines = 80}) async {
    final StringBuffer sb = StringBuffer()
      ..writeln('=== Focus Fense — block activity (Cursor) ===')
      ..writeln('summary: $summaryPath')
      ..writeln('jsonl: $jsonlPath')
      ..writeln('');
    try {
      final File sum = File(summaryPath);
      if (await sum.exists()) {
        sb.writeln('--- block_activity_summary.json ---');
        sb.writeln(await sum.readAsString());
        sb.writeln('');
      }
    } catch (_) {}
    sb.writeln('--- recent events (newest first) ---');
    for (final BlockActivityEvent e in _events.take(maxLines)) {
      sb.writeln(e.displayLine);
    }
    return sb.toString();
  }
}

enum BlockActivityKind {
  boot,
  snapshot,
  blockHit,
  browserVisit,
  rulesFetch,
  hostsApply,
  autoSave,
  protection,
  selfHeal,
}

final class BlockActivityEvent {
  const BlockActivityEvent({
    required this.at,
    required this.kind,
    required this.message,
    this.data,
    this.level = 'info',
    this.debounceKey,
  });

  final DateTime at;
  final BlockActivityKind kind;
  final String message;
  final Map<String, Object?>? data;
  final String level;
  final String? debounceKey;

  String get displayLine {
    final String t =
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
    return '[$t] ${kind.name} | $message';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'ts': at.toIso8601String(),
        'kind': kind.name,
        'level': level,
        'message': message,
        if (data != null && data!.isNotEmpty) 'data': data,
      };
}
