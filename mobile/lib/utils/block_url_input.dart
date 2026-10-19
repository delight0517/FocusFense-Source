/// Parsing for "block this URL" inputs. System DNS (`hosts`) can only block
/// **hostnames** — path and query (`/watch?v=…`) are invisible to `hosts`.
final class BlockUrlInput {
  const BlockUrlInput({
    required this.raw,
    required this.host,
    required this.pathQuery,
  });

  final String raw;
  /// Lowercase host, no scheme, no port stripping (kept simple).
  final String host;
  /// Path + query without leading slash, e.g. `watch?v=abc`. Empty if none.
  final String pathQuery;

  bool get hasPathOrQuery => pathQuery.isNotEmpty;

  /// `youtube.com/watch?v=xx` → host `youtube.com`, pathQuery `watch?v=xx`
  static BlockUrlInput parse(String raw) {
    String t = raw.trim();
    if (t.isEmpty) {
      return const BlockUrlInput(raw: '', host: '', pathQuery: '');
    }
    t = t.replaceFirst(RegExp(r'^https?://'), '');
    final int slash = t.indexOf('/');
    if (slash < 0) {
      return BlockUrlInput(raw: raw, host: t.toLowerCase(), pathQuery: '');
    }
    return BlockUrlInput(
      raw: raw,
      host: t.substring(0, slash).toLowerCase(),
      pathQuery: t.substring(slash + 1).trim(),
    );
  }

  /// Best-effort YouTube `v=` id for keyword hints (11 chars typical).
  static String? extractYoutubeVideoId(String pathQuery) {
    final RegExp re = RegExp(r'(?:^|[?&])v=([a-zA-Z0-9_-]{6,})');
    final RegExpMatch? m = re.firstMatch(pathQuery);
    return m?.group(1);
  }

  /// Short pattern for keyword row: prefer `watch?v=ID`, else first segment.
  static String suggestKeywordPattern(BlockUrlInput in_) {
    final String? vid = extractYoutubeVideoId(in_.pathQuery);
    if (vid != null) {
      return 'watch?v=$vid';
    }
    if (in_.pathQuery.length > 120) {
      return in_.pathQuery.substring(0, 120);
    }
    return in_.pathQuery;
  }
}
