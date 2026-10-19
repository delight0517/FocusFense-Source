import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/data/schedule_domain_presets.dart';

void main() {
  test('adult preset uses expanded builtin list', () {
    final ScheduleDomainPreset adult = scheduleDomainPresets().first;
    expect(adult.name, '성인');
    expect(adult.domains.length, greaterThanOrEqualTo(200));
    expect(adult.numericStems, isNotEmpty);
    expect(
      adult.itemCount,
      adult.domains.length + adult.numericStems.length + adult.keywords.length,
    );
    expect(adult.domains, contains('redbogo4.com'));
    expect(adult.numericStems, contains('redbogo'));
  });

  test('4VPN visible packs are exposed as schedule presets', () {
    final Map<String, ScheduleDomainPreset> byId =
        <String, ScheduleDomainPreset>{
          for (final ScheduleDomainPreset preset in scheduleDomainPresets())
            preset.id: preset,
        };

    expect(byId['gaming_pack_400']?.domains.length, greaterThanOrEqualTo(200));
    expect(byId['gaming_pack_400']?.keywords.length, greaterThanOrEqualTo(300));
    expect(byId['gambling']?.domains.length, greaterThanOrEqualTo(100));
    expect(byId['gambling']?.keywords.length, greaterThanOrEqualTo(80));
    expect(
      byId['illegal_webtoon_sites']?.domains.length,
      greaterThanOrEqualTo(50),
    );
    expect(
      byId['illegal_webtoon_sites']?.keywords.length,
      greaterThanOrEqualTo(30),
    );
  });
}
