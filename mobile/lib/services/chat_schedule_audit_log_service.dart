import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/chat_schedule_intent.dart';
import 'app_logger.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';

/// Audit trail of chat-driven schedule changes — "which chat message changed
/// which schedule, how" — kept for [kRetention] so Claude/Codex sessions (and
/// the developer) can debug chat-schedule behavior without guessing.
///
/// Files (same debug folder as `block_activity_log_service.dart`):
///   * `chat_schedule_audit.jsonl` — append-only event stream.
///   * `chat_schedule_audit_summary.json` — latest snapshot (one read for agents).
///
/// Schema + how to interpret it: `docs/CHAT_SCHEDULE_AUDIT_LOG.md`.
final class ChatScheduleAuditLogService {
  ChatScheduleAuditLogService._();
  static final ChatScheduleAuditLogService instance =
      ChatScheduleAuditLogService._();

  static const Duration kRetention = Duration(days: 7);
  static const int _kMaxMem = 300;
  static const Duration _kCompactInterval = Duration(hours: 1);

  final List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  DateTime? _lastCompactAt;
  bool _loaded = false;

  String get jsonlPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'chat_schedule_audit.jsonl',
  );

  String get summaryPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'chat_schedule_audit_summary.json',
  );

  /// Records one chat-schedule turn: the raw message, which schedule it
  /// touched, what actually changed (from [result]), and a snapshot of the
  /// whole conversation up to this point so it's clear *which conversation
  /// this schedule was formed at the end of*.
  Future<void> record({
    required String conversationId,
    required int turnIndex,
    required String message,
    required ChatScheduleApplyResult result,
    List<Map<String, String>> conversation = const <Map<String, String>>[],
  }) async {
    await _ensureLoaded();
    final ChatSchedulePreview preview = result.preview;
    final String action = result.pendingEdit != null
        ? 'deferred'
        : !result.ok
        ? 'blocked'
        : preview.willCreateSchedule
        ? 'create'
        : 'update';
    final BuildIdentity identity = await BuildIdentityService.instance.current();
    final Map<String, Object?> entry = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'appVersion': '${identity.version}+${identity.buildNumber}',
      'conversationId': conversationId,
      'turnIndex': turnIndex,
      'message': message,
      'scheduleId': preview.scheduleId,
      'scheduleName': preview.scheduleName,
      'action': action,
      'result': result.toJson(),
      'conversation': conversation,
    };
    _entries.add(entry);
    if (_entries.length > _kMaxMem) {
      _entries.removeRange(0, _entries.length - _kMaxMem);
    }
    try {
      final Directory dir = Directory(
        CrashJournalService.instance.debugFolderPath,
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(
        jsonlPath,
      ).writeAsString('${jsonEncode(entry)}\n', mode: FileMode.append, flush: true);
    } catch (e) {
      AppLogger.instance.warn('chat_schedule_audit append failed: $e');
    }
    await _maybeCompact();
    unawaited(_writeSummary());
  }

  /// All entries within [kRetention], oldest first. Safe to call from
  /// `BackupService` — this is what makes the audit trail part of the
  /// regular backup snapshot.
  Future<List<Map<String, Object?>>> recentEntries() async {
    await _ensureLoaded();
    _pruneInMemory();
    return List<Map<String, Object?>>.unmodifiable(_entries);
  }

  /// Self-describing note embedded directly in every export so a Claude or
  /// Codex session reading a pasted clipboard bundle can interpret it
  /// without needing repo access to `docs/CHAT_SCHEDULE_AUDIT_LOG.md`.
  static const Map<String, Object?> _kHowToInterpret = <String, Object?>{
    'forAgents':
        'Claude/Codex 공용 해석 가이드. 이 JSON은 최근 7일간 "어떤 채팅 메시지가 '
        '어떤 스케줄을 어떻게 바꿨는지"의 감사 기록이다. entries는 오래된 것부터 순서대로.',
    'entryFields': <String, String>{
      'ts': '이 적용이 일어난 시각 (ISO8601) — "언제"',
      'appVersion': '이 적용이 일어난 시점의 앱 버전+빌드 번호 — "어떤 버전에서"',
      'conversationId': '한 채팅창 세션 동안 고정되는 id — 같은 대화에서 나온 turn을 묶는다',
      'turnIndex': '해당 conversationId 안에서의 순서 (0부터)',
      'message': '사용자가 실제로 입력한 원문',
      'scheduleId': '영향을 받은 스케줄의 id',
      'scheduleName': '영향을 받은 스케줄 이름',
      'action':
          'create=새 스케줄 생성 / update=기존 스케줄 수정 / '
          'blocked=거부됨(대부분 잠금 정책) / deferred=타임락 종료 후 자동 적용 대기중',
      'result': 'ChatScheduleApplyResult 전체 — result.preview.warnings에 거부/보류 사유가 있음',
      'conversation': '이 적용이 나온 시점까지의 전체 대화 스냅샷 — "어떤 대화 끝에서 형성되었는지"',
    },
    'debuggingTip':
        'action이 blocked/deferred인데 사용자가 즉시 적용을 기대했다면 '
        'result.preview.warnings부터 확인 — 대부분 스케줄 잠금 정책이 의도대로 동작한 것이지 버그가 아니다.',
  };

  /// Pretty-printed JSON bundle meant to be copied straight to the
  /// clipboard for a developer / AI debugging session.
  Future<String> exportForBackup() async {
    final List<Map<String, Object?>> entries = await recentEntries();
    final BuildIdentity identity = await BuildIdentityService.instance.current();
    final Map<String, Object?> bundle = <String, Object?>{
      'kind': 'chat_schedule_audit_backup',
      'appVersion': '${identity.version}+${identity.buildNumber}',
      'appName': BuildIdentityService.kProductDisplayName,
      'operatingSystem': identity.operatingSystem,
      'exportedAt': DateTime.now().toIso8601String(),
      'retentionDays': kRetention.inDays,
      'entryCount': entries.length,
      'schemaDoc': 'docs/CHAT_SCHEDULE_AUDIT_LOG.md',
      'jsonl': jsonlPath,
      'howToInterpret': _kHowToInterpret,
      'entries': entries,
    };
    return const JsonEncoder.withIndent('  ').convert(bundle);
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final File f = File(jsonlPath);
      if (await f.exists()) {
        final List<String> lines = await f.readAsLines();
        final DateTime cutoff = DateTime.now().subtract(kRetention);
        for (final String line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final Object? decoded = jsonDecode(line);
            if (decoded is Map<String, Object?>) {
              final DateTime? ts = DateTime.tryParse('${decoded['ts']}');
              if (ts != null && ts.isBefore(cutoff)) continue;
              _entries.add(decoded);
            }
          } catch (_) {
            // skip malformed line
          }
        }
        if (_entries.length > _kMaxMem) {
          _entries.removeRange(0, _entries.length - _kMaxMem);
        }
      }
    } catch (e) {
      AppLogger.instance.warn('chat_schedule_audit load failed: $e');
    }
  }

  void _pruneInMemory() {
    final DateTime cutoff = DateTime.now().subtract(kRetention);
    _entries.removeWhere((Map<String, Object?> e) {
      final DateTime? ts = DateTime.tryParse('${e['ts']}');
      return ts == null || ts.isBefore(cutoff);
    });
  }

  /// Rewrites the jsonl file dropping entries older than [kRetention].
  /// Throttled so a burst of chat applies doesn't rewrite the file on every
  /// single one.
  Future<void> _maybeCompact() async {
    final DateTime now = DateTime.now();
    if (_lastCompactAt != null &&
        now.difference(_lastCompactAt!) < _kCompactInterval) {
      return;
    }
    _lastCompactAt = now;
    _pruneInMemory();
    try {
      final StringBuffer sb = StringBuffer();
      for (final Map<String, Object?> e in _entries) {
        sb.writeln(jsonEncode(e));
      }
      final File f = File(jsonlPath);
      final File tmp = File('$jsonlPath.tmp');
      await tmp.writeAsString(sb.toString(), flush: true);
      try {
        await tmp.rename(f.path);
      } catch (_) {
        await tmp.copy(f.path);
        await tmp.delete();
      }
    } catch (e) {
      AppLogger.instance.warn('chat_schedule_audit compact failed: $e');
    }
  }

  Future<void> _writeSummary() async {
    try {
      final Map<String, Object?> summary = <String, Object?>{
        'updatedAt': DateTime.now().toIso8601String(),
        'retentionDays': kRetention.inDays,
        'entryCount': _entries.length,
        'jsonl': jsonlPath,
        'schemaDoc': 'docs/CHAT_SCHEDULE_AUDIT_LOG.md',
        'entries': _entries.reversed.take(50).toList(),
      };
      final Directory dir = Directory(
        CrashJournalService.instance.debugFolderPath,
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(summaryPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(summary),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('chat_schedule_audit summary write failed: $e');
    }
  }
}
