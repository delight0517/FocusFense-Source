import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/app_control_contract.dart';

void main() {
  const valid = <String, Object?>{
    'maxMinutes': 30,
    'warningMinutes': 10,
    'targets': ['sc2_x64.exe'],
    'enabled': true,
  };
  test(
    'pooled daily game contract accepts exact integers and explicit exes',
    () {
      AppControlContract.validate('gameBudget.configure', valid);
      AppControlContract.validate('gameBudget.configure', {
        ...valid,
        'maxMinutes': 1,
        'warningMinutes': 0,
      });
    },
  );
  test('invalid limits targets and bypass arguments fail before mutation', () {
    for (final args in <Map<String, Object?>>[
      {},
      {...valid, 'maxMinutes': 0},
      {...valid, 'maxMinutes': 1441},
      {...valid, 'maxMinutes': 30.0},
      {...valid, 'warningMinutes': -1},
      {...valid, 'warningMinutes': 30},
      {...valid, 'enabled': false},
      {...valid, 'targets': []},
      {
        ...valid,
        'targets': ['C:/game.exe'],
      },
      {
        ...valid,
        'targets': ['*.exe'],
      },
      {
        ...valid,
        'targets': ['../game.exe'],
      },
      {
        ...valid,
        'targets': ['Game.exe', 'game.exe'],
      },
      {...valid, 'targets': List.filled(101, 'game.exe')},
      {...valid, 'skipLock': true},
    ]) {
      expect(
        () => AppControlContract.validate('gameBudget.configure', args),
        throwsFormatException,
      );
    }
  });
}
