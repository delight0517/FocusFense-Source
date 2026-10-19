import 'package:shared_preferences/shared_preferences.dart';

/// Changes expensive Firefox YouTube feed filtering only, never URL protection.
class BrowserPerformancePrefs {
  BrowserPerformancePrefs._();
  static final instance = BrowserPerformancePrefs._();
  static const key = 'firefox_youtube_feed_filtering_v1';
  Future<bool> youtubeFeedFiltering() async =>
      (await SharedPreferences.getInstance()).getBool(key) ?? true;
  Future<void> setYoutubeFeedFiltering(bool enabled) async {
    if (!await (await SharedPreferences.getInstance()).setBool(key, enabled)) {
      throw StateError('Could not save Firefox performance preference');
    }
  }

  Future<Map<String, Object?>> status() async => {
    'browser': 'firefox',
    'youtubeFeedFiltering': await youtubeFeedFiltering(),
    'scope': 'youtube-feed-filtering-only',
    'urlProtectionUnchanged': true,
    'quotaUnchanged': true,
  };
}
