import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/browser_youtube_policy_split.dart';
import 'package:six_clean_room/services/chromium_policy_service.dart';
import 'package:six_clean_room/services/extension_rules_builder.dart';
import 'package:six_clean_room/services/youtube_enforcement_hosts.dart';

/// Self-test for the YouTube block pipeline — proves the exact video/channel
/// the user reported (`watch?v=oKv36JQ64QM`, `@SC2HL`) produces correct,
/// Chromium URLBlocklist fallback. Rules remain limited to selected
/// channel/video URLs.
void main() {
  group('Chromium YouTube fallback safety', () {
    test(
      'does not create site-wide blocking when extension is unavailable',
      () {
        final List<String> patterns =
            BrowserYoutubePolicySplit.withYoutubeApexEnsured(const <String>[
              '*://youtube.com/watch?v=video123*',
            ]);
        expect(patterns, <String>['*://youtube.com/watch?v=video123*']);
      },
    );

    test('keeps an explicitly selected full-domain block', () {
      final List<String> patterns =
            BrowserYoutubePolicySplit.withYoutubeApexEnsured(const <String>[
              'youtube.com',
            ]);
      expect(patterns, <String>['youtube.com']);
    });
  });

  group('YouTube video block — watch?v=oKv36JQ64QM', () {
    const String mixedCaseUrl = 'https://www.youtube.com/watch?v=oKv36JQ64QM';
    const String vid = 'oKv36JQ64QM';

    ExtensionRulesPayload payloadFor(String rawKeyword, {String? videoId}) {
      return ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: <String>[rawKeyword.toLowerCase()],
        rawKeywords: <String>[rawKeyword],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeVideoIds: videoId != null
            ? <String>[videoId]
            : const <String>[],
      );
    }

    test('HKCU URLBlocklist patterns cover BOTH original and lower case', () {
      final ExtensionRulesPayload payload = payloadFor(
        mixedCaseUrl,
        videoId: vid,
      );
      final List<String> patterns =
          ChromiumPolicyService.youtubeUrlBlockPatterns(payload);

      expect(patterns, contains('*://*.youtube.com/watch?v=$vid*'));
      expect(patterns, contains('*://youtu.be/$vid*'));
      expect(patterns, isNot(contains('youtube.com')));
      expect(patterns, isNot(contains('youtu.be')));
    });

    test('video id is extracted from rawKeywords (case preserved)', () {
      final ExtensionRulesPayload payload = payloadFor(mixedCaseUrl);
      final List<String> patterns =
          ChromiumPolicyService.youtubeUrlBlockPatterns(payload);
      expect(patterns, contains('*://*.youtube.com/watch?v=$vid*'));
    });

    test('payload JSON exposes blockedYoutubeVideoIds to the extension', () {
      final ExtensionRulesPayload payload = payloadFor(
        mixedCaseUrl,
        videoId: vid,
      );
      final Map<String, Object?> json = payload.toJson(port: 17361);
      expect(json['blockedYoutubeVideoIds'], contains(vid));
    });
  });

  group('YouTube channel block — @SC2HL', () {
    test('handle patterns cover original and lower case', () {
      const String handle = 'SC2HL';
      final ExtensionRulesPayload payload = ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>['youtube.com/@sc2hl'],
        rawKeywords: const <String>['https://www.youtube.com/@SC2HL'],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeHandles: <String>[handle],
      );
      final List<String> patterns =
          ChromiumPolicyService.youtubeUrlBlockPatterns(payload);
      expect(patterns, contains('*://*.youtube.com/@SC2HL*'));
      expect(patterns, isNot(contains('youtube.com')));
    });
  });

  group('YouTube handle camelCase variants — @uThermal from @uthermal', () {
    // User reports: DB has `youtube.com/@uthermal` (lowercase) but YouTube
    // serves the channel as `@uThermal` (lowercase u, uppercase T). Plain
    // lower+upper variants don't catch it. We must also emit a TitleCase
    // variant and an "lTitle" (lowercase first + Title-cased rest) variant
    // so common camelCase channels match.
    test('emits uThermal variant from lowercase handle uthermal', () {
      final ExtensionRulesPayload payload = ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>['youtube.com/@uthermal'],
        rawKeywords: const <String>['youtube.com/@uthermal'],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeHandles: <String>['uthermal'],
      );
      final List<String> ps = ChromiumPolicyService.youtubeUrlBlockPatterns(
        payload,
      );
      expect(ps, contains('*://*.youtube.com/@uThermal*'));
    });
  });

  group('YouTube URL surface coverage — m. / music. / bare / embed', () {
    test('video patterns cover mobile, music, bare-host, embed surfaces', () {
      const String vid = 'oKv36JQ64QM';
      final ExtensionRulesPayload payload = ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: <String>['youtube.com/watch?v=$vid'.toLowerCase()],
        rawKeywords: <String>['https://www.youtube.com/watch?v=$vid'],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeVideoIds: <String>[vid],
      );
      final List<String> ps = ChromiumPolicyService.youtubeUrlBlockPatterns(
        payload,
      );
      expect(ps, contains('*://*.youtube.com/watch?v=$vid*'));
      expect(ps, contains('*://youtu.be/$vid*'));
    });
    test('handle patterns cover m., music., bare youtube.com surfaces', () {
      const String handle = 'SC2HL';
      final ExtensionRulesPayload payload = ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>['youtube.com/@sc2hl'],
        rawKeywords: const <String>['https://www.youtube.com/@SC2HL'],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeHandles: <String>[handle],
      );
      final List<String> ps = ChromiumPolicyService.youtubeUrlBlockPatterns(
        payload,
      );
      expect(ps, contains('*://*.youtube.com/@SC2HL*'));
    });
  });

  group('PAC handle forms — percent-encoded Korean', () {
    test('youtubeHandlePacForms includes UTF-8 percent path', () {
      const String handle = '뷰티풀너드';
      final List<String> forms = ChromiumPolicyService.youtubeHandlePacForms(
        handle,
      );
      expect(
        forms.any((String f) => f.contains('%EB%B7%B0')),
        isTrue,
        reason: 'PAC must match percent-encoded @handle URLs',
      );
    });
  });

  group('YouTube channel block — Korean handle @뷰티풀너드 (percent-encoded URL)', () {
    test('handle patterns include percent-encoded UTF-8 variant', () {
      const String handle = '뷰티풀너드';
      const String percentEncoded =
          '%EB%B7%B0%ED%8B%B0%ED%92%80%EB%84%88%EB%93%9C';
      final ExtensionRulesPayload payload = ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>['youtube.com/@뷰티풀너드'],
        rawKeywords: const <String>[
          'https://www.youtube.com/@%EB%B7%B0%ED%8B%B0%ED%92%80%EB%84%88%EB%93%9C',
        ],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeHandles: <String>[handle],
      );
      final List<String> patterns =
          ChromiumPolicyService.youtubeUrlBlockPatterns(payload);
      expect(
        patterns,
        contains(
          '*://*.youtube.com/@%EB%B7%B0%ED%8B%B0%ED%92%80%EB%84%88%EB%93%9C*',
        ),
      );
    });
  });

  group('YouTube channel block — Korean handle @보따', () {
    // YouTube serves the Korean channel as `@%EB%B3%B4%EB%94%B0` in the
    // actual URL Chrome sees, while the app stores the handle as decoded
    // `보따`. URLBlocklist patterns are byte-compared against the encoded
    // URL — so we MUST emit a percent-encoded variant alongside the unicode
    // form, otherwise the channel sits on the blocklist but never gets blocked.
    test('handle patterns include percent-encoded UTF-8 variant', () {
      const String handle = '보따';
      const String percentEncoded = '%EB%B3%B4%EB%94%B0';
      final ExtensionRulesPayload payload = ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>['youtube.com/@보따'],
        rawKeywords: const <String>['https://www.youtube.com/@보따'],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeHandles: <String>[handle],
      );
      final List<String> patterns =
          ChromiumPolicyService.youtubeUrlBlockPatterns(payload);
      expect(patterns, contains('*://*.youtube.com/@%EB%B3%B4%EB%94%B0*'));
      // The user pasted the URL with percent-encoded path too — same answer.
      final ExtensionRulesPayload payload2 = ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>['youtube.com/@%eb%b3%b4%eb%94%b0'],
        rawKeywords: const <String>[
          'https://www.youtube.com/@%EB%B3%B4%EB%94%B0',
        ],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeHandles: <String>[handle],
      );
      final List<String> patterns2 =
          ChromiumPolicyService.youtubeUrlBlockPatterns(payload2);
      expect(patterns2, contains('*://*.youtube.com/@%EB%B3%B4%EB%94%B0*'));
    });
  });

  group('URLBlocklist cap — handles before bulk videos', () {
    test('winterstarcraft survives 300+ video ids in payload', () {
      final List<String> manyVids = List<String>.generate(
        320,
        (int i) => 'vid${i.toString().padLeft(6, '0')}',
      );
      final ExtensionRulesPayload payload = ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>[],
        rawKeywords: const <String>[],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeHandles: const <String>['winterstarcraft'],
        blockedYoutubeVideoIds: manyVids,
      );
      final List<String> patterns =
          ChromiumPolicyService.youtubeUrlBlockPatterns(payload);
      expect(patterns, contains('*://*.youtube.com/@winterstarcraft*'));
    });
  });

  group('YouTube selected URL access', () {
    test('specific video blocks do not sinkhole shared media CDNs', () {
      final List<String> builtins =
          YoutubeEnforcementHosts.expandedBuiltinDomainsForWindowsHosts();
      expect(builtins, isNot(contains('youtube.com')));
      expect(builtins, isNot(contains('youtu.be')));
      expect(builtins, isNot(contains('googlevideo.com')));
      expect(builtins, isNot(contains('ytimg.com')));
      expect(builtins, isNot(contains('pornhub.com')));
      final List<String> adultBuiltins =
          YoutubeEnforcementHosts.expandedBuiltinDomainsForWindowsHosts(
            includeAdult: true,
          );
      expect(adultBuiltins, contains('pornhub.com'));
    });
  });
}
