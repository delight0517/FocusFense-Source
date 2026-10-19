import '../utils/block_url_input.dart';
import 'chromium_policy_service.dart';
import 'extension_rules_builder.dart';

/// Connection-level URL patterns for **PAC dead-proxy** and **Chrome/Edge
/// URLBlocklist** — blocks navigation before the page loads (no extension).
///
/// * **hosts** — domain only (`0.0.0.0`); cannot express `/path` or `?v=`.
/// * **PAC** — `PROXY 127.0.0.1:9` → connection refused (WinINET / Chrome / Edge / Firefox PAC).
/// * **URLBlocklist** — native Chromium block page (“관리자가 차단”).
///
/// YouTube watch/channel patterns are owned by [ChromiumPolicyService]; this
/// builder covers generic keyword URLs (`reddit.com/r/foo`, `watch?v=…` on
/// non-YouTube hosts, bare paths like `/shorts` when paired with host).
final class ConnectionUrlBlockPatternBuilder {
  ConnectionUrlBlockPatternBuilder._();

  static const String _deadProxy = "PROXY 127.0.0.1:9";

  /// HKCU URLBlocklist / Firefox WebsiteFilter patterns from user keywords.
  static List<String> urlBlocklistPatterns(ExtensionRulesPayload rules) {
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    final Set<String> ytVids = ChromiumPolicyService.collectYoutubeVideoIds(rules);

    void add(String pattern) {
      final String p = pattern.trim();
      if (p.isEmpty || !seen.add(p)) return;
      out.add(p);
    }

    final List<String> source = rules.rawKeywords.isNotEmpty
        ? rules.rawKeywords
        : rules.keywords;

    for (final String raw in source) {
      final _ConnectionPattern? cp = _fromKeyword(raw, ytVids: ytVids);
      if (cp == null) continue;
      for (final String pat in cp.urlBlocklistPatterns) {
        add(pat);
      }
    }
    return out;
  }

  /// PAC `FindProxyForURL` body lines (without leading function wrapper).
  static String pacLines(ExtensionRulesPayload rules) {
    final StringBuffer out = StringBuffer();
    final Set<String> emitted = <String>{};
    final Set<String> ytVids = ChromiumPolicyService.collectYoutubeVideoIds(rules);

    void emit(String line) {
      final String key = line.trim();
      if (key.isEmpty || !emitted.add(key)) return;
      out.writeln(line);
    }

    for (final String raw in rules.rawKeywords.isNotEmpty
        ? rules.rawKeywords
        : rules.keywords) {
      final _ConnectionPattern? cp = _fromKeyword(raw, ytVids: ytVids);
      if (cp == null) continue;
      for (final String line in cp.pacLines) {
        emit(line);
      }
    }
    return out.toString();
  }

  static _ConnectionPattern? _fromKeyword(
    String raw, {
    required Set<String> ytVids,
  }) {
    String t = raw.trim();
    if (t.isEmpty || t.startsWith('#')) return null;

    // YouTube handled elsewhere.
    final String tl = t.toLowerCase();
    if (tl.contains('youtube.com') ||
        tl.contains('youtu.be') ||
        tl.startsWith('@') ||
        tl.contains('watch?v=')) {
      return null;
    }

    t = t.replaceFirst(RegExp(r'^https?://'), '');
    if (!t.contains('/') && !t.contains('?')) {
      // Bare host or keyword — domain layer (hosts/PAC host rules) owns it.
      return null;
    }

    final BlockUrlInput parsed = BlockUrlInput.parse(t);
    if (parsed.host.isEmpty || !parsed.hasPathOrQuery) return null;

    final String? vid = BlockUrlInput.extractYoutubeVideoId(parsed.pathQuery);
    if (vid != null && ytVids.contains(vid.toLowerCase())) return null;

    final String host = _pacEscape(parsed.host);
    final String pathQ = parsed.pathQuery;
    if (pathQ.length < 3) return null;

    final String pathLower = pathQ.toLowerCase();
    final String pathEsc = _pacEscape(pathLower);
    final String hostPattern = _urlBlocklistHost(parsed.host);

    final List<String> blocklist = <String>[
      '*://$hostPattern/$pathQ*',
      '*://$hostPattern/*/$pathQ*',
    ];
    if (pathQ.contains('?')) {
      blocklist.add('*://$hostPattern/*${pathQ.split('?').first}*');
    }

    final List<String> pac = <String>[
      "  if ((dnsDomainIs(host, '$host') || shExpMatch(host, '*.$host')) && "
      "(u.indexOf('$pathEsc') >= 0 || shExpMatch(u, '*$pathEsc*'))) "
      "return '$_deadProxy';",
    ];

    return _ConnectionPattern(
      urlBlocklistPatterns: blocklist,
      pacLines: pac,
    );
  }

  static String _urlBlocklistHost(String host) {
    final String h = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    return h;
  }

  static String _pacEscape(String s) =>
      s.replaceAll('\\', r'\\').replaceAll("'", r"\'");
}

final class _ConnectionPattern {
  const _ConnectionPattern({
    required this.urlBlocklistPatterns,
    required this.pacLines,
  });

  final List<String> urlBlocklistPatterns;
  final List<String> pacLines;
}
