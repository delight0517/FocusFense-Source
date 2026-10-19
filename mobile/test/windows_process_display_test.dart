import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_process_display.dart';
import 'package:six_clean_room/services/windows_process_lister.dart';

void main() {
  test('SC2 path gets StarCraft II label', () {
    const RunningProcessInfo p = RunningProcessInfo(
      exeName: 'sc2_x64.exe',
      pid: 1,
      windowTitle: '',
      executablePath: r'C:\Program Files (x86)\StarCraft II\Versions\Base\SC2_x64.exe',
    );
    expect(WindowsProcessDisplay.friendlyName(p), 'StarCraft II');
  });

  test('Battle.net Agent path gets friendly label', () {
    const RunningProcessInfo p = RunningProcessInfo(
      exeName: 'agent.exe',
      pid: 1,
      windowTitle: '',
      executablePath: r'C:\ProgramData\Battle.net\Agent\Agent.exe',
    );
    expect(WindowsProcessDisplay.friendlyName(p), 'Battle.net (Agent)');
  });
}
