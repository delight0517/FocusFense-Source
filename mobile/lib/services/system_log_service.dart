import 'dart:io';

import 'app_logger.dart';

/// Reads the macOS unified log (`log show`) filtered by predicates relevant
/// to DNS / Firefox / Chrome so the user can paste *real OS-level* evidence
/// of what's happening, not just our app's output. Costs a couple of
/// seconds — call sparingly, not on every screen rebuild.
final class SystemLogService {
  SystemLogService._();
  static final SystemLogService instance = SystemLogService._();

  /// Returns the last [minutes] of relevant log entries, joined as one big
  /// string. Capped at [maxLines] so it stays paste-friendly.
  Future<String> fetch({
    int minutes = 5,
    int maxLines = 400,
    String? extraPredicate,
  }) async {
    if (!Platform.isMacOS) return '(macOS 전용)';

    // Default predicate: anything DNS-related, anything from Firefox/Chrome,
    // anything mentioning known canary hosts. Quoted carefully because the
    // `log show` predicate is NSPredicate syntax.
    final String basePredicate = <String>[
      'subsystem == "com.apple.network"',
      'subsystem == "com.apple.mDNSResponder"',
      'process == "firefox"',
      'process == "Firefox"',
      'process == "Google Chrome"',
      'process == "mDNSResponder"',
      'eventMessage CONTAINS[c] "naver.com"',
      'eventMessage CONTAINS[c] "pornhub"',
      'eventMessage CONTAINS[c] "0.0.0.0"',
    ].join(' OR ');

    final String predicate =
        extraPredicate == null ? basePredicate : '($basePredicate) OR ($extraPredicate)';

    AppLogger.instance.info(
      'SystemLogService.fetch minutes=$minutes maxLines=$maxLines',
    );

    try {
      final ProcessResult r = await Process.run(
        'log',
        <String>[
          'show',
          '--style', 'compact',
          '--last', '${minutes}m',
          '--predicate', predicate,
          '--info',
        ],
      ).timeout(const Duration(seconds: 25));

      final String stderr = (r.stderr as String? ?? '').trim();
      if (stderr.isNotEmpty) {
        AppLogger.instance.info('log show stderr: $stderr');
      }
      final String out = (r.stdout as String? ?? '');
      if (out.trim().isEmpty) {
        return '(매칭되는 시스템 로그 없음 — 최근 $minutes분 동안 DNS/브라우저 이벤트가 없었어요)';
      }
      final List<String> lines = out.split('\n');
      if (lines.length <= maxLines) return out;
      final List<String> tail = lines.sublist(lines.length - maxLines);
      return '(앞쪽 ${lines.length - maxLines}줄 생략)\n${tail.join('\n')}';
    } catch (e) {
      AppLogger.instance.warn('system log fetch failed', error: e);
      return '(시스템 로그 읽기 실패: $e)';
    }
  }
}
