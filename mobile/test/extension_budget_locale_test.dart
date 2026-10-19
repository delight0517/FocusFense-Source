import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/extension_rules_builder.dart';

void main() {
  test('Firefox rule projection preserves the chosen app locale', () {
    for (final locale in ['en', 'ja', 'zh', 'ko', 'he', 'ar']) {
      final payload = ExtensionRulesPayload(
        blockedDomains: const ['youtube.com', 'example.com'],
        keywords: const [],
        searchQueries: const [],
        precisionContentFilter: true,
        updatedAtMs: 1,
        locale: locale,
      );
      final firefox = payload.copyWithoutYoutubeApex();
      expect(firefox.toJson(port: 17361)['focusfenseLocale'], locale);
      expect(firefox.blockedDomains, ['example.com']);
    }
  });
}
