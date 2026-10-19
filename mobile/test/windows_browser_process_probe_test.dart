import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_hidden_process.dart';

void main() {
  test('native pipe retains every chunk before buffer reuse and release', () async {
    if (!Platform.isWindows) return;
    final result = await windowsRunHidden(
      '${Platform.environment['WINDIR']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command',
        r'[Console]::Out.Write(("A" * 20000) + ("B" * 20000)); [Console]::Error.Write(("C" * 18000))'],
    );
    expect(result.exitCode, 0);
    expect(result.stdout, '${'A' * 20000}${'B' * 20000}');
    expect(result.stderr, 'C' * 18000);
  });
  test('live Windows browser process probe returns parseable JSON', () async {
    if (!Platform.isWindows) return;
    final result = await windowsRunHidden(
      '${Platform.environment['WINDIR']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoProfile', '-NoLogo', '-NonInteractive', '-Command',
       'Get-CimInstance Win32_Process -Filter "Name = \'chrome.exe\' OR Name = \'msedge.exe\' OR Name = \'brave.exe\'" | Select-Object ProcessId,Name,CommandLine | ConvertTo-Json -Compress -Depth 3'],
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final text = '${result.stdout}'.trim();
    if (text.isNotEmpty) expect(jsonDecode(text), anyOf(isList, isMap));
  });
}
