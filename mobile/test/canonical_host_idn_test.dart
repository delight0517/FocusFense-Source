import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/mac_system_block_service.dart';
import 'package:six_clean_room/utils/url_rule_detector.dart';
import 'package:six_clean_room/models/unified_rule_kind.dart';

void main() {
  test('canonicalHost — Unicode IDN becomes punycode', () {
    const String url = 'https://링크다모아.com/';
    final String host = MacSystemBlockService.canonicalHost(url);
    expect(host, 'xn--2j1b43k3tao42a6rn.com');
  });

  test('canonicalHost — punycode URL unchanged', () {
    const String url = 'https://xn--2j1b43k3tao42a6rn.com/path';
    final String host = MacSystemBlockService.canonicalHost(url);
    expect(host, 'xn--2j1b43k3tao42a6rn.com');
  });

  test('detect — paste full link-damoa URL is host block', () {
    const String url = 'https://xn--2j1b43k3tao42a6rn.com/';
    final DetectedRule d = UrlRuleDetector.detect(url);
    expect(d.kind, UnifiedRuleKind.host);
    expect(d.pattern, 'xn--2j1b43k3tao42a6rn.com');
  });

  test('detect — Unicode link-damoa URL normalizes to punycode host', () {
    const String url = 'https://링크다모아.com/';
    final DetectedRule d = UrlRuleDetector.detect(url);
    expect(d.kind, UnifiedRuleKind.host);
    expect(d.pattern, 'xn--2j1b43k3tao42a6rn.com');
  });
}
