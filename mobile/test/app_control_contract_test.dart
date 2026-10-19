import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/app_control_contract.dart';

void main() {
  test('Chrome temporary block bounds and exact integer duration', () {
    AppControlContract.validate('app.blockChrome', {'hours': 72});
    for (final hours in [null, 0, -1, 73, 1.5, '72']) {
      expect(
        () => AppControlContract.validate('app.blockChrome', {'hours': hours}),
        throwsFormatException,
      );
    }
    expect(
      () => AppControlContract.validate('app.blockChrome', {
        'hours': 72,
        'exe': 'other.exe',
      }),
      throwsFormatException,
    );
  });
  test('reject invalid args before preview or mutation', () {
    for (final args in <Map<String, Object?>>[
      {'strictness': 'other'},
      {'forceSafeSearch': 'false'},
      {'unlockPinRequired': false},
      {},
    ]) {
      expect(
        () => AppControlContract.validate('policy.patch', args),
        throwsFormatException,
      );
    }
    expect(
      () =>
          AppControlContract.validate('browser.enable', {'browser': 'unknown'}),
      throwsFormatException,
    );
    expect(
      () => AppControlContract.validate('protection.enable', {
        'shell': 'anything',
      }),
      throwsFormatException,
    );
  });
  test('domain normalization and allowed policy patch', () {
    expect(
      AppControlContract.normalizeHost('https://Example.com./path'),
      'example.com',
    );
    expect(
      () => AppControlContract.normalizeHost('https://user:pass@example.com'),
      throwsFormatException,
    );
    AppControlContract.validate('policy.patch', {
      'forceSafeSearch': true,
      'strictness': 'strict',
    });
    AppControlContract.validate('rule.add', {
      'type': 'keyword',
      'value': 'test',
    });
  });
}
