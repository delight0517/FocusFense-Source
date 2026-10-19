import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/block_app.dart';
import 'package:six_clean_room/services/windows_game_app_aliases.dart';
import 'package:six_clean_room/services/windows_process_lister.dart';

void main() {
  test('Battle.net preset expands to agent and sc2', () {
    final List<BlockApp> out = WindowsGameAppAliases.expand(<BlockApp>[
      const BlockApp(exeName: '', displayName: 'Battle.net', windowTitleMatch: 'Battle.net'),
    ]);
    final Set<String> exes = out.map((BlockApp a) => a.exeName).toSet();
    expect(exes, containsAll(<String>['battle.net.exe', 'agent.exe', 'sc2_x64.exe']));
  });

  test('StarCraft II preset maps to sc2_x64', () {
    final List<BlockApp> out = WindowsGameAppAliases.expand(<BlockApp>[
      const BlockApp(exeName: '', displayName: 'StarCraft II'),
    ]);
    expect(out.single.exeName, 'sc2_x64.exe');
  });

  test('picker battle.net exe expands related processes for storage', () {
    final List<BlockApp> out = WindowsGameAppAliases.fromPickerSelection(
      <RunningProcessInfo>[
        const RunningProcessInfo(
          exeName: 'battle.net.exe',
          pid: 1,
          windowTitle: 'Battle.net',
          executablePath: r'C:\Program Files (x86)\Battle.net\Battle.net.exe',
        ),
      ],
    );
    final Set<String> exes = out.map((BlockApp a) => a.exeName).toSet();
    expect(exes, containsAll(<String>['battle.net.exe', 'agent.exe', 'sc2_x64.exe']));
  });
}
