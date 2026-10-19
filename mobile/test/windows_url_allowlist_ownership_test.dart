import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:six_clean_room/services/mac_system_block_service.dart';
import 'package:six_clean_room/services/windows_browser_bypass_closer_service.dart';
import 'package:six_clean_room/services/windows_url_allowlist_ownership_service.dart';

String q(String value) => "'${value.replaceAll("'", "''")}'";

void main() {
  test(
    'conflicting allowlist entries are journaled and restored reversibly',
    () async {
      if (!Platform.isWindows) return;
      final Directory temp = await Directory.systemTemp.createTemp(
        'ff-allowlist-test-',
      );
      final String root =
          r'HKCU:\Software\FocusFenseAllowlistTest\' +
          DateTime.now().microsecondsSinceEpoch.toString();
      final String key = '$root\\URLAllowlist';
      final String journal = p.join(temp.path, 'journal.json');
      final String off = p.join(temp.path, 'off.json');
      Future<ProcessResult> run(String body) async {
        final File file = File(p.join(temp.path, 'run.ps1'));
        await file.writeAsString("\$ErrorActionPreference='Stop'\n$body");
        return Process.run(
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
          <String>['-NoProfile', '-NonInteractive', '-File', file.path],
        );
      }

      try {
        final ProcessResult setup = await run('''
New-Item -Path ${q(key)} -Force | Out-Null
New-ItemProperty -LiteralPath ${q(key)} -Name '1' -Value '*://youtube.com/*' -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath ${q(key)} -Name '5' -Value '*://www.youtube.com/watch/*' -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath ${q(key)} -Name '2' -Value '*://example.net/*' -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath ${q(key)} -Name '3' -Value '*://mail.google.com/*' -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath ${q(key)} -Name '4' -Value '*' -PropertyType String -Force | Out-Null
''');
        expect(setup.exitCode, 0, reason: '${setup.stdout}\n${setup.stderr}');

        final String remove =
            WindowsUrlAllowlistOwnershipService.buildRemoveScript(
              blockedHosts: <String>['youtube.com', 'google.com'],
              roots: <String>[root],
              allRootsForTesting: <String>[root],
              journal: journal,
              offMarker: off,
            );
        final ProcessResult removed = await run(remove);
        expect(
          removed.exitCode,
          0,
          reason: '${removed.stdout}\n${removed.stderr}',
        );
        expect('${removed.stdout}', contains('allowlist_removed=2'));
        expect(File(journal).existsSync(), isTrue);

        // A later administrator edit to the other owned slot must survive OFF.
        final ProcessResult edit = await run('''
New-ItemProperty -LiteralPath ${q(key)} -Name '1' -Value '*://changed.example/*' -PropertyType String -Force | Out-Null
''');
        expect(edit.exitCode, 0, reason: '${edit.stdout}\n${edit.stderr}');
        final String restore =
            WindowsUrlAllowlistOwnershipService.buildRestoreScript(
              roots: <String>[root],
              allRootsForTesting: <String>[root],
              journal: journal,
            );
        final ProcessResult restored = await run(restore);
        expect(
          restored.exitCode,
          0,
          reason: '${restored.stdout}\n${restored.stderr}',
        );
        final ProcessResult verify = await run('''
\$item=Get-Item -LiteralPath ${q(key)}
if (\$item.GetValue('1') -cne '*://changed.example/*') { throw 'later administrator edit overwritten' }
if (\$item.GetValue('5') -cne '*://www.youtube.com/watch/*') { throw 'original conflicting exception not restored' }
if (\$item.GetValue('2') -cne '*://example.net/*') { throw 'unrelated allowlist entry lost' }
if (\$item.GetValue('3') -cne '*://mail.google.com/*') { throw 'managed Gmail allowlist lost' }
if (\$item.GetValue('4') -cne '*') { throw 'generic allowlist changed' }
if ((Get-Content -LiteralPath ${q(journal)} -Raw | ConvertFrom-Json).entries.Count -ne 0) { throw 'ownership journal not cleared' }
''');
        expect(
          verify.exitCode,
          0,
          reason: '${verify.stdout}\n${verify.stderr}',
        );
      } finally {
        await run(
          'Remove-Item -LiteralPath ${q(root)} -Recurse -Force -ErrorAction SilentlyContinue',
        );
        await temp.delete(recursive: true);
      }
    },
  );

  test('host policy canonicalization removes a terminal DNS root dot', () {
    expect(
      MacSystemBlockService.canonicalHost('https://youtube.com./watch'),
      'youtube.com',
    );
  });

  test('allowlist conflict parsing includes bare Chromium host filters', () {
    expect(
      WindowsBrowserBypassCloserService.blockedHostsFromPatterns(<String>[
        'youtube.com',
        '*://*.xn--example.com/watch?v=1',
        'https://www.blocked.test/path',
        '*.*/*',
      ]),
      <String>{'youtube.com', 'xn--example.com', 'blocked.test'},
    );
  });

  test('OFF marker prevents allowlist changes', () async {
    if (!Platform.isWindows) return;
    final Directory temp = await Directory.systemTemp.createTemp(
      'ff-allowlist-off-',
    );
    final String root =
        r'HKCU:\Software\FocusFenseAllowlistOffTest\' +
        DateTime.now().microsecondsSinceEpoch.toString();
    final String key = '$root\\URLAllowlist';
    final String journal = p.join(temp.path, 'journal.json');
    final String off = p.join(temp.path, 'off.json');
    final File file = File(p.join(temp.path, 'run.ps1'));
    Future<ProcessResult> run(String body) async {
      await file.writeAsString("\$ErrorActionPreference='Stop'\n$body");
      return Process.run(
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        <String>['-NoProfile', '-NonInteractive', '-File', file.path],
      );
    }

    try {
      await File(off).writeAsString('off');
      final ProcessResult result = await run('''
New-Item -Path ${q(key)} -Force | Out-Null
New-ItemProperty -LiteralPath ${q(key)} -Name '1' -Value '*://youtube.com/*' -PropertyType String -Force | Out-Null
${WindowsUrlAllowlistOwnershipService.buildRemoveScript(blockedHosts: <String>['youtube.com'], roots: <String>[root], allRootsForTesting: <String>[root], journal: journal, offMarker: off)}
''');
      expect(result.exitCode, isNot(0));
      final ProcessResult verify = await run('''
if ((Get-Item -LiteralPath ${q(key)}).GetValue('1') -cne '*://youtube.com/*') { throw 'OFF changed allowlist' }
if (Test-Path -LiteralPath ${q(journal)}) { throw 'OFF wrote journal' }
''');
      expect(verify.exitCode, 0, reason: '${verify.stdout}\n${verify.stderr}');
    } finally {
      await run(
        'Remove-Item -LiteralPath ${q(root)} -Recurse -Force -ErrorAction SilentlyContinue',
      );
      await temp.delete(recursive: true);
    }
  });
}
