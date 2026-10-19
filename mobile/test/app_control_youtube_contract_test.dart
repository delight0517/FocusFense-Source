import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/app_control_contract.dart';

void main() {
  test(
    'budget target contracts reject missing empty oversized and unknown input',
    () {
      for (final action in [
        'youtube.exemptions.preview',
        'youtube.exemptions.add',
        'youtube.exemptions.remove',
      ]) {
        AppControlContract.validate(action, {
          'targets': ['https://youtu.be/AbCdEf123_-'],
        });
        for (final args in <Map<String, Object?>>[
          {},
          {'targets': []},
          {
            'targets': [''],
          },
          {
            'targets': [' '],
          },
          {
            'targets': [1],
          },
          {'targets': List.filled(51, 'https://example.com')},
          {
            'targets': ['https://example.com\n'],
          },
          {
            'targets': ['https://example.com'],
            'disableAdult': true,
          },
        ]) {
          expect(
            () => AppControlContract.validate(action, args),
            throwsFormatException,
          );
        }
      }
    },
  );
  test('chat service contract has no parser-message or lock bypass', () {
    AppControlContract.validate('chat.preview', {
      'message': '유튜브 시간 제외',
      'resolution': 'existing',
    });
    for (final args in <Map<String, Object?>>[
      {},
      {'message': ''},
      {'message': ' '},
      {'message': 'hi', 'parserMessage': 'override'},
      {'message': 'hi', 'resolution': 'bypass'},
      {'message': 'hi', 'forceScheduleId': ''},
    ]) {
      expect(
        () => AppControlContract.validate('chat.apply', args),
        throwsFormatException,
      );
    }
  });
}
