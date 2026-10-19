import 'app_logger.dart';
import 'chromium_policy_service.dart';
import 'extension_rules_builder.dart';
import 'local_database.dart';
import 'youtube_video_block_resolver.dart';

/// When the resolver/API says a video is blocked (channel rule) but the
/// videoId is missing from URLBlocklist/PAC, insert a `watch?v=` keyword so
/// the next policy sync blocks without the loopback API (app-kill safe).
final class YoutubePolicyLayerGapHealer {
  YoutubePolicyLayerGapHealer._();
  static final YoutubePolicyLayerGapHealer instance =
      YoutubePolicyLayerGapHealer._();

  /// Mandatory probes — resolver-blocked videos that must appear in HKCU/PAC.
  // @incident: project_youtube_block_pipeline — regression canaries for the
  // case-sensitivity bug (videoId must be lowercased before matching
  // URLBlocklist); do not remove these probes.
  static const List<String> kMandatoryPolicyVideoIds = <String>[
    '9zz_j97kDIY', // @뷰티풀너드 — user agent test 2026-06-10
    'oYVEqFdjNDs', // @뷰티풀너드 — prior gap report
  ];

  /// Returns count of newly inserted keyword rows.
  Future<int> healFromRules(ExtensionRulesPayload rules) async {
    final Set<String> inPolicy = ChromiumPolicyService.collectYoutubeVideoIds(
      rules,
    ).map((String v) => v.toLowerCase()).toSet();

    final Set<String> probeIds = <String>{
      ...kMandatoryPolicyVideoIds,
      ...rules.blockedYoutubeVideoIds.map((String v) => v.toLowerCase()),
    };
    for (final String k in rules.keywords) {
      final RegExpMatch? m = RegExp(
        r'[?&]v=([\w-]{6,})',
        caseSensitive: false,
      ).firstMatch(k);
      if (m != null) probeIds.add(m.group(1)!.toLowerCase());
    }

    int inserted = 0;
    for (final String rawVid in probeIds) {
      final String vidLower = rawVid.trim().toLowerCase();
      if (vidLower.isEmpty || inPolicy.contains(vidLower)) continue;

      final YoutubeBlockCheckResult check =
          await YoutubeVideoBlockResolver.instance.checkVideo(rawVid);
      if (!check.blocked) continue;

      final String preserved = _preservedVideoId(rawVid);
      if (preserved.isEmpty) continue;

      try {
        await LocalDatabase.instance.insertKeyword(
          id: 'yt_policy_gap_$vidLower',
          pattern: 'https://www.youtube.com/watch?v=$preserved',
        );
        inserted++;
        inPolicy.add(vidLower);
        AppLogger.instance.info(
          'yt_policy_gap_heal: inserted watch?v=$preserved (${check.matched})',
        );
      } catch (e) {
        AppLogger.instance.warn(
          'yt_policy_gap_heal: insert failed $preserved: $e',
        );
      }
    }
    return inserted;
  }

  static String _preservedVideoId(String raw) {
    final String t = raw.trim();
    if (t.isEmpty) return '';
    final RegExpMatch? m =
        RegExp(r'^[\w-]{6,}$', caseSensitive: false).firstMatch(t);
    return m != null ? m.group(0)! : '';
  }
}
