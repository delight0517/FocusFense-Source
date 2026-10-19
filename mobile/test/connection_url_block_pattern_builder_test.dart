import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/connection_url_block_pattern_builder.dart';
import 'package:six_clean_room/services/extension_rules_builder.dart';

void main() {
  group('ConnectionUrlBlockPatternBuilder', () {
    test('emits URLBlocklist + PAC for host/path keywords', () {
      const ExtensionRulesPayload rules = ExtensionRulesPayload(
        blockedDomains: <String>[],
        keywords: <String>['reddit.com/r/nsfw'],
        rawKeywords: <String>['reddit.com/r/nsfw'],
        searchQueries: <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
      );

      final List<String> patterns =
          ConnectionUrlBlockPatternBuilder.urlBlocklistPatterns(rules);
      expect(patterns, isNotEmpty);
      expect(
        patterns.any((String p) => p.contains('reddit.com') && p.contains('r/nsfw')),
        isTrue,
      );

      final String pac = ConnectionUrlBlockPatternBuilder.pacLines(rules);
      expect(pac, contains('127.0.0.1:9'));
      expect(pac, contains('reddit.com'));
      expect(pac, contains('r/nsfw'));
    });

    test('skips YouTube keywords (owned by ChromiumPolicyService)', () {
      const ExtensionRulesPayload rules = ExtensionRulesPayload(
        blockedDomains: <String>[],
        keywords: <String>['youtube.com/@foo'],
        rawKeywords: <String>['youtube.com/@foo'],
        searchQueries: <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
        blockedYoutubeHandles: <String>['foo'],
      );

      expect(
        ConnectionUrlBlockPatternBuilder.urlBlocklistPatterns(rules),
        isEmpty,
      );
      expect(ConnectionUrlBlockPatternBuilder.pacLines(rules), isEmpty);
    });

    test('skips bare host keywords (domain layer owns them)', () {
      const ExtensionRulesPayload rules = ExtensionRulesPayload(
        blockedDomains: <String>[],
        keywords: <String>['pornhub.com'],
        rawKeywords: <String>['pornhub.com'],
        searchQueries: <ExtensionSearchQueryRule>[],
        precisionContentFilter: true,
        updatedAtMs: 0,
      );

      expect(
        ConnectionUrlBlockPatternBuilder.urlBlocklistPatterns(rules),
        isEmpty,
      );
    });
  });
}
