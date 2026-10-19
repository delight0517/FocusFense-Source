import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/rules_meta.dart';

void main() {
  test('adult site blocking is enabled by default', () {
    expect(RulesMeta.defaults.adultSitesBlocked, isTrue);
    expect(RulesMeta.fromJson(<String, Object?>{}).adultSitesBlocked, isTrue);
    expect(RulesMeta.fromPrefsString('{}').adultSitesBlocked, isTrue);
  });

  test('an explicit opt-out remains disabled after serialization', () {
    final RulesMeta optedOut = RulesMeta.defaults.copyWith(
      adultSitesBlocked: false,
    );

    expect(RulesMeta.fromJson(optedOut.toJson()).adultSitesBlocked, isFalse);
    expect(
      RulesMeta.fromPrefsString(optedOut.toPrefsJson()).adultSitesBlocked,
      isFalse,
    );
  });
}
