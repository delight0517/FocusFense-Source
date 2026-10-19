import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/data/allowed_browser_app_catalog.dart';

void main() {
  group('AllowedBrowserAppCatalog.isAllowedWindowTitle', () {
    test('allows Gemini / Gmail / YouTube Music / Google login windows', () {
      const List<String> allowed = <String>[
        'Gemini - Google Chrome',
        'Gmail - Google Chrome',
        '받은편지함 (3) - Gmail - Google Chrome',
        'YouTube Music - Google Chrome',
        '로그인 - Google 계정 - Google Chrome',
        'Sign in - Google Accounts - Google Chrome',
      ];
      for (final String t in allowed) {
        expect(AllowedBrowserAppCatalog.isAllowedWindowTitle(t), isTrue,
            reason: 'should allow: $t');
      }
    });

    test('does NOT allow general browsing or plain YouTube', () {
      const List<String> blocked = <String>[
        'Google Chrome',
        'New Tab - Google Chrome',
        'YouTube - Google Chrome',
        '야동 최신 - Google Chrome',
      ];
      for (final String t in blocked) {
        expect(AllowedBrowserAppCatalog.isAllowedWindowTitle(t), isFalse,
            reason: 'should NOT allow: $t');
      }
    });
  });

  group('AllowedBrowserAppCatalog.isGenericBrowserBrand', () {
    test('bare browser brand names are generic (never title-kill)', () {
      for (final String b in <String>[
        'Google Chrome',
        'google chrome',
        'Microsoft Edge',
        'Mozilla Firefox',
        'Naver Whale',
        'Brave',
      ]) {
        expect(AllowedBrowserAppCatalog.isGenericBrowserBrand(b), isTrue,
            reason: 'should be generic brand: $b');
      }
    });

    test('a real page title is not a generic brand', () {
      expect(
          AllowedBrowserAppCatalog.isGenericBrowserBrand(
              'Gemini - Google Chrome'),
          isFalse);
      expect(AllowedBrowserAppCatalog.isGenericBrowserBrand('Battle.net'),
          isFalse);
    });
  });
}
