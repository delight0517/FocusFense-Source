import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/data/premade_p_block_website_list.dart';
import 'package:six_clean_room/data/schedule_domain_presets.dart';
import 'package:six_clean_room/utils/cold_turkey_rule_parser.dart';
import 'package:six_clean_room/utils/url_rule_matcher.dart';

void main() {
  group('P Block preset', () {
    test(
      'is registered and preserves the imported list without duplicates',
      () {
        final ScheduleDomainPreset preset = scheduleDomainPresets().singleWhere(
          (ScheduleDomainPreset item) => item.id == 'p_block_0501',
        );

        expect(preset.name, 'P 차단 목록');
        expect(preset.domains, isNotEmpty);
        expect(preset.keywords, isNotEmpty);
        expect(preset.domains.toSet().length, preset.domains.length);
        expect(preset.keywords.toSet().length, preset.keywords.length);
        expect(preset.domains, contains('pornhub.com'));
        expect(preset.keywords, contains('*google.com/*q=*가슴*성형*'));
        expect(preset.domains.length, 224);
        expect(preset.keywords.length, 399);
      },
    );

    test('quick-block input suggests the existing P-list preset', () {
      for (final String query in <String>[
        'p block websites',
        'p list',
        'porn list',
        'porn',
        '야동',
        '음란물',
        '야동 리스트',
        '음란물 리스트',
      ]) {
        expect(
          matchQuickBlockPresets(query).map((ScheduleDomainPreset p) => p.id),
          contains('p_block_0501'),
          reason: 'Expected P-list suggestion for "$query"',
        );
      }
      expect(exactQuickBlockPreset('p block websites')?.id, 'p_block_0501');
    });

    test(
      'imported search patterns match search URLs and ignore other terms',
      () {
        const String pattern = '*google.com/*q=*가슴*성형*';
        expect(
          urlMatchesColdTurkeyPattern(
            'https://www.google.com/search?q=가슴성형',
            pattern,
          ),
          isTrue,
        );
        expect(
          urlMatchesColdTurkeyPattern(
            'https://www.google.com/search?q=오늘+날씨',
            pattern,
          ),
          isFalse,
        );
      },
    );

    test('Cold Turkey regex subset and wildcard hosts are retained', () {
      expect(
        urlMatchesColdTurkeyPattern(
          'https://search.example/search?q=섹시',
          '*.*/*[?&]q=*(비키니|엉덩이|가슴[*]?성형|섹시|골반)*',
        ),
        isTrue,
      );
      expect(
        parseColdTurkeyLine('*.example.xxx')?.kind,
        ColdTurkeyRuleKind.urlPattern,
      );
      expect(
        urlMatchesColdTurkeyPattern(
          'https://sub.example.xxx/',
          '*.example.xxx',
        ),
        isTrue,
      );
    });
  });

  test('source-generated lists have the expected stable sizes', () {
    expect(kPBlockWebsiteDomains.length, 224);
    expect(kPBlockWebsiteUrlPatterns.length, 399);
  });
}
