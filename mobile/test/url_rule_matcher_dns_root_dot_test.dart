import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/utils/url_rule_matcher.dart';

void main() {
  test('a terminal DNS root dot cannot bypass a domain rule', () {
    expect(
      urlMatchesColdTurkeyPattern(
        'https://blocked.example./path',
        'blocked.example',
      ),
      isTrue,
    );
    expect(
      urlMatchesColdTurkeyPattern(
        'https://sub.blocked.example./path',
        'blocked.example',
      ),
      isTrue,
    );
  });

  test('a terminal DNS root dot cannot bypass a host and path rule', () {
    expect(
      urlMatchesColdTurkeyPattern(
        'https://blocked.example./search?q=explicit',
        'blocked.example/search?q=*',
      ),
      isTrue,
    );
  });
}
