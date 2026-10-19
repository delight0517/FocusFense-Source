import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/unified_rule_kind.dart';
import 'package:six_clean_room/utils/url_rule_detector.dart';

void main() {
  test('inferStoredKind — domain row', () {
    expect(
      UrlRuleDetector.inferStoredKind(value: 'reddit.com', isDomainRow: true),
      UnifiedRuleKind.host,
    );
  });

  test('inferStoredKind — youtube video pattern', () {
    expect(
      UrlRuleDetector.inferStoredKind(
        value: 'youtube.com/watch?v=abc123',
        isDomainRow: false,
      ),
      UnifiedRuleKind.videoURL,
    );
  });

  test('inferStoredKind — channel handle', () {
    expect(
      UrlRuleDetector.inferStoredKind(value: '@starcraft', isDomainRow: false),
      UnifiedRuleKind.channelURL,
    );
  });
}
