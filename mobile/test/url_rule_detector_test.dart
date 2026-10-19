import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/unified_rule_kind.dart';
import 'package:six_clean_room/utils/url_rule_detector.dart';

void main() {
  test('detect — percent-encoded Korean @handle URL is channel, not host', () {
    const String encoded =
        'https://www.youtube.com/@%EB%B7%B0%ED%8B%B0%ED%92%80%EB%84%88%EB%93%9C';
    final DetectedRule d = UrlRuleDetector.detect(encoded);
    expect(d.kind, UnifiedRuleKind.channelURL);
    expect(d.pattern, '@뷰티풀너드');
  });

  test('detect — bare Korean @handle is channel', () {
    final DetectedRule d = UrlRuleDetector.detect('@뷰티풀너드');
    expect(d.kind, UnifiedRuleKind.channelURL);
    expect(d.pattern, '@뷰티풀너드');
  });

  test('detect — youtube.com alone is host (whole-site confirm path)', () {
    final DetectedRule d = UrlRuleDetector.detect('youtube.com');
    expect(d.kind, UnifiedRuleKind.host);
    expect(d.pattern, 'youtube.com');
  });

  test('smartRuleHint — encoded channel shows channel hint', () {
    const String encoded =
        'https://www.youtube.com/@%EB%B7%B0%ED%8B%B0%ED%92%80%EB%84%88%EB%93%9C';
    final String? hint = UrlRuleDetector.smartRuleHint(encoded);
    expect(hint, contains('채널'));
  });

  test('detect — pornhub path without scheme is apex host, not keyword', () {
    const String line = 'pornhub.com/aoidjfosidjfoi';
    final DetectedRule d = UrlRuleDetector.detect(line);
    expect(d.kind, UnifiedRuleKind.host);
    expect(d.pattern, 'pornhub.com');
    expect(d.normalizedFrom, line);
  });

  test('detect — https pornhub path strips to apex host', () {
    const String line = 'https://pornhub.com/view_video.php?viewkey=abc';
    final DetectedRule d = UrlRuleDetector.detect(line);
    expect(d.kind, UnifiedRuleKind.host);
    expect(d.pattern, 'pornhub.com');
  });
}
