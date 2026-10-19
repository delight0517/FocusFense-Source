import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/services/browser_performance_prefs.dart';
import 'package:six_clean_room/services/extension_rules_builder.dart';
import 'package:six_clean_room/services/app_control_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Firefox performance preference defaults full and persists light',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = BrowserPerformancePrefs.instance;
      expect(await prefs.youtubeFeedFiltering(), isTrue);
      await prefs.setYoutubeFeedFiltering(false);
      expect(await prefs.youtubeFeedFiltering(), isFalse);
      expect((await prefs.status())['quotaUnchanged'], isTrue);
    },
  );
  test(
    'light payload retains exact URL channel video keyword and SafeSearch protection',
    () {
      const original = ExtensionRulesPayload(
        blockedDomains: ['adult.example', 'youtube.com'],
        keywords: ['blocked'],
        searchQueries: [],
        precisionContentFilter: true,
        updatedAtMs: 1,
        blockedYoutubeHandles: ['handle'],
        blockedYoutubeChannelIds: ['UCtest'],
        blockedYoutubeVideoIds: ['AbCdEf123_-'],
        forceSafeSearch: true,
        protectionEnabled: true,
        focusLocked: true,
      );
      final full = original.toJson(port: 1);
      final light = original.withYoutubeFeedFiltering(false).toJson(port: 1);
      expect(light['hideYoutubeResults'], isFalse);
      for (final key in full.keys.where((key) => key != 'hideYoutubeResults')) {
        expect(light[key], full[key], reason: key);
      }
      expect(original.toJson(port: 1)['hideYoutubeResults'], isTrue);
      final split = original
          .withYoutubeFeedFiltering(false)
          .copyWithoutYoutubeApex()
          .toJson(port: 1);
      expect(split['hideYoutubeResults'], isFalse);
      expect(split['blockedYoutubeVideoIds'], ['AbCdEf123_-']);
      expect(split['blockedDomains'], ['adult.example']);
    },
  );
  test(
    'performance action accepts bool only and rejects protection changes',
    () {
      AppControlContract.validate('browser.performance', {
        'youtubeFeedFiltering': false,
      });
      for (final args in <Map<String, Object?>>[
        {},
        {'youtubeFeedFiltering': 'false'},
        {'youtubeFeedFiltering': false, 'protectionEnabled': false},
      ]) {
        expect(
          () => AppControlContract.validate('browser.performance', args),
          throwsFormatException,
        );
      }
    },
  );
}
