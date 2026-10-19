import 'youtube_enforcement_hosts.dart';

/// Keeps user-selected YouTube URL rules scoped to their selected channel or
/// video across Firefox and Chromium.
final class BrowserYoutubePolicySplit {
  BrowserYoutubePolicySplit._();

  static const List<String> kYoutubeApexBlockPatterns = <String>[
    'youtube.com',
    'youtu.be',
  ];

  /// True for site-wide YouTube URLBlocklist rows (not per-channel / per-video).
  static bool isYoutubeApexBlockPattern(String pattern) {
    final String p = pattern.trim().toLowerCase();
    if (p.isEmpty) return false;
    if (p == 'youtube.com' ||
        p == 'youtu.be' ||
        p == '*://youtube.com/*' ||
        p == '*://*.youtube.com/*' ||
        p == '*://youtu.be/*') {
      return true;
    }
    final RegExpMatch? m = RegExp(
      r'^\*://(?:\*\.)?([^/*]+)/\*$',
      caseSensitive: false,
    ).firstMatch(p);
    if (m == null) {
      return YoutubeEnforcementHosts.isYoutubeSiteApex(p);
    }
    final String host = m.group(1)!.toLowerCase();
    return YoutubeEnforcementHosts.isYoutubeSiteApex(host);
  }

  static List<String> withoutYoutubeApex(Iterable<String> patterns) {
    return patterns
        .where((String p) => !isYoutubeApexBlockPattern(p))
        .toList(growable: false);
  }

  /// Keeps explicit patterns without inventing a site-wide YouTube block.
  /// A previous fallback added youtube.com/youtu.be whenever extension
  /// readiness was false, making a single channel/video rule block all YouTube.
  static List<String> withYoutubeApexEnsured(List<String> patterns) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    void add(String raw) {
      final String p = raw.trim();
      if (p.isEmpty || !seen.add(p)) return;
      out.add(p);
    }

    for (final String p in patterns) {
      add(p);
    }
    return out.length > 1000 ? out.sublist(0, 1000) : out;
  }

  static List<String> withoutYoutubeApexDomains(List<String> domains) {
    return domains
        .where((String d) => !YoutubeEnforcementHosts.isYoutubeSiteApex(d))
        .toList(growable: false);
  }
}
