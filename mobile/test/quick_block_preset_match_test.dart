import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/data/schedule_domain_presets.dart';

void main() {
  group('quick block preset matching', () {
    test(
      'recognizes Korean and English adult-content words as the adult preset',
      () {
        for (final String query in <String>['porn', 'porn site', '야동', '음란물']) {
          expect(
            matchQuickBlockPresets(query).map((ScheduleDomainPreset p) => p.id),
            contains('adult_combined'),
            reason: 'Expected a visible adult preset suggestion for "$query"',
          );
          expect(exactQuickBlockPreset(query)?.id, 'adult_combined');
        }

        final List<ScheduleDomainPreset> matches = matchQuickBlockPresets(
          'porn site',
        );

        expect(matches, isNotEmpty);
        expect(matches.first.id, 'adult_combined');
      },
    );

    test('finds gambling presets from Korean and English queries', () {
      for (final String query in <String>[
        '도박',
        '도박 사이트',
        '카지노',
        'casino',
        'gambling',
      ]) {
        expect(
          matchQuickBlockPresets(query).map((ScheduleDomainPreset p) => p.id),
          contains('gambling'),
          reason: 'Expected a visible gambling preset suggestion for "$query"',
        );
        expect(exactQuickBlockPreset(query)?.id, 'gambling');
      }
      expect(matchQuickBlockPresets('gamb').first.id, 'gambling');
    });

    test('keeps ordinary phrases on normal rule detection', () {
      expect(exactQuickBlockPreset('porn site blocker tips'), isNull);
      expect(matchQuickBlockPresets('x'), isEmpty);
    });
  });
}
