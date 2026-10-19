import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';

/// Structured fix / apply audit log for **Cursor agents** — no copy-paste needed.
///
/// Files (Windows):
/// * `%USERPROFILE%\Documents\SixVPN_Blocker_Debug\cursor_agent_fix_log.jsonl`
/// * `%USERPROFILE%\Documents\SixVPN_Blocker_Debug\cursor_agent_fix_last.json`
///
/// Read: `mobile\tools\Read-CursorAgentFixLog.ps1`
final class CursorAgentFixLogService {
  CursorAgentFixLogService._();
  static final CursorAgentFixLogService instance = CursorAgentFixLogService._();

  static const int _kMaxJsonlBytes = 512 * 1024;

  String get jsonlPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'cursor_agent_fix_log.jsonl',
      );

  String get lastPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'cursor_agent_fix_last.json',
      );

  /// Append one fix cycle and refresh [lastPath].
  Future<void> record(CursorAgentFixEntry entry) async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    try {
      await CrashJournalService.instance.warmup();
      final Directory dir = Directory(p.dirname(jsonlPath));
      if (!await dir.exists()) await dir.create(recursive: true);

      final String build = await BuildIdentityService.instance.summaryLine();
      final Map<String, Object?> row = entry.toJson(build: build);
      final String line = '${jsonEncode(row)}\n';

      final File jf = File(jsonlPath);
      if (await jf.exists()) {
        final int len = await jf.length();
        if (len + line.length > _kMaxJsonlBytes) {
          await _rotateJsonl(jf);
        }
      }
      await jf.writeAsString(line, mode: FileMode.append, flush: true);

      await File(lastPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'updatedAt': DateTime.now().toIso8601String(),
          'cursorReadme': 'mobile/tools/Read-CursorAgentFixLog.ps1',
          'jsonl': jsonlPath,
          'latest': row,
          'openFailures': entry.failedLayers,
          'appliedLayers': entry.appliedLayers,
        }),
        flush: true,
      );

      AppLogger.instance.info(
        'cursor_agent_fix: ${entry.component}.${entry.action} ok=${entry.ok} '
        '${entry.verdict}',
      );
    } catch (e, st) {
      AppLogger.instance.warn('cursor_agent_fix write failed: $e');
    }
  }

  Future<void> _rotateJsonl(File f) async {
    try {
      final String raw = await f.readAsString();
      final List<String> lines = raw.split('\n').where((String s) => s.trim().isNotEmpty).toList();
      final int keep = lines.length ~/ 2;
      await f.writeAsString('${lines.skip(keep).join('\n')}\n', flush: true);
    } catch (_) {
      await f.writeAsString('', flush: true);
    }
  }

  Map<String, Object?>? readLastSync() {
    try {
      final File f = File(lastPath);
      if (!f.existsSync()) return null;
      final Object? j = jsonDecode(f.readAsStringSync());
      if (j is Map) return Map<String, Object?>.from(j);
    } catch (_) {}
    return null;
  }
}

final class CursorAgentFixEntry {
  const CursorAgentFixEntry({
    required this.component,
    required this.action,
    required this.ok,
    required this.verdict,
    this.reason = 'manual',
    this.details = const <String, Object?>{},
    this.failedLayers = const <String>[],
    this.appliedLayers = const <String>[],
    this.fixesAttempted = const <String>[],
  });

  final String component;
  final String action;
  final bool ok;
  final String verdict;
  final String reason;
  final Map<String, Object?> details;
  final List<String> failedLayers;
  final List<String> appliedLayers;
  final List<String> fixesAttempted;

  Map<String, Object?> toJson({required String build}) => <String, Object?>{
        'ts': DateTime.now().toIso8601String(),
        'build': build,
        'component': component,
        'action': action,
        'ok': ok,
        'verdict': verdict,
        'reason': reason,
        'details': details,
        'failedLayers': failedLayers,
        'appliedLayers': appliedLayers,
        'fixesAttempted': fixesAttempted,
      };
}
