import 'cold_turkey_rule_parser.dart';

/// Parses lines like `youtube.com/handle` or `youtube.com/watch?v=…` into
/// keyword patterns for the browser extension (feed + SERP + navigation).
class YouTubeBlocklistBatch {
  YouTubeBlocklistBatch({List<ColdTurkeyParsedRule>? rules})
      : rules = rules ?? <ColdTurkeyParsedRule>[];

  final List<ColdTurkeyParsedRule> rules;

  int get channelRules =>
      rules.where((r) => r.raw.contains('youtube.com')).length;
}

YouTubeBlocklistBatch parseYouTubeBlocklistLines(Iterable<String> lines) {
  final Set<String> seen = <String>{};
  final List<ColdTurkeyParsedRule> out = <ColdTurkeyParsedRule>[];

  void addKeyword(String raw, String pattern) {
    final String p = pattern.trim().toLowerCase();
    if (p.isEmpty || !seen.add(p)) return;
    out.add(
      ColdTurkeyParsedRule(
        raw: raw,
        kind: ColdTurkeyRuleKind.path,
        keywordPattern: p,
      ),
    );
  }

  for (final String line in lines) {
    final String raw = line.trim();
    if (raw.isEmpty || raw.startsWith('#')) continue;

    final List<String> patterns = _expandYouTubeLine(raw);
    for (final String p in patterns) {
      addKeyword(raw, p);
    }
  }
  return YouTubeBlocklistBatch(rules: out);
}

List<String> _expandYouTubeLine(String line) {
  String t = _safeDecode(line.trim());
  if (t.isEmpty) return const <String>[];

  t = t.replaceFirst(RegExp(r'^https?://'), '');
  t = t.replaceFirst(RegExp(r'^www\.'), '');
  if (!t.toLowerCase().startsWith('youtube.com') &&
      !t.toLowerCase().startsWith('youtu.be')) {
    if (t.contains('youtube.com')) {
      final int i = t.toLowerCase().indexOf('youtube.com');
      t = t.substring(i);
    } else {
      return const <String>[];
    }
  }

  final String lower = t.toLowerCase();
  final List<String> out = <String>[];

  if (lower.contains('watch?v=') || lower.contains('youtu.be/')) {
    out.add(lower.split('?').first.contains('youtu.be')
        ? lower
        : lower.replaceFirst('youtu.be/', 'youtube.com/watch?v='));
    final Uri? u = Uri.tryParse('https://$lower');
    final String? v = u?.queryParameters['v'];
    if (v != null && v.isNotEmpty) {
      out.add('youtube.com/watch?v=${v.toLowerCase()}');
      out.add('watch?v=${v.toLowerCase()}');
    }
    return out;
  }

  String path = '';
  final int slash = lower.indexOf('/');
  if (slash >= 0) {
    path = lower.substring(slash);
  }

  if (path.startsWith('/channel/') ||
      path.startsWith('/user/') ||
      path.startsWith('/c/')) {
    out.add('youtube.com$path');
    return out;
  }

  String handle = path.replaceFirst('/', '');
  if (handle.startsWith('@')) {
    handle = handle.substring(1);
  }
  if (handle.isEmpty) return const <String>[];

  final String decodedHandle = _safeDecode(handle);
  final String encodedHandle = Uri.encodeComponent(decodedHandle);
  out.add('youtube.com/$decodedHandle');
  out.add('youtube.com/@$decodedHandle');
  out.add('youtube.com/c/$decodedHandle');
  out.add('@$decodedHandle');
  out.add('/@$decodedHandle');
  if (encodedHandle != decodedHandle) {
    out.add('youtube.com/$encodedHandle');
    out.add('youtube.com/@$encodedHandle');
    out.add('@$encodedHandle');
  }
  out.add('/$decodedHandle');
  return out;
}

String _safeDecode(String s) {
  if (s.isEmpty || !s.contains('%')) return s;
  try {
    return Uri.decodeFull(s);
  } catch (_) {
    return s;
  }
}
