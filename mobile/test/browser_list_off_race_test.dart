import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/enforcement/layers/browser_policy_layer.dart';

void main() {
  for (final timing in ['before', 'intent', 'write', 'browser_marker']) {
    test('URL list OFF at $timing removes only owned entries', () async {
      final temp = await Directory.systemTemp.createTemp('ff-list-off-');
      final root =
          'HKCU:\\Software\\FocusFenseListRaceTest\\${DateTime.now().microsecondsSinceEpoch}'
          '${timing == 'browser_marker' ? r'\SOFTWARE\Policies\Chromium' : ''}';
      final marker =
          '${temp.path}\\${timing == 'browser_marker' ? 'extension_disabled_aside_v1.json' : 'off'}';
      String q(String s) => "'${s.replaceAll("'", "''")}'";
      final helper = BrowserPolicyLayer.ownedListsPowerShell(
        journalPath: '${temp.path}\\journal.json',
        policyRoots: [root, '$root\\Other'],
        stateDirectoryForTesting: temp.path,
      );
      final hook = timing == 'before' || timing == 'browser_marker'
          ? 'Set-Content -LiteralPath ${q(marker)} -Value off'
          : timing == 'intent'
          ? '''
\$originalSave=\${function:Write-FFOwnedLists}
function Write-FFOwnedLists(\$entries) {
 & \$originalSave \$entries
 if (@(\$entries | Where-Object { \$_.value -eq 'blocked.example' }).Count -gt 0) { Set-Content -LiteralPath ${q(marker)} -Value off }
}
'''
          : '''
function Set-ItemProperty {
 param([string]\$LiteralPath,[string]\$Name,\$Value,[string]\$Type,[string]\$ErrorAction)
 Microsoft.PowerShell.Management\\Set-ItemProperty -LiteralPath \$LiteralPath -Name \$Name -Value \$Value -Type \$Type -ErrorAction Stop
 if (\$Value -eq 'blocked.example') { Set-Content -LiteralPath ${q(marker)} -Value off }
}
''';
      final script = File('${temp.path}\\run.ps1');
      await script.writeAsString('''
\$ErrorActionPreference='Stop'
$helper
try {
New-Item -Path ${q('$root\\URLBlocklist')} -Force | Out-Null
Set-ItemProperty -LiteralPath ${q('$root\\URLBlocklist')} -Name 1 -Value foreign.example -Type String
Set-FFOwnedList -key ${q('$root\\Other\\URLBlocklist')} -patterns @('other.example')
$hook
\$cancelled=\$false
try { Set-FFOwnedList -key ${q('$root\\URLBlocklist')} -patterns @('blocked.example','late.example') ${timing == 'browser_marker' ? '' : '-offMarkers @(${q(marker)})'} }
catch { if (\$_.Exception.Message -notlike '*stopped by OFF*') { throw }; \$cancelled=\$true }
if (-not \$cancelled) { throw 'OFF was ignored' }
\$item=Get-Item -LiteralPath ${q('$root\\URLBlocklist')}
if (@(\$item.GetValueNames()).Count -ne 1 -or \$item.GetValue('1') -ne 'foreign.example') { throw 'wrong cleanup scope' }
if ((Get-Item -LiteralPath ${q('$root\\Other\\URLBlocklist')}).GetValue('1') -ne 'other.example') { throw 'other browser changed' }
\$entries=@(Read-FFOwnedLists)
if (\$entries.Count -ne 1 -or \$entries[0].value -ne 'other.example') { throw 'stale intent remains' }
} finally { Remove-Item -LiteralPath ${q(root)} -Recurse -Force -ErrorAction SilentlyContinue }
''');
      try {
        final result = await Process.run(
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
          ['-NoProfile', '-NonInteractive', '-File', script.path],
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        await temp.delete(recursive: true);
      }
    }, skip: !Platform.isWindows);
  }
}
