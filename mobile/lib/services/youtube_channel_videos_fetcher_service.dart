import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';
import 'local_database.dart';

/// "User added a channel handle — they actually want ALL videos from that
/// channel blocked." Without this, URLBlocklist alone only catches the
/// channel landing page; individual `/watch?v=…` URLs for the channel's
/// videos sail through because the URL pattern matcher has no channel ↔
/// video knowledge.
///
/// This service does what the user expects automatically: given a handle
/// (e.g. `AGU_TV`), fetch the channel's recent videos from YouTube,
/// extract their `videoId` values, and insert them as keyword rows in the
/// same schedule as the channel. The next `BlockSyncService.requestApply`
/// then translates them into URLBlocklist `watch?v=…` patterns and the
/// videos block at the URL bar.
///
/// Strategy:
///   1. Hit `https://www.youtube.com/@<handle>/videos` (the user-visible
///      channel videos page). YouTube returns server-rendered HTML that
///      contains `"videoId":"<11-char-id>"` for every visible video.
///   2. Parse the videoIds with a regex (no JS execution needed).
///   3. Dedupe + insert into the keywords table under the same schedule.
///   4. Caller triggers an apply so URLBlocklist picks them up.
///
/// Limits:
///   * YouTube paginates — initial HTML only carries ~30 videos. Good
///     enough for the user's "block this channel" intent; the watchdog
///     re-fetches on each sync run so new uploads land within a few
///     minutes.
///   * Uses Dart's `HttpClient`. No API key required.
///   * Best-effort: if the channel page changes structure, we log and
///     return zero (no crash). The user can still add individual videos
///     manually.
final class YoutubeChannelVideosFetcherService {
  YoutubeChannelVideosFetcherService._();
  static final YoutubeChannelVideosFetcherService instance =
      YoutubeChannelVideosFetcherService._();

  static const Duration _kTimeout = Duration(seconds: 8);
  static const Duration _kYoutubeProbeTtl = Duration(minutes: 15);
  static const Duration _kPerHandleGap = Duration(milliseconds: 80);
  static const int _kMaxHandlesPerRun = 6;
  // Cap per call so we don't insert hundreds of keywords from one channel —
  // the URLBlocklist cap is 1000 and we want headroom for other channels.
  // 25 most recent videos covers the user's "I don't want to see this
  // channel's stuff" intent without filling the policy.
  static const int _kMaxVideosPerChannel = 25;

  bool? _youtubeReachable;
  DateTime? _youtubeProbeAt;

  /// When hosts/PAC block youtube.com, skip HTTP fetches (they only spam
  /// DNS errors and stall the UI thread waiting on timeouts).
  Future<bool> _youtubeNetworkAvailable() async {
    final DateTime now = DateTime.now();
    if (_youtubeProbeAt != null &&
        now.difference(_youtubeProbeAt!) < _kYoutubeProbeTtl) {
      return _youtubeReachable ?? false;
    }
    _youtubeProbeAt = now;
    try {
      final List<InternetAddress> addrs = await InternetAddress.lookup(
        'www.youtube.com',
      ).timeout(const Duration(seconds: 2));
      _youtubeReachable =
          addrs.isNotEmpty && addrs.first.rawAddress.isNotEmpty;
    } catch (_) {
      _youtubeReachable = false;
    }
    if (_youtubeReachable != true) {
      AppLogger.instance.info(
        'yt_fetch: skip — youtube.com unreachable (blocked by hosts/PAC)',
      );
    }
    return _youtubeReachable ?? false;
  }

  /// Fetch + extract videoIds from `youtube.com/@<handle>/videos`.
  /// Returns the deduped list (newest first as YouTube serves them).
  /// Empty list = fetch failed or channel has no videos.
  Future<List<String>> fetchVideoIdsForHandle(String handle) async {
    if (!await _youtubeNetworkAvailable()) return <String>[];
    final String clean = _normalizeHandle(handle);
    if (clean.isEmpty) return <String>[];

    // YouTube serves Korean/Unicode handles as percent-encoded paths in the
    // real URL (`/@%EB%B7%B0…`) while the app stores decoded `뷰티풀너드`.
    // Try decoded first, then UTF-8 percent-encoded.
    final List<String> pathForms = <String>[clean];
    final String enc = _percentEncodeUtf8(clean);
    if (enc != clean) pathForms.add(enc);

    for (final String pathHandle in pathForms) {
      final List<String> ids = await _fetchVideoIdsFromChannelUrl(
        'https://www.youtube.com/@$pathHandle/videos',
        handleLabel: clean,
      );
      if (ids.isNotEmpty) return ids;
    }
    return <String>[];
  }

  Future<List<String>> _fetchVideoIdsFromChannelUrl(
    String pageUrl, {
    required String handleLabel,
  }) async {
    try {
      final HttpClient client = HttpClient()
        ..connectionTimeout = _kTimeout
        ..idleTimeout = _kTimeout;
      try {
        final HttpClientRequest req = await client.getUrl(Uri.parse(pageUrl));
        req.headers.set(
          'User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        );
        req.headers.set('Accept-Language', 'en-US,en;q=0.9');
        final HttpClientResponse resp =
            await req.close().timeout(_kTimeout);
        if (resp.statusCode != 200) {
          AppLogger.instance.warn(
            'yt_fetch: handle=$handleLabel status=${resp.statusCode} url=$pageUrl',
          );
          return <String>[];
        }
        final String body = await resp.transform(utf8.decoder).join();
        return _extractVideoIds(body);
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      AppLogger.instance.warn('yt_fetch: handle=$handleLabel failed: $e');
      return <String>[];
    }
  }

  static String _normalizeHandle(String raw) {
    return _safeDecode(raw.replaceAll(RegExp(r'^@'), '').trim());
  }

  static String _safeDecode(String s) {
    if (s.isEmpty || !s.contains('%')) return s;
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }

  static String _percentEncodeUtf8(String value) {
    if (value.isEmpty) return value;
    final List<int> bytes = utf8.encode(value);
    final StringBuffer sb = StringBuffer();
    for (final int b in bytes) {
      if (b < 0x80) {
        sb.writeCharCode(b);
      } else {
        sb.write('%');
        sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
    }
    return sb.toString();
  }

  /// After the user adds channel keywords, fetch recent videos and insert
  /// `watch?v=` rows so URLBlocklist/DNR can block watch pages directly.
  Future<int> syncFromKeywordPatterns(
    Iterable<String> patterns, {
    String? scheduleId,
  }) async {
    final Set<String> handles = <String>{};
    for (final String raw in patterns) {
      final String? h = _handleFromPattern(raw);
      if (h != null && h.isNotEmpty) handles.add(h);
    }
    int total = 0;
    for (final String handle in handles) {
      total += await _insertVideosForHandle(handle, scheduleId: scheduleId);
    }
    return total;
  }

  static String? _handleFromPattern(String pattern) {
    final String p = pattern.trim().toLowerCase();
    RegExpMatch? m = RegExp(r'youtube\.com/@([^/?#\s]+)').firstMatch(p);
    m ??= RegExp(r'youtube\.com/c/([^/?#\s]+)').firstMatch(p);
    if (m != null) return _normalizeHandle(m.group(1)!);
    if (p.startsWith('@') && !p.contains('/')) {
      return _normalizeHandle(p.substring(1));
    }
    if (p.startsWith('/@')) return _normalizeHandle(p.substring(2));
    return null;
  }

  Future<int> _insertVideosForHandle(
    String handle, {
    String? scheduleId,
  }) async {
    final List<String> videoIds = await fetchVideoIdsForHandle(handle);
    int added = 0;
    for (final String vid in videoIds) {
      try {
        await LocalDatabase.instance.insertKeyword(
          id: 'yt_autofetch_${handle}_$vid',
          pattern: 'https://www.youtube.com/watch?v=$vid',
          scheduleId: scheduleId,
        );
        added++;
      } catch (err) {
        AppLogger.instance.warn(
          'yt_fetch insert failed for $handle/$vid: $err',
        );
      }
    }
    AppLogger.instance.info(
      'yt_fetch: handle=$handle fetched=${videoIds.length} inserted=$added',
    );
    return added;
  }

  /// Pulls out `videoId` values from a YouTube channel-page HTML. The page
  /// embeds them as `"videoId":"<11 chars>"` inside a giant ytInitialData
  /// JSON blob. We dedupe and cap.
  static List<String> _extractVideoIds(String html) {
    final RegExp re = RegExp(r'"videoId":"([A-Za-z0-9_-]{11})"');
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    for (final RegExpMatch m in re.allMatches(html)) {
      final String id = m.group(1)!;
      if (seen.add(id)) {
        out.add(id);
        if (out.length >= _kMaxVideosPerChannel) break;
      }
    }
    return out;
  }

  /// For every YouTube handle keyword in the same schedule, fetch the
  /// channel's videos and insert each as a new keyword row. Idempotent:
  /// existing keyword with the same video ID is skipped (the insertKeyword
  /// API uses conflictAlgorithm.replace anyway).
  ///
  /// Returns a per-handle count of newly-inserted videos.
  Future<Map<String, int>> syncAllBlockedChannels({
    void Function(String handle, int count)? onProgress,
  }) async {
    if (!await _youtubeNetworkAvailable()) return <String, int>{};

    final List<Map<String, Object?>> kws =
        await LocalDatabase.instance.keywordsAllEnabled();
    final Map<String, String?> handleToSchedule = <String, String?>{};
    for (final Map<String, Object?> kw in kws) {
      final String pattern = (kw['pattern'] as String? ?? '').toLowerCase();
      RegExpMatch? m =
          RegExp(r'youtube\.com/@([^/?#\s]+)').firstMatch(pattern);
      m ??= RegExp(r'youtube\.com/c/([^/?#\s]+)').firstMatch(pattern);
      String? handle;
      if (m != null) {
        handle = _normalizeHandle(m.group(1)!);
      } else if (pattern.startsWith('@') && !pattern.contains('/')) {
        handle = _normalizeHandle(pattern.substring(1));
      }
      if (handle == null || handle.isEmpty) continue;
      final String? sched = kw['schedule_id'] as String?;
      // Prefer the schedule that already owns this handle (first one wins).
      handleToSchedule.putIfAbsent(handle, () => sched);
    }
    final Map<String, int> result = <String, int>{};
    int processed = 0;
    for (final MapEntry<String, String?> e in handleToSchedule.entries) {
      if (processed >= _kMaxHandlesPerRun) break;
      processed++;
      final String handle = e.key;
      final String? scheduleId = e.value;
      if (processed > 1) {
        await Future<void>.delayed(_kPerHandleGap);
      }
      final List<String> videoIds = await fetchVideoIdsForHandle(handle);
      int added = 0;
      for (final String vid in videoIds) {
        try {
          await LocalDatabase.instance.insertKeyword(
            id: 'yt_autofetch_${handle}_$vid',
            pattern: 'https://www.youtube.com/watch?v=$vid',
            scheduleId: scheduleId,
          );
          added++;
        } catch (err) {
          AppLogger.instance.warn(
            'yt_fetch insert failed for $handle/$vid: $err',
          );
        }
      }
      result[handle] = added;
      onProgress?.call(handle, added);
      AppLogger.instance.info(
        'yt_fetch: handle=$handle fetched=${videoIds.length} inserted=$added',
      );
    }
    return result;
  }
}

