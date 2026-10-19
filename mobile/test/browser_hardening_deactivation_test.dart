import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_browser_bypass_closer_service.dart';
import 'package:six_clean_room/services/windows_extension_guard_service.dart';
import 'package:six_clean_room/services/windows_system_block_service.dart';
import 'package:six_clean_room/services/mac_system_block_service.dart';

void main() {
  for (final timing in ['before', 'intent', 'write']) {
    test(
      'browser OFF at $timing prevents late hardening and preserves other browser',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'ff-hardening-race-',
        );
        final root =
            'HKCU:\\Software\\FocusFenseHardeningTest\\${DateTime.now().microsecondsSinceEpoch}';
        final marker = '${temp.path}\\browser-off.json';
        final journal = '${temp.path}\\owned.json';
        String q(String s) => "'${s.replaceAll("'", "''")}'";
        final values = <Map<String, Object>>[
          {
            'key': '$root\\Aside',
            'name': 'QuicAllowed',
            'kind': 'DWord',
            'value': 0,
            'disabledMarkerPath': marker,
          },
          {
            'key': '$root\\Aside',
            'name': 'IncognitoModeAvailability',
            'kind': 'DWord',
            'value': 1,
            'disabledMarkerPath': marker,
          },
          {
            'key': '$root\\Chrome',
            'name': 'QuicAllowed',
            'kind': 'DWord',
            'value': 0,
          },
        ];
        var apply = WindowsBrowserBypassCloserService.buildOwnedHardeningScript(
          pacUri: '',
          journalPath: journal,
          offMarkerPath: '${temp.path}\\global-off',
          valuesForTesting: values,
        );
        final hook = timing == 'before'
            ? 'Set-Content -LiteralPath ${q(marker)} -Value disabled'
            : timing == 'intent'
            ? '''
\$originalSave = \${function:Save-FFPac}
function Save-FFPac(\$records) {
  & \$originalSave \$records
  if (@(\$records | Where-Object { \$_.name -eq 'QuicAllowed' -and \$_.key -like '*\\Aside' }).Count -gt 0) {
    Set-Content -LiteralPath ${q(marker)} -Value disabled
  }
}
'''
            : '''
\$originalWrite = \${function:Write-FFPacState}
function Write-FFPacState([string]\$key,[string]\$name,\$state) {
  & \$originalWrite \$key \$name \$state
  if (\$key -like '*\\Aside' -and \$state.exists -and \$state.value -eq '0') {
    Set-Content -LiteralPath ${q(marker)} -Value disabled
  }
}
''';
        apply = apply.replaceFirst(
          'if (-not (Invoke-FFPacApply))',
          '$hook\nif (-not (Invoke-FFPacApply))',
        );
        final file = File('${temp.path}\\test.ps1');
        await file.writeAsString('''
\$ErrorActionPreference='Stop'
try {
New-Item -Path ${q('$root\\Aside')} -Force | Out-Null
Set-ItemProperty -LiteralPath ${q('$root\\Aside')} -Name QuicAllowed -Value 1 -Type DWord
$apply
\$a=Get-Item -LiteralPath ${q('$root\\Aside')}
if (\$a.GetValue('QuicAllowed') -ne 1 -or \$null -ne \$a.GetValue('IncognitoModeAvailability')) { throw 'late browser write' }
if ((Get-Item -LiteralPath ${q('$root\\Chrome')}).GetValue('QuicAllowed') -ne 0) { throw 'other browser lost' }
\$saved=Get-Content -LiteralPath ${q(journal)} -Raw | ConvertFrom-Json
if (@(\$saved.entries).Count -ne 1 -or \$saved.entries[0].key -notlike '*\\Chrome') { throw 'stale ownership resurrected' }
} finally { Remove-Item -LiteralPath ${q(root)} -Recurse -Force -ErrorAction SilentlyContinue }
''');
        try {
          final result = await Process.run(
            r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
            ['-NoProfile', '-NonInteractive', '-File', file.path],
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        } finally {
          await temp.delete(recursive: true);
        }
      },
      skip: !Platform.isWindows,
    );
  }
  test('local failure cannot prevent other cleanup or elevation', () async {
    var attempts = 0;
    var other = 0;
    var elevated = 0;
    final result = await WindowsSystemBlockService.runDeactivationPhases(
      local: [
        () async {
          if (++attempts == 1) throw StateError('locked');
        },
        () async {
          other++;
        },
      ],
      elevated: () async {
        elevated++;
        return MacBlockResult.success();
      },
    );
    expect(result.ok, isTrue);
    expect([attempts, other, elevated], [2, 2, 1]);
  });
  test('persistent local cleanup failure remains a failure', () async {
    final result = await WindowsSystemBlockService.runDeactivationPhases(
      local: [
        () async {
          throw StateError('still locked');
        },
      ],
      elevated: () async => MacBlockResult.success(),
    );
    expect(result.ok, isFalse);
  });
  test('cancelled elevation does not claim success or retry', () async {
    var count = 0;
    final result = await WindowsSystemBlockService.runDeactivationPhases(
      local: [
        () async {
          count++;
          throw StateError('locked');
        },
      ],
      elevated: () async => MacBlockResult.cancelled(),
    );
    expect(result.status, MacBlockStatus.cancelled);
    expect(count, 1);
  });
  test('primary PAC and DNS have a single owner', () {
    final values = WindowsBrowserBypassCloserService.hardeningValues(
      'file:///test',
    );
    final primary = values.where(
      (v) =>
          '${v['key']}'.endsWith(r'Google\Chrome') ||
          '${v['key']}'.endsWith(r'Microsoft\Edge'),
    );
    expect(primary.map((v) => v['name']).toSet(), {
      'IncognitoModeAvailability',
      'QuicAllowed',
      'BrowserSwitcherEnabled',
      'InternetExplorerIntegrationLevel',
    });
  });
  test(
    'browser OFF restores owned hardening and retains typed baseline',
    () async {
      final temp = await Directory.systemTemp.createTemp('ff-hardening-test-');
      final root =
          'HKCU:\\Software\\FocusFenseHardeningTest\\${DateTime.now().microsecondsSinceEpoch}';
      String q(String s) => "'${s.replaceAll("'", "''")}'";
      final values = <Map<String, Object>>[
        {
          'key': root,
          'name': 'IncognitoModeAvailability',
          'kind': 'DWord',
          'value': 1,
        },
        {'key': root, 'name': 'QuicAllowed', 'kind': 'DWord', 'value': 0},
      ];
      final journal = '${temp.path}\\owned.json';
      final apply = WindowsBrowserBypassCloserService.buildOwnedHardeningScript(
        pacUri: '',
        journalPath: journal,
        offMarkerPath: '${temp.path}\\off',
        valuesForTesting: values,
      );
      final disable =
          WindowsExtensionGuardService.disableBrowserExtensionsScript(
                browserIds: ['aside'],
                resultPath: '${temp.path}\\result',
                registryRoots: {
                  'aside': [root],
                },
                ownedHardeningJournalPath: journal,
                hardeningValuesForTesting: values,
              )
              .replaceAll('exit 0', 'return')
              .replaceAll('exit 1', "throw 'disable failed'");
      final file = File('${temp.path}\\test.ps1');
      await file.writeAsString('''
\$ErrorActionPreference='Stop'
try {
New-Item -Path ${q(root)} -Force | Out-Null
Set-ItemProperty -LiteralPath ${q(root)} -Name IncognitoModeAvailability -Type DWord -Value 1
Set-ItemProperty -LiteralPath ${q(root)} -Name QuicAllowed -Type DWord -Value 1
$apply
& { $disable }
\$key=Get-Item -LiteralPath ${q(root)}
if (\$key.GetValue('IncognitoModeAvailability') -ne 1 -or \$key.GetValue('QuicAllowed') -ne 1) { throw 'baseline lost' }
if (\$key.GetValueKind('QuicAllowed').ToString() -ne 'DWord') { throw 'kind lost' }
} finally { Remove-Item -LiteralPath ${q(root)} -Recurse -Force -ErrorAction SilentlyContinue }
''');
      try {
        final result = await Process.run(
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
          ['-NoProfile', '-NonInteractive', '-File', file.path],
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
