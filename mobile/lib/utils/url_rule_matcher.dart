/// Cold Turkey–style URL / host pattern matching (shared import + tests).
library;

/// Returns true when [url] matches a Cold Turkey line stored as [pattern].
///
/// Examples:
///   * `chess.com` — host only (no `/` in pattern)
///   * `duolingo.com/chess-matches` — host + path prefix
///   * `*.*/*q=*chess*` — any host, path/query glob
///   * `youtube.*/*search_query=*starcraft2*` — YouTube family + query glob
bool urlMatchesColdTurkeyPattern(String url, String pattern) {
  final String p = pattern.trim().toLowerCase();
  if (p.isEmpty) return false;

  String href = url.trim().toLowerCase();
  if (href.isEmpty) return false;
  if (!href.contains('://')) {
    href = 'https://$href';
  }

  final Uri? uri = Uri.tryParse(href);
  if (uri == null || uri.host.isEmpty) {
    return href.contains(p.replaceAll('*', ''));
  }

  // A terminal DNS root dot does not change the destination host. Browsers
  // preserve it in `hostname`, so normalize it before exact/suffix checks.
  String host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (host.startsWith('www.')) {
    host = host.substring(4);
  }
  final String encodedPathQuery =
      '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
  // `Uri.query` keeps percent escapes, while imported keyword rules contain
  // readable Unicode (for example Korean search terms). Match both forms.
  final String pathQuery = <String>{
    encodedPathQuery.toLowerCase(),
    _decodeUrlComponent(encodedPathQuery).toLowerCase(),
  }.join('\n');

  final int slash = p.indexOf('/');
  final String hostPat = slash >= 0 ? p.substring(0, slash) : p;
  final String pathPat = slash >= 0 ? p.substring(slash) : '';

  final bool hostMatches = hostPat.contains('*')
      ? _hostPatternMatches(host, hostPat)
      : host == hostPat || host.endsWith('.$hostPat');
  if (!hostMatches) return false;
  if (pathPat.isNotEmpty) {
    return _globMatches(pathQuery, pathPat);
  }
  return hostMatches;
}

String _decodeUrlComponent(String value) {
  try {
    return Uri.decodeComponent(value.replaceAll('+', '%20'));
  } on FormatException {
    return value;
  }
}

bool _hostPatternMatches(String host, String pattern) {
  final String pat = pattern.trim().toLowerCase();
  if (pat.isEmpty || pat == '*' || pat == '*.*') return true;

  if (pat.endsWith('.*')) {
    final String stem = pat.substring(0, pat.length - 2);
    if (stem.isEmpty) return true;
    return host == stem || host.endsWith('.$stem') || host.contains(stem);
  }

  final String regex = _coldTurkeyGlobRegex(pat);
  return RegExp('^$regex\$', caseSensitive: false).hasMatch(host);
}

bool _globMatches(String text, String pattern) {
  final String pat = pattern.trim().toLowerCase();
  if (pat.isEmpty) return true;
  final String regex = _coldTurkeyGlobRegex(pat);
  return RegExp(regex, caseSensitive: false).hasMatch(text);
}

/// Cold Turkey exports combine `*` globs with a small regex subset:
/// character classes (`[?&]`), alternatives (`(a|b)`) and quantifiers (`[*]?`).
String _coldTurkeyGlobRegex(String pattern) {
  final StringBuffer regex = StringBuffer();
  for (int i = 0; i < pattern.length; i++) {
    final String char = pattern[i];
    if (char == '*') {
      regex.write('.*');
      continue;
    }
    if (char == '[') {
      final int close = pattern.indexOf(']', i + 1);
      if (close > i + 1) {
        final String contents = pattern.substring(i + 1, close);
        if (RegExp(
          r'^[a-z0-9?&*_-]+$',
          caseSensitive: false,
        ).hasMatch(contents)) {
          regex.write('[');
          regex.write(contents);
          regex.write(']');
          i = close;
          continue;
        }
      }
      regex.write(r'\[');
      continue;
    }
    if (char == ']' && i > 0 && pattern[i - 1] == '[') {
      continue;
    }
    if (char == '(' || char == ')' || char == '|') {
      final int open = char == '(' ? i : pattern.lastIndexOf('(', i - 1);
      final int close = open < 0 ? -1 : pattern.indexOf(')', open + 1);
      final String group = open < 0 || close < 0
          ? ''
          : pattern.substring(open + 1, close);
      final bool isSupportedAlternative =
          group.contains('|') && !group.contains('(') && !group.contains(')');
      final bool isInSupportedAlternative =
          isSupportedAlternative &&
          (i == open || i == close || (char == '|' && i > open && i < close));
      regex.write(isInSupportedAlternative ? char : RegExp.escape(char));
      continue;
    }
    if (char == '?' &&
        i > 0 &&
        (pattern[i - 1] == ']' || pattern[i - 1] == ')')) {
      regex.write('?');
      continue;
    }
    regex.write(RegExp.escape(char));
  }
  return regex.toString();
}
