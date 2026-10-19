import 'builtin_block_domains.dart';
import '../data/builtin_adult_apex_domains.dart';
import 'mac_system_block_service.dart';

/// Host helpers for explicitly selected YouTube rules.
final class YoutubeEnforcementHosts {
  YoutubeEnforcementHosts._();

  /// Built-in domains for Windows hosts (DNS sinkhole).
  ///
  /// Adult defaults only. YouTube apex (`youtube.com`, `youtu.be`) stays
  /// DNS-reachable — per-video/channel blocks use PAC + URLBlocklist + extension.
  /// Shared media CDN hosts are excluded because blocking them disables every
  /// YouTube video, regardless of the user's selected channel/video rules.
  static List<String> expandedBuiltinDomainsForWindowsHosts({
    bool includeAdult = false,
    Iterable<String> adultDomains = kBuiltinAdultApexDomains,
  }) {
    final Set<String> out = <String>{};
    final Iterable<String> builtins = <String>[
      ...kExtensionBuiltinBlockedDomains,
      if (includeAdult) ...adultDomains,
    ];
    for (final String raw in builtins) {
      if (raw == kDiagnosticBlockSentinelHost) continue;
      final String c = MacSystemBlockService.canonicalHost(raw);
      if (c.isEmpty || isYoutubeSiteApex(c)) continue;
      out.addAll(MacSystemBlockService.expandCompactForHosts(c));
    }
    return out.toList()..sort();
  }

  /// True for apex / www / m / music — **not** CDN edges (googlevideo, ytimg).
  static bool isYoutubeSiteApex(String host) {
    final String c = MacSystemBlockService.canonicalHost(host);
    if (c == 'youtube.com' || c == 'youtu.be') return true;
    if (!c.endsWith('.youtube.com')) return false;
    final String sub = c.substring(0, c.length - '.youtube.com'.length);
    return sub.isEmpty ||
        sub == 'www' ||
        sub == 'm' ||
        sub == 'music' ||
        sub == 'mobile';
  }

  /// Removes site-wide YouTube DNS sinkhole lines from a hosts host set.
  static void removeYoutubeSiteApex(Set<String> hosts) {
    hosts.removeWhere(isYoutubeSiteApex);
  }
}
