import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:six_clean_room/enforcement/layers/browser_policy_layer.dart';
import 'package:six_clean_room/services/chromium_policy_service.dart';
import 'package:six_clean_room/services/windows_browser_bypass_closer_service.dart';

String q(String text) => "'${text.replaceAll("'", "''")}'";

void main() {
  late Directory temp;
  late String root;
  late String journal;
  late String fragment;
  Future<ProcessResult> run(String body) async {
    final file = File(p.join(temp.path, 'run.ps1'));
    await file.writeAsString(
      "\$ErrorActionPreference='Stop'\n$fragment\n$body",
    );
    return Process.run(
      r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      <String>['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file.path],
    );
  }

  Future<Map<String, dynamic>> read() async {
    final result = await run('''
\$key=${q('$root\\URLBlocklist')}
\$values=@{}
foreach(\$property in (Get-ItemProperty -LiteralPath \$key).PSObject.Properties) {
  if (\$property.Name -match '^\\d+\$') { \$values[\$property.Name]=\$property.Value }
}
ConvertTo-Json -InputObject \$values -Compress
''');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return jsonDecode('${result.stdout}'.trim()) as Map<String, dynamic>;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ff-owned-policy-');
    root =
        'HKCU:\\Software\\FocusFenseOwnershipTest\\${DateTime.now().microsecondsSinceEpoch}';
    journal = p.join(temp.path, 'ownership.json');
    fragment = BrowserPolicyLayer.ownedListsPowerShell(
      journalPath: journal,
      policyRoots: <String>[root],
    );
    final result = await run('''
New-Item -Path ${q('$root\\URLBlocklist')} -Force | Out-Null
Set-ItemProperty -LiteralPath ${q('$root\\URLBlocklist')} -Name '1' -Value 'existing.example' -Type String
Set-ItemProperty -LiteralPath ${q('$root\\URLBlocklist')} -Name '5' -Value 'shared.example' -Type String
''');
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
  tearDown(() async {
    await run('Remove-Item -LiteralPath ${q(root)} -Recurse -Force');
    await temp.delete(recursive: true);
  });

  test('derivative writer preserves existing lists and honors OFF', () async {
    Future<ProcessResult> write(List<String> patterns) => run(
      WindowsBrowserBypassCloserService.buildOwnedBlocklistScript(
        root,
        patterns,
        journalPath: journal,
        policyRoots: [root],
        offMarkerPath: p.join(temp.path, 'off.json'),
      ),
    );
    expect((await write(['blocked.example'])).exitCode, 0);
    expect(
      (await read()).values,
      containsAll(['existing.example', 'shared.example', 'blocked.example']),
    );
    expect((await write(['changed.example'])).exitCode, 0);
    expect((await read()).values, isNot(contains('blocked.example')));
    await File(p.join(temp.path, 'off.json')).writeAsString('{}');
    final before = await read();
    expect((await write(['must-not-appear.example'])).exitCode, 0);
    expect(await read(), before);
    expect((await run('Restore-FFOwnedLists')).exitCode, 0);
    expect(
      (await read()).values,
      unorderedEquals(['existing.example', 'shared.example']),
    );
  }, skip: !Platform.isWindows);

  test(
    'list update and OFF preserve preexisting entries and deduplicate rules',
    () async {
      for (final body in <String>[
        "Set-FFOwnedList ${q('$root\\URLBlocklist')} @('blocked.example','shared.example')",
        "Set-FFOwnedList ${q('$root\\URLBlocklist')} @('changed.example')",
      ]) {
        final result = await run(body);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final state = await read();
        final journalState = jsonDecode(await File(journal).readAsString());
        expect(
          journalState['entries'].first['key'],
          startsWith(r'Registry::HKEY_USERS\S-1-5-'),
        );
        expect(state['1'], 'existing.example');
        expect(state['5'], 'shared.example');
        expect(state, hasLength(3));
      }
      expect((await read()).values, contains('changed.example'));
      expect((await read()).values, isNot(contains('blocked.example')));
      expect((await run('Restore-FFOwnedLists')).exitCode, 0);
      expect(await read(), <String, dynamic>{
        '1': 'existing.example',
        '5': 'shared.example',
      });
      expect(
        jsonDecode(await File(journal).readAsString())['entries'],
        isEmpty,
      );
      expect((await run('Restore-FFOwnedLists')).exitCode, 0);
    },
    skip: !Platform.isWindows,
  );

  test(
    'elevated apply supports empty updates without deleting other policies',
    () async {
      expect(
        (await run('''
Set-ItemProperty -LiteralPath ${q(root)} -Name BuiltInDnsClientEnabled -Value 1 -Type DWord
Set-ItemProperty -LiteralPath ${q(root)} -Name DnsOverHttpsMode -Value 'automatic' -Type String
''')).exitCode,
        0,
      );
      for (final patterns in <List<String>>[
        <String>['selected.example'],
        <String>[],
      ]) {
        final script = ChromiumPolicyService.buildOwnedRegistryPolicyFragment(
          patterns,
          journalPath: journal,
          policyRoots: <String>[root],
          offMarkerPath: p.join(temp.path, 'off.json'),
        );
        final result = await run(script);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final state = await read();
        expect(state['1'], 'existing.example');
        expect(state['5'], 'shared.example');
        expect(state.values.contains('selected.example'), patterns.isNotEmpty);
      }
      final restored = await run(
        ChromiumPolicyService.elevatedRegistryPolicyRemoveFragment(
              journalPath: journal,
              policyRoots: [root],
              offMarkerPath: p.join(temp.path, 'off.json'),
            ) +
            '''
\$dns=Get-ItemProperty -LiteralPath ${q(root)}
if (\$dns.BuiltInDnsClientEnabled -ne 1 -or \$dns.DnsOverHttpsMode -ne 'automatic') { throw 'DNS baseline not restored' }
''',
      );
      expect(
        restored.exitCode,
        0,
        reason: '${restored.stdout}\n${restored.stderr}',
      );
      expect(
        (await read()).values,
        unorderedEquals(['existing.example', 'shared.example']),
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'elevated DNS OFF preserves a later administrator value and value kind',
    () async {
      final apply = ChromiumPolicyService.buildOwnedRegistryPolicyFragment(
        ['selected.example'],
        journalPath: journal,
        policyRoots: [root],
        offMarkerPath: p.join(temp.path, 'off.json'),
      );
      expect((await run(apply)).exitCode, 0);
      expect(
        (await run('''
Set-ItemProperty -LiteralPath ${q(root)} -Name BuiltInDnsClientEnabled -Value '0' -Type String
Set-ItemProperty -LiteralPath ${q(root)} -Name DnsOverHttpsMode -Value 'secure' -Type String
''')).exitCode,
        0,
      );
      final result = await run(
        ChromiumPolicyService.elevatedRegistryPolicyRemoveFragment(
              journalPath: journal,
              policyRoots: [root],
              offMarkerPath: p.join(temp.path, 'off.json'),
            ) +
            '''
\$key=Get-Item -LiteralPath ${q(root)}
if (\$key.GetValueKind('BuiltInDnsClientEnabled').ToString() -ne 'String') { throw 'Later kind erased' }
if (\$key.GetValue('DnsOverHttpsMode') -ne 'secure') { throw 'Later DNS value erased' }
''',
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
    },
    skip: !Platform.isWindows,
  );

  test('OFF marker prevents elevated DNS and URL policy mutation', () async {
    final marker = p.join(temp.path, 'off.json');
    await File(marker).writeAsString('off');
    final before = await read();
    final result = await run(
      ChromiumPolicyService.buildOwnedRegistryPolicyFragment(
        ['must-not-appear.example'],
        journalPath: journal,
        policyRoots: [root],
        offMarkerPath: marker,
      ),
    );
    expect(result.exitCode, isNot(0));
    expect(await read(), before);
    expect(await File('$journal.dns').exists(), false);
  }, skip: !Platform.isWindows);

  test(
    'OFF during elevated DNS write stops URL apply and remains reversible',
    () async {
      final marker = p.join(temp.path, 'off.json');
      final before = await read();
      final apply =
          ChromiumPolicyService.buildOwnedRegistryPolicyFragment(
            ['must-not-appear.example'],
            journalPath: journal,
            policyRoots: [root],
            offMarkerPath: marker,
          ).replaceFirst(
            '      Write-FFPacState \$spec.key \$spec.name \$entry.after',
            '      Write-FFPacState \$spec.key \$spec.name \$entry.after\n' +
                '[IO.File]::WriteAllText(${q(marker)},\'off\')',
          );
      expect((await run(apply)).exitCode, isNot(0));
      expect(await read(), before);
      final restored = await run(
        ChromiumPolicyService.elevatedRegistryPolicyRemoveFragment(
              journalPath: journal,
              policyRoots: [root],
              offMarkerPath: marker,
            ) +
            '''
\$key=Get-Item -LiteralPath ${q(root)}
if (\$key.GetValueNames() -contains 'BuiltInDnsClientEnabled' -or \$key.GetValueNames() -contains 'DnsOverHttpsMode') { throw 'Interrupted DNS override retained' }
''',
      );
      expect(restored.exitCode, 0, reason: '${restored.stderr}');
    },
    skip: !Platform.isWindows,
  );

  test(
    'DNS restoration is attempted even when the site ownership journal is corrupt',
    () async {
      expect(
        (await run('''
Set-ItemProperty -LiteralPath ${q(root)} -Name DnsOverHttpsMode -Value 'automatic' -Type String
''')).exitCode,
        0,
      );
      expect(
        (await run(
          ChromiumPolicyService.buildOwnedRegistryPolicyFragment(
            ['selected.example'],
            journalPath: journal,
            policyRoots: [root],
            offMarkerPath: p.join(temp.path, 'off.json'),
          ),
        )).exitCode,
        0,
      );
      await File(journal).writeAsString('{broken');
      final result = await run(
        ChromiumPolicyService.elevatedRegistryPolicyRemoveFragment(
          journalPath: journal,
          policyRoots: [root],
          offMarkerPath: p.join(temp.path, 'off.json'),
        ),
      );
      expect(result.exitCode, isNot(0));
      final checked = await run('''
\$value=(Get-ItemProperty -LiteralPath ${q(root)}).DnsOverHttpsMode
if (\$value -ne 'automatic') { throw 'DNS restoration was skipped' }
''');
      expect(checked.exitCode, 0, reason: '${checked.stderr}');
      expect(
        jsonDecode(await File('$journal.dns').readAsString())['entries'],
        isEmpty,
      );
    },
    skip: !Platform.isWindows,
  );

  test('OFF preserves a later edit to an owned slot', () async {
    expect(
      (await run(
        "Set-FFOwnedList ${q('$root\\URLBlocklist')} @('blocked.example')",
      )).exitCode,
      0,
    );
    final state = await read();
    final slot = state.entries
        .firstWhere((e) => e.value == 'blocked.example')
        .key;
    expect(
      (await run(
        "Set-ItemProperty -LiteralPath ${q('$root\\URLBlocklist')} -Name ${q(slot)} -Value 'admin-edit.example' -Type String\nRestore-FFOwnedLists",
      )).exitCode,
      0,
    );
    expect((await read())[slot], 'admin-edit.example');
    expect((await read())['1'], 'existing.example');
  }, skip: !Platform.isWindows);

  test(
    'OFF preserves a changed registry value kind and concurrent writes fail safely',
    () async {
      final key = '$root\\URLBlocklist';
      final locked = await run('''
\$held = Open-FFOwnedListsLock
try { Set-FFOwnedList ${q(key)} @('blocked.example') } finally { \$held.Dispose() }
''');
      expect(locked.exitCode, isNot(0));
      expect(await read(), <String, dynamic>{
        '1': 'existing.example',
        '5': 'shared.example',
      });
      expect(
        (await run("Set-FFOwnedList ${q(key)} @('blocked.example')")).exitCode,
        0,
      );
      final state = await read();
      final slot = state.entries
          .firstWhere((entry) => entry.value == 'blocked.example')
          .key;
      expect(
        (await run('''
Set-ItemProperty -LiteralPath ${q(key)} -Name ${q(slot)} -Value 'blocked.example' -Type ExpandString
Restore-FFOwnedLists
''')).exitCode,
        0,
      );
      expect((await read())[slot], 'blocked.example');
    },
    skip: !Platform.isWindows,
  );

  test(
    'interrupted mutation can be restored and unscoped records are rejected',
    () async {
      final key = '$root\\URLBlocklist';
      await File(journal).writeAsString(
        jsonEncode(<String, dynamic>{
          'schema': 1,
          'entries': <Object>[
            <String, String>{
              'key': key,
              'name': '2',
              'value': 'old-owned.example',
            },
            <String, String>{
              'key': key,
              'name': '2',
              'value': 'new-owned.example',
            },
          ],
        }),
      );
      expect(
        (await run(
          "Set-ItemProperty -LiteralPath ${q(key)} -Name '2' -Value 'new-owned.example' -Type String\nRestore-FFOwnedLists",
        )).exitCode,
        0,
      );
      expect(await read(), <String, dynamic>{
        '1': 'existing.example',
        '5': 'shared.example',
      });
      await File(journal).writeAsString(
        jsonEncode(<String, dynamic>{
          'schema': 1,
          'entries': <Object>[
            <String, String>{
              'key': '$root\\Unrelated',
              'name': '1',
              'value': 'do-not-touch',
            },
          ],
        }),
      );
      expect((await run('Restore-FFOwnedLists')).exitCode, isNot(0));
      expect((await read())['1'], 'existing.example');
    },
    skip: !Platform.isWindows,
  );
}
