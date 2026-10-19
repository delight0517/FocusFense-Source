import 'dart:async';

import '../utils/cold_turkey_rule_parser.dart';
import '../utils/youtube_blocklist_parser.dart';
import 'app_logger.dart';
import 'block_sync_service.dart';
import 'local_database.dart';
import 'youtube_channel_videos_fetcher_service.dart';

/// Adds YouTube channel / video URLs into a schedule as **keyword** rows
/// (browser extension — not hosts/DNS).
final class YouTubeScheduleBlockService {
  YouTubeScheduleBlockService._();
  static final YouTubeScheduleBlockService instance =
      YouTubeScheduleBlockService._();

  static bool looksLikeYouTubeInput(String raw) {
    final String t = raw.trim().toLowerCase();
    return t.contains('youtube.com') ||
        t.contains('youtu.be') ||
        t.startsWith('@');
  }

  /// Normalizes bare handles: `@SC2HL` → `youtube.com/@SC2HL`
  static String normalizeInputLine(String raw) {
    String t = _safeDecode(raw.trim());
    if (t.isEmpty) return t;
    if (t.startsWith('@')) {
      return 'youtube.com$t';
    }
    if (!t.contains('youtube.com') && !t.contains('youtu.be')) {
      return 'youtube.com/$t';
    }
    return t;
  }

  static String _safeDecode(String s) {
    if (s.isEmpty || !s.contains('%')) return s;
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }

  Future<YouTubeScheduleAddResult> addToSchedule({
    required String scheduleId,
    required String urlOrHandle,
  }) async {
    final String line = normalizeInputLine(urlOrHandle);
    if (line.isEmpty) {
      return const YouTubeScheduleAddResult(
        added: 0,
        skipped: 0,
        patterns: <String>[],
        error: 'URL 또는 @채널명을 입력하세요.',
      );
    }

    final YouTubeBlocklistBatch batch = parseYouTubeBlocklistLines(<String>[line]);
    if (batch.rules.isEmpty) {
      return YouTubeScheduleAddResult(
        added: 0,
        skipped: 0,
        patterns: const <String>[],
        error: '인식할 수 없는 YouTube 주소입니다. 예: youtube.com/@SC2HL',
      );
    }

    final Set<String> existing = <String>{
      for (final Map<String, Object?> row
          in await LocalDatabase.instance.keywordsForSchedule(scheduleId))
        (row['pattern'] as String? ?? '').trim().toLowerCase(),
    };

    int added = 0;
    int skipped = 0;
    final List<String> inserted = <String>[];

    for (final ColdTurkeyParsedRule rule in batch.rules) {
      final String? pat = rule.keywordPattern?.trim().toLowerCase();
      if (pat == null || pat.isEmpty) continue;
      if (existing.contains(pat)) {
        skipped++;
        continue;
      }
      final String id =
          'yt_${DateTime.now().microsecondsSinceEpoch}_${added}_${pat.hashCode}';
      await LocalDatabase.instance.insertKeyword(
        id: id,
        pattern: pat,
        scheduleId: scheduleId,
      );
      existing.add(pat);
      inserted.add(pat);
      added++;
    }

    AppLogger.instance.info(
      'YouTube schedule add: schedule=$scheduleId added=$added skipped=$skipped',
    );

    if (added > 0 && _looksLikeChannelAdd(inserted)) {
      unawaited(
        _autoSyncChannelVideos(
          patterns: inserted,
          scheduleId: scheduleId,
        ),
      );
    }

    return YouTubeScheduleAddResult(
      added: added,
      skipped: skipped,
      patterns: inserted,
      sourceLine: line,
    );
  }

  static bool _looksLikeChannelAdd(List<String> patterns) {
    for (final String p in patterns) {
      final String t = p.toLowerCase();
      if (t.contains('youtube.com/@') ||
          t.contains('youtube.com/c/') ||
          t.startsWith('@') ||
          t.startsWith('/@')) {
        return true;
      }
    }
    return false;
  }

  static Future<void> _autoSyncChannelVideos({
    required List<String> patterns,
    required String scheduleId,
  }) async {
    try {
      final int inserted = await YoutubeChannelVideosFetcherService.instance
          .syncFromKeywordPatterns(patterns, scheduleId: scheduleId);
      if (inserted > 0) {
        AppLogger.instance.info(
          'YouTube channel auto-sync: inserted $inserted watch?v= rows',
        );
        BlockSyncService.instance.requestApply();
      }
    } catch (e) {
      AppLogger.instance.warn('YouTube channel auto-sync failed: $e');
    }
  }
}

final class YouTubeScheduleAddResult {
  const YouTubeScheduleAddResult({
    required this.added,
    required this.skipped,
    required this.patterns,
    this.error,
    this.sourceLine,
  });

  final int added;
  final int skipped;
  final List<String> patterns;
  final String? error;
  final String? sourceLine;

  bool get ok => error == null && added > 0;
}
