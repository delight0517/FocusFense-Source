import 'dart:convert';
import 'dart:io';

import 'extension_rules_builder.dart';

/// Resolves a YouTube video ID to its channel and checks active block rules.
/// Used by loopback `/youtube/check` — extensions call this on every watch page.
final class YoutubeVideoBlockResolver {
  YoutubeVideoBlockResolver._();
  static final YoutubeVideoBlockResolver instance = YoutubeVideoBlockResolver._();

  static const Duration _kCacheTtl = Duration(hours: 8);
  static const Duration _kFetchTimeout = Duration(seconds: 10);

  final Map<String, _ResolveCacheEntry> _cache = <String, _ResolveCacheEntry>{};

  /// Channel page `/@handle` or `/c/slug` — extensions call on direct navigation.
  Future<YoutubeBlockCheckResult> checkChannel(String rawPathOrUrl) async {
    final RegExpMatch? watchMatch = RegExp(
      r'(?:[?&]v=|youtu\.be/|/shorts/)([\w-]{6,})',
      caseSensitive: false,
    ).firstMatch(rawPathOrUrl);
    if (watchMatch != null) {
      return checkVideo(watchMatch.group(1)!);
    }
    final String? handle = _extractHandleFromPath(rawPathOrUrl);
    if (handle == null || handle.isEmpty) {
      return const YoutubeBlockCheckResult(
        blocked: false,
        videoId: '',
        error: 'invalid_channel_path',
      );
    }

    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    final String? matched = _matchChannelPath(rawPathOrUrl, rules);
    return YoutubeBlockCheckResult(
      blocked: matched != null,
      videoId: '',
      matched: matched,
      rule: matched,
      channelHandle: handle,
    );
  }

  Future<YoutubeBlockCheckResult> checkVideo(String rawVideoId) async {
    final String videoId = _normalizeVideoId(rawVideoId);
    if (videoId.isEmpty) {
      return const YoutubeBlockCheckResult(
        blocked: false,
        videoId: '',
        error: 'invalid_video_id',
      );
    }

    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    final YoutubeVideoResolveResult resolved =
        await resolveVideo(rawVideoId);
    final String? matched = _matchBlockedRule(resolved, rules);
    return YoutubeBlockCheckResult(
      blocked: matched != null,
      videoId: videoId,
      matched: matched,
      rule: matched,
      channelHandle: resolved.channelHandle,
      channelId: resolved.channelId,
      authorName: resolved.authorName,
      authorUrl: resolved.authorUrl,
    );
  }

  Future<YoutubeVideoResolveResult> resolveVideo(String rawVideoId) async {
    final String videoId = _normalizeVideoId(rawVideoId);
    final String fetchId = _preservedVideoId(rawVideoId);
    if (videoId.isEmpty || fetchId.isEmpty) {
      return const YoutubeVideoResolveResult(error: 'invalid_video_id');
    }

    final DateTime now = DateTime.now();
    final _ResolveCacheEntry? cached = _cache[videoId];
    if (cached != null && now.difference(cached.at) < _kCacheTtl) {
      return cached.result;
    }

    YoutubeVideoResolveResult result = await _fetchOEmbed(fetchId);
    if (result.channelHandle == null && result.channelId == null) {
      final YoutubeVideoResolveResult page = await _fetchWatchPage(fetchId);
      result = result.merge(page);
    }
    result = YoutubeVideoResolveResult(
      videoId: videoId,
      authorName: result.authorName,
      authorUrl: result.authorUrl,
      channelHandle: result.channelHandle,
      channelId: result.channelId,
      error: result.error,
    );

    _cache[videoId] = _ResolveCacheEntry(at: now, result: result);
    return result;
  }

  String? _matchChannelPath(String raw, ExtensionRulesPayload rules) {
    final String? handle = _extractHandleFromPath(raw)?.toLowerCase();
    if (handle == null || handle.isEmpty) return null;

    final Set<String> handles = <String>{
      ...rules.blockedYoutubeHandles
          .map((String h) => _safeDecode(h.trim()).toLowerCase()),
    };
    final Set<String> channelIds = <String>{
      ...rules.blockedYoutubeChannelIds.map((String c) => c.toLowerCase()),
    };

    for (final String k in rules.keywords) {
      final RegExpMatch? at = RegExp(
        r'youtube\.com/@([^/?#\s]+)',
        caseSensitive: false,
      ).firstMatch(k);
      if (at != null) {
        handles.add(_safeDecode(at.group(1)!).toLowerCase());
      }
      final RegExpMatch? ch = RegExp(
        r'youtube\.com/channel/([^/?#\s]+)',
        caseSensitive: false,
      ).firstMatch(k);
      if (ch != null) channelIds.add(ch.group(1)!.toLowerCase());
      final String t = k.trim();
      if (t.startsWith('@') && !t.contains('/')) {
        handles.add(_safeDecode(t.substring(1)).toLowerCase());
      }
      final String? slug = _legacySlugFromKeyword(k);
      if (slug != null) handles.add(slug);
    }

    if (handles.contains(handle)) {
      return 'youtube.com/@$handle';
    }

    final String path = _normalizeYoutubePath(raw).toLowerCase();
    final String pathDecoded = _safeDecode(path).toLowerCase();
    for (final String h in handles) {
      if (h.isEmpty) continue;
      if (pathDecoded == '/@$h' ||
          pathDecoded.startsWith('/@$h/') ||
          pathDecoded == '/c/$h' ||
          pathDecoded.startsWith('/c/$h/')) {
        return 'youtube.com/@$h';
      }
      final String enc = Uri.encodeComponent(h).toLowerCase();
      if (path == '/@$enc' ||
          path.startsWith('/@$enc/') ||
          path == '/c/$enc' ||
          path.startsWith('/c/$enc/')) {
        return 'youtube.com/@$h';
      }
    }

    for (final String id in channelIds) {
      if (pathDecoded.contains('/channel/$id')) {
        return 'youtube.com/channel/$id';
      }
    }

    return null;
  }

  String? _extractHandleFromPath(String raw) {
    final String path = _normalizeYoutubePath(raw);
    final String decoded = _safeDecode(path);
    final RegExpMatch? at = RegExp(r'^/@([^/?#]+)').firstMatch(decoded);
    if (at != null) return _safeDecode(at.group(1)!);
    final RegExpMatch? c = RegExp(r'^/c/([^/?#]+)').firstMatch(decoded);
    if (c != null) return _safeDecode(c.group(1)!);
    return null;
  }

  String _normalizeYoutubePath(String raw) {
    String t = raw.trim();
    if (t.isEmpty) return '/';
    if (t.contains('youtube.com') || t.contains('://')) {
      final Uri? uri = Uri.tryParse(t.contains('://') ? t : 'https://$t');
      if (uri != null && uri.path.isNotEmpty) return uri.path;
    }
    if (!t.startsWith('/')) t = '/$t';
    return t.split('?').first.split('#').first;
  }

  String? _matchBlockedRule(
    YoutubeVideoResolveResult resolved,
    ExtensionRulesPayload rules,
  ) {
    final String handle = (resolved.channelHandle ?? '').trim().toLowerCase();
    final String channelId = (resolved.channelId ?? '').trim().toLowerCase();
    final String author = (resolved.authorName ?? '').trim().toLowerCase();
    final String authorUrl = (resolved.authorUrl ?? '').trim().toLowerCase();

    final Set<String> handles = <String>{
      ...rules.blockedYoutubeHandles.map((String h) => _safeDecode(h.trim()).toLowerCase()),
    };
    final Set<String> channelIds = <String>{
      ...rules.blockedYoutubeChannelIds.map((String c) => c.toLowerCase()),
    };
    final Set<String> videoIds = <String>{
      ...rules.blockedYoutubeVideoIds.map((String v) => v.toLowerCase()),
    };

    for (final String k in rules.keywords) {
      final String? slug = _legacySlugFromKeyword(k);
      if (slug != null) handles.add(slug);
      final RegExpMatch? at =
          RegExp(r'youtube\.com/@([^/?#\s]+)', caseSensitive: false)
              .firstMatch(k);
      if (at != null) handles.add(_safeDecode(at.group(1)!).toLowerCase());
    }

    if (videoIds.contains(resolved.videoId.toLowerCase())) {
      return 'youtube.com/watch?v=${resolved.videoId}';
    }

    if (handle.isNotEmpty && handles.contains(handle)) {
      return 'youtube.com/@$handle';
    }
    if (channelId.isNotEmpty && channelIds.contains(channelId)) {
      return 'youtube.com/channel/$channelId';
    }

    if (authorUrl.isNotEmpty) {
      for (final String h in handles) {
        if (h.isEmpty) continue;
        if (_urlReferencesHandle(authorUrl, h)) {
          return 'youtube.com/@$h';
        }
      }
    }

    if (author.isNotEmpty) {
      for (final String h in handles) {
        if (h.isEmpty) continue;
        if (author == h ||
            author.contains(h) ||
            h.contains(author) ||
            _safeDecode(author) == h) {
          return 'youtube.com/@$h';
        }
      }
    }

    for (final String k in rules.keywords) {
      final String kl = k.toLowerCase();
      if (!kl.contains('youtube.com') && !kl.contains('youtu.be')) continue;
      final String? slug = _legacySlugFromKeyword(kl);
      if (slug != null && author.isNotEmpty && author.contains(slug)) {
        return 'youtube.com/$slug';
      }
      if (handle.isNotEmpty && kl.contains(handle)) return k;
      if (channelId.isNotEmpty && kl.contains(channelId)) return k;
    }

    return null;
  }

  static String? _legacySlugFromKeyword(String k) {
    final RegExpMatch? m =
        RegExp(r'youtube\.com/([^/?#\s@]+)', caseSensitive: false).firstMatch(k);
    if (m == null) return null;
    final String slug = _safeDecode(m.group(1)!);
    const Set<String> reserved = <String>{
      'watch',
      'shorts',
      'feed',
      'results',
      'playlist',
      'gaming',
      'premium',
      'account',
      'channel',
      'c',
      'user',
      'post',
      'live',
    };
    if (slug.isEmpty || reserved.contains(slug.toLowerCase())) return null;
    return slug.toLowerCase();
  }

  static String _normalizeVideoId(String raw) {
    final String t = raw.trim();
    if (t.isEmpty) return '';
    final RegExpMatch? m =
        RegExp(r'^[\w-]{6,}$', caseSensitive: false).firstMatch(t);
    return m != null ? m.group(0)!.toLowerCase() : '';
  }

  /// YouTube oEmbed/watch HTML require the **original** video-id casing;
  /// lowercasing (e.g. `oYVEqFdjNDs` → `oyveqfdjnds`) yields HTTP 404.
  static String _preservedVideoId(String raw) {
    final String t = raw.trim();
    if (t.isEmpty) return '';
    final RegExpMatch? m =
        RegExp(r'^[\w-]{6,}$', caseSensitive: false).firstMatch(t);
    return m != null ? m.group(0)! : '';
  }

  static String _safeDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  /// YouTube oEmbed returns percent-encoded @handles in author_url while
  /// rules store decoded Unicode (`뷰티풀너드`). Match both forms.
  static bool _urlReferencesHandle(String url, String handle) {
    final String u = url.toLowerCase();
    final String h = handle.toLowerCase();
    if (h.isEmpty) return false;
    if (u.contains('/@$h') || u.contains('/c/$h') || u.contains('/user/$h')) {
      return true;
    }
    final String enc = _percentEncodeUtf8(h).toLowerCase();
    if (enc != h &&
        (u.contains('/@$enc') ||
            u.contains('/c/$enc') ||
            u.contains('/user/$enc'))) {
      return true;
    }
    return false;
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

  Future<YoutubeVideoResolveResult> _fetchOEmbed(String videoId) async {
    final Uri uri = Uri.parse(
      'https://www.youtube.com/oembed'
      '?url=${Uri.encodeComponent('https://www.youtube.com/watch?v=$videoId')}'
      '&format=json',
    );
    try {
      final HttpClient client = HttpClient();
      client.connectionTimeout = _kFetchTimeout;
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set('User-Agent', '6VPNBlocker/1.0');
      final HttpClientResponse res =
          await req.close().timeout(_kFetchTimeout);
      final String body = await utf8.decoder.bind(res).join();
      client.close(force: true);
      if (res.statusCode != 200) {
        return YoutubeVideoResolveResult(
          videoId: videoId,
          error: 'oembed_http_${res.statusCode}',
        );
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) {
        return YoutubeVideoResolveResult(videoId: videoId, error: 'oembed_json');
      }
      final Map<String, dynamic> m = Map<String, dynamic>.from(decoded);
      final String authorName = '${m['author_name'] ?? ''}'.trim();
      final String authorUrl = '${m['author_url'] ?? ''}'.trim();
      return YoutubeVideoResolveResult(
        videoId: videoId,
        authorName: authorName.isEmpty ? null : authorName,
        authorUrl: authorUrl.isEmpty ? null : authorUrl,
        channelHandle: _handleFromAuthorUrl(authorUrl),
        channelId: _channelIdFromAuthorUrl(authorUrl),
      );
    } catch (e) {
      return YoutubeVideoResolveResult(
        videoId: videoId,
        error: 'oembed_failed:$e',
      );
    }
  }

  Future<YoutubeVideoResolveResult> _fetchWatchPage(String videoId) async {
    final Uri uri =
        Uri.parse('https://www.youtube.com/watch?v=$videoId&hl=en');
    try {
      final HttpClient client = HttpClient();
      client.connectionTimeout = _kFetchTimeout;
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      );
      final HttpClientResponse res =
          await req.close().timeout(_kFetchTimeout);
      final String body = await utf8.decoder.bind(res).join();
      client.close(force: true);
      if (res.statusCode != 200) {
        return YoutubeVideoResolveResult(
          videoId: videoId,
          error: 'watch_http_${res.statusCode}',
        );
      }
      String? channelId;
      String? handle;
      String? author;
      RegExpMatch? m = RegExp(
        r'"channelId"\s*:\s*"(UC[^"]+)"',
        caseSensitive: false,
      ).firstMatch(body);
      channelId = m?.group(1);
      m = RegExp(
        r'"ownerChannelName"\s*:\s*"([^"]+)"',
        caseSensitive: false,
      ).firstMatch(body);
      author = m?.group(1);
      m = RegExp(
        r'"vanityChannelUrl"\s*:\s*"([^"]+)"',
        caseSensitive: false,
      ).firstMatch(body);
      if (m != null) handle = _handleFromAuthorUrl(m.group(1)!);
      m = RegExp(
        r'"channelHandle"\s*:\s*"(@[^"]+)"',
        caseSensitive: false,
      ).firstMatch(body);
      if (m != null) handle ??= m.group(1)!.replaceFirst('@', '');
      return YoutubeVideoResolveResult(
        videoId: videoId,
        authorName: author,
        channelHandle: handle,
        channelId: channelId,
        authorUrl: handle != null ? 'https://www.youtube.com/@$handle' : null,
      );
    } catch (e) {
      return YoutubeVideoResolveResult(
        videoId: videoId,
        error: 'watch_failed:$e',
      );
    }
  }

  static String? _handleFromAuthorUrl(String url) {
    final String u = url.trim();
    if (u.isEmpty) return null;
    RegExpMatch? m = RegExp(r'/@([^/?#\s]+)', caseSensitive: false).firstMatch(u);
    if (m != null) return _safeDecode(m.group(1)!);
    m = RegExp(r'/c/([^/?#\s]+)', caseSensitive: false).firstMatch(u);
    if (m != null) return _safeDecode(m.group(1)!);
    return null;
  }

  static String? _channelIdFromAuthorUrl(String url) {
    final RegExpMatch? m = RegExp(
      r'/channel/(UC[^/?#\s]+)',
      caseSensitive: false,
    ).firstMatch(url);
    return m?.group(1);
  }
}

final class YoutubeVideoResolveResult {
  const YoutubeVideoResolveResult({
    this.videoId = '',
    this.authorName,
    this.authorUrl,
    this.channelHandle,
    this.channelId,
    this.error,
  });

  final String videoId;
  final String? authorName;
  final String? authorUrl;
  final String? channelHandle;
  final String? channelId;
  final String? error;

  YoutubeVideoResolveResult merge(YoutubeVideoResolveResult other) {
    return YoutubeVideoResolveResult(
      videoId: videoId.isNotEmpty ? videoId : other.videoId,
      authorName: authorName ?? other.authorName,
      authorUrl: authorUrl ?? other.authorUrl,
      channelHandle: channelHandle ?? other.channelHandle,
      channelId: channelId ?? other.channelId,
      error: error ?? other.error,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'videoId': videoId,
        if (authorName != null) 'authorName': authorName,
        if (authorUrl != null) 'authorUrl': authorUrl,
        if (channelHandle != null) 'channelHandle': channelHandle,
        if (channelId != null) 'channelId': channelId,
        if (error != null) 'error': error,
      };
}

final class YoutubeBlockCheckResult {
  const YoutubeBlockCheckResult({
    required this.blocked,
    required this.videoId,
    this.matched,
    this.rule,
    this.channelHandle,
    this.channelId,
    this.authorName,
    this.authorUrl,
    this.error,
  });

  final bool blocked;
  final String videoId;
  final String? matched;
  final String? rule;
  final String? channelHandle;
  final String? channelId;
  final String? authorName;
  final String? authorUrl;
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
        'blocked': blocked,
        'videoId': videoId,
        if (matched != null) 'matched': matched,
        if (rule != null) 'rule': rule,
        if (channelHandle != null) 'channelHandle': channelHandle,
        if (channelId != null) 'channelId': channelId,
        if (authorName != null) 'authorName': authorName,
        if (authorUrl != null) 'authorUrl': authorUrl,
        if (error != null) 'error': error,
      };
}

final class _ResolveCacheEntry {
  const _ResolveCacheEntry({required this.at, required this.result});

  final DateTime at;
  final YoutubeVideoResolveResult result;
}
