import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:six_clean_room/services/chrome_extension_identity.dart';
import 'package:six_clean_room/services/extension_guard_prefs.dart';
import 'package:six_clean_room/services/firefox_xpi_packager.dart';
import 'package:six_clean_room/services/windows_extension_guard_service.dart';
import 'package:six_clean_room/enforcement/layers/browser_policy_layer.dart';

String _quote(String text) => "'${text.replaceAll("'", "''")}'";

String _isolateGuard(String script, String registry) => script
    .replaceAll(r'HKLM:\SOFTWARE', '__MACHINE__')
    .replaceAll(r'HKCU:\SOFTWARE', '__USER__')
    .replaceAll('__MACHINE__', '$registry\\Machine\\SOFTWARE')
    .replaceAll('__USER__', '$registry\\User\\SOFTWARE')
    .replaceAll(r"$root -like 'HKLM:*'", "\$root -like '$registry\\Machine*'");

Future<ProcessResult> _run(File file) => Process.run(
  r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
  <String>['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file.path],
);

void main() {
  late Directory temp;
  late ExtensionGuardPrefs prefs;
  late String registry;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ff-managed-extensions-');
    prefs = ExtensionGuardPrefs.forTesting(
      Directory(p.join(temp.path, 'state')),
    );
    registry =
        'HKCU:\\Software\\FocusFenseManagedTest\\${DateTime.now().microsecondsSinceEpoch}';
  });
  tearDown(() async {
    if (Platform.isWindows) {
      final File cleanup = File(p.join(temp.path, 'cleanup.ps1'));
      await cleanup.writeAsString(
        'Remove-Item -LiteralPath ${_quote(registry)} -Recurse -Force -ErrorAction SilentlyContinue',
      );
      await _run(cleanup);
    }
    await temp.delete(recursive: true);
  });

  test(
    'browser choices persist independently after restarting the preferences',
    () async {
      await prefs.setBrowserEnabled('chrome', false);
      await prefs.setBrowserEnabled('firefox', false);
      final ExtensionGuardPrefs restarted = ExtensionGuardPrefs.forTesting(
        Directory(p.join(temp.path, 'state')),
      );
      expect(restarted.isBrowserExplicitlyDisabled('chrome'), isTrue);
      expect(restarted.isBrowserExplicitlyDisabled('firefox'), isTrue);
      expect(restarted.isBrowserExplicitlyDisabled('edge'), isFalse);
      await restarted.setBrowserEnabled('chrome', true);
      expect(prefs.isBrowserExplicitlyDisabled('chrome'), isFalse);
      expect(prefs.isBrowserExplicitlyDisabled('firefox'), isTrue);
      await prefs.setBrowserEnabled('edge', false);
      expect(
        prefs.isRegistryRootExplicitlyDisabled(
          r'HKCU\Software\Policies\Microsoft\EdgeBeta',
        ),
        isTrue,
      );
      await prefs.setBrowserEnabled('aside', false);
      expect(
        prefs.isRegistryRootExplicitlyDisabled(
          r'HKLM\Software\Chromium\Extensions',
        ),
        isTrue,
      );
      await prefs.setBrowserEnabled('chrome', false);
      const ExtensionPolicyVerifyResult missing = ExtensionPolicyVerifyResult(
        registryOk: false,
        policyHklmOk: false,
        forcelistOk: false,
        chromeForcelistOk: false,
        edgeForcelistOk: false,
        chromeHkcuForcelistOk: false,
        edgeHkcuForcelistOk: false,
        chromeHkcuPolicyOk: false,
        edgeHkcuPolicyOk: false,
        chromeUserInstallOk: false,
        edgeUserInstallOk: false,
        chromeHklmInstallOk: false,
        edgeHklmInstallOk: false,
        chromeLoadExtensionFallbackOk: false,
        chromeInstallOk: false,
        edgeInstallOk: false,
        firefoxPolicyOk: false,
        asideRequired: true,
        programDataPath: null,
        detail: 'test',
      );
      expect(missing.requestedStateSatisfied(preferences: prefs), isTrue);
      expect(missing.protectionOk, isFalse);
      await prefs.setBrowserEnabled('edge', true);
      expect(missing.requestedStateSatisfied(preferences: prefs), isFalse);
      expect(
        () => prefs.browserDisabledMarkerPath('../escape'),
        throwsArgumentError,
      );
    },
  );

  for (final selected in <List<String>>[
    ['aside'],
    ['aside', 'firefox'],
  ]) {
    test(
      'selective OFF $selected retains other browser policy ownership',
      () async {
        final roots = <String, String>{
          for (final browser in ['chrome', 'aside', 'firefox'])
            browser: '$registry\\$browser',
        };
        final journal = p.join(temp.path, 'selective-owned.json');
        String listKey(String browser) =>
            '${roots[browser]}\\${browser == 'firefox' ? r'WebsiteFilter\Block' : 'URLBlocklist'}';
        final seed = File(p.join(temp.path, 'selective-seed.ps1'));
        await seed.writeAsString('''
\$ErrorActionPreference='Stop'
${BrowserPolicyLayer.ownedListsPowerShell(journalPath: journal, policyRoots: roots.values.toList())}
${roots.entries.map((entry) => '''
New-Item -Path ${_quote(listKey(entry.key))} -Force | Out-Null
Set-ItemProperty -LiteralPath ${_quote(listKey(entry.key))} -Name '2' -Value 'unrelated.example' -Type String
Set-FFOwnedList ${_quote(listKey(entry.key))} @('${entry.key}.example')
''').join('\n')}
''');
        final seeded = await _run(seed);
        expect(seeded.exitCode, 0, reason: '${seeded.stderr}');
        final script = File(p.join(temp.path, 'selective-off.ps1'));
        await script.writeAsString(
          WindowsExtensionGuardService.disableBrowserExtensionsScript(
            browserIds: selected,
            resultPath: p.join(temp.path, 'selective.exit'),
            registryRoots: {
              for (final browser in selected) browser: [roots[browser]!],
            },
            ownedListsJournalPath: journal,
            ownedPolicyRootsForTesting: roots.values.toList(),
          ),
        );
        final result = await _run(script);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final remaining =
            jsonDecode(await File(journal).readAsString())['entries'] as List;
        expect(remaining.length, roots.length - selected.length);
        for (final browser in roots.keys) {
          await seed.writeAsString('''
\$settings=Get-ItemProperty -LiteralPath ${_quote(listKey(browser))}
if (\$settings.'2' -ne 'unrelated.example') { exit 1 }
if (${selected.contains(browser) ? "\$null -ne \$settings.PSObject.Properties['1']" : "\$settings.'1' -ne '$browser.example'"}) { exit 2 }
exit 0
''');
          expect((await _run(seed)).exitCode, 0, reason: browser);
        }
      },
      skip: !Platform.isWindows,
    );
  }

  for (final bool failChrome in <bool>[false, true]) {
    test('group OFF attempts all browsers; failure=$failChrome', () async {
      final String resultPath = p.join(temp.path, 'group.exit');
      // A stale success must not mask a failed browser in a subsequent run.
      await File('$resultPath.chrome').writeAsString('0');
      final Map<String, List<String>> roots = <String, List<String>>{
        for (final String browser in ExtensionGuardPrefs.managedBrowserIds)
          browser: <String>[
            browser == 'chrome' && failChrome
                ? r'NonexistentRegistryProvider:\failure'
                : '$registry\\$browser',
          ],
      };
      final File script = File(p.join(temp.path, 'group.ps1'));
      final String siteRoot = '$registry\\sitePolicy';
      final String ownedJournal = p.join(temp.path, 'owned-sites.json');
      final File seed = File(p.join(temp.path, 'owned-seed.ps1'));
      await seed.writeAsString('''
New-Item -Path ${_quote('$siteRoot\\URLBlocklist')} -Force | Out-Null
Set-ItemProperty -LiteralPath ${_quote('$siteRoot\\URLBlocklist')} -Name '1' -Value 'own.example' -Type String
Set-ItemProperty -LiteralPath ${_quote('$siteRoot\\URLBlocklist')} -Name '2' -Value 'other.example' -Type String
''');
      expect((await _run(seed)).exitCode, 0);
      await File(ownedJournal).writeAsString(
        jsonEncode(<String, dynamic>{
          'schema': 1,
          'entries': <Object>[
            <String, String>{
              'key': '$siteRoot\\URLBlocklist',
              'name': '1',
              'value': 'own.example',
            },
          ],
        }),
      );
      await script.writeAsString(
        WindowsExtensionGuardService.disableBrowserExtensionsScript(
          browserIds: ExtensionGuardPrefs.managedBrowserIds,
          resultPath: resultPath,
          registryRoots: roots,
          ownedListsJournalPath: ownedJournal,
          ownedPolicyRootsForTesting: <String>[siteRoot],
        ),
      );
      final ProcessResult result = await _run(script);
      expect(
        jsonDecode(await File(ownedJournal).readAsString())['entries'],
        isEmpty,
      );
      await seed.writeAsString('''
\$values=Get-ItemProperty -LiteralPath ${_quote('$siteRoot\\URLBlocklist')}
if (\$null -ne \$values.PSObject.Properties['1'] -or \$values.'2' -ne 'other.example') { exit 1 }
exit 0
''');
      expect((await _run(seed)).exitCode, 0);
      expect(
        result.exitCode,
        failChrome ? 1 : 0,
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(
        (await File(resultPath).readAsString()).trim(),
        failChrome ? '1' : '0',
      );
      for (final String browser in ExtensionGuardPrefs.managedBrowserIds) {
        expect(
          (await File('$resultPath.$browser').readAsString()).trim(),
          failChrome && browser == 'chrome' ? '1' : '0',
        );
      }
      if (failChrome) {
        expect(
          (await File('$resultPath.error').readAsString()).trim(),
          'chrome',
        );
      }
    }, skip: !Platform.isWindows);
  }

  for (final String browser in ExtensionGuardPrefs.managedBrowserIds) {
    test(
      '$browser removal preserves other extensions and website policies',
      () async {
        final String id = browser == 'firefox'
            ? kFirefoxExtensionId
            : ChromeExtensionIdentity.extensionId;
        final File policyFile = File(p.join(temp.path, 'policies.json'));
        final Map<String, dynamic> original = <String, dynamic>{
          'policies': <String, dynamic>{
            'WebsiteFilter': <String, dynamic>{
              'Block': <String>['*://blocked.example/*'],
            },
            'ExtensionSettings': <String, dynamic>{
              'other@test': <String, dynamic>{'installation_mode': 'allowed'},
              id: <String, dynamic>{'installation_mode': 'force_installed'},
              if (browser != 'firefox')
                ChromeExtensionIdentity.legacyExtensionId: <String, dynamic>{
                  'installation_mode': 'force_installed',
                },
            },
            'Extensions': <String, dynamic>{
              'Install': <String>[
                'https://other.example/addon.xpi',
                'file:///C:/test/${FirefoxXpiPackager.kXpiFileName}',
              ],
              'Locked': <String>['other@test', id],
            },
          },
        };
        await policyFile.writeAsString(jsonEncode(original));
        final File seed = File(p.join(temp.path, 'seed.ps1'));
        await seed.writeAsString('''
\$ErrorActionPreference='Stop'
\$root=${_quote(registry)}
New-Item -Path \$root -Force | Out-Null
Set-ItemProperty -Path \$root -Name ExtensionSettings -Value ${_quote(jsonEncode(original['policies']['ExtensionSettings']))} -Type String
foreach(\$name in @('URLBlocklist','ExtensionInstallForcelist','Extensions\\Install','Extensions\\Locked')) { New-Item -Path (Join-Path \$root \$name) -Force | Out-Null }
Set-ItemProperty -Path (Join-Path \$root 'URLBlocklist') -Name '1' -Value '*://blocked.example/*' -Type String
Set-ItemProperty -Path (Join-Path \$root 'ExtensionInstallForcelist') -Name '1' -Value 'other-extension;https://other.example/update.xml' -Type String
Set-ItemProperty -Path (Join-Path \$root 'ExtensionInstallForcelist') -Name '2' -Value '$id;file:///C:/own.xml' -Type String
${browser == 'firefox' ? '' : "Set-ItemProperty -Path (Join-Path \$root 'ExtensionInstallForcelist') -Name '3' -Value '${ChromeExtensionIdentity.legacyExtensionId};file:///legacy.xml' -Type String"}
Set-ItemProperty -Path (Join-Path \$root 'Extensions\\Install') -Name '1' -Value 'https://other.example/addon.xpi' -Type String
Set-ItemProperty -Path (Join-Path \$root 'Extensions\\Install') -Name '2' -Value 'file:///C:/test/${FirefoxXpiPackager.kXpiFileName}' -Type String
Set-ItemProperty -Path (Join-Path \$root 'Extensions\\Locked') -Name '1' -Value 'other@test' -Type String
Set-ItemProperty -Path (Join-Path \$root 'Extensions\\Locked') -Name '2' -Value '$id' -Type String
''');
        expect((await _run(seed)).exitCode, 0);
        final File disable = File(p.join(temp.path, 'disable.ps1'));
        await disable.writeAsString(
          WindowsExtensionGuardService.disableBrowserExtensionScript(
            browserId: browser,
            resultPath: p.join(temp.path, 'disable.exit'),
            registryRoots: <String>[registry],
            firefoxPolicyFiles: browser == 'firefox'
                ? <String>[policyFile.path]
                : <String>[],
          ),
        );
        final ProcessResult result = await _run(disable);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final File read = File(p.join(temp.path, 'read.ps1'));
        await read.writeAsString('''
\$root=${_quote(registry)}
function Values(\$path) { @((Get-ItemProperty -LiteralPath \$path).PSObject.Properties | Where-Object {\$_.Name -match '^\\d+\$'} | ForEach-Object {\$_.Value}) }
@{settings=(((Get-ItemProperty \$root).ExtensionSettings -join '')|ConvertFrom-Json); block=@(Values (Join-Path \$root 'URLBlocklist')); force=@(Values (Join-Path \$root 'ExtensionInstallForcelist')); install=@(Values (Join-Path \$root 'Extensions\\Install')); locked=@(Values (Join-Path \$root 'Extensions\\Locked'))}|ConvertTo-Json -Depth 30 -Compress
''');
        final Map<String, dynamic> state =
            jsonDecode('${(await _run(read)).stdout}'.trim())
                as Map<String, dynamic>;
        expect(
          state['settings'][id]['installation_mode'],
          browser == 'firefox' ? 'blocked' : 'removed',
        );
        expect(state['settings']['other@test']['installation_mode'], 'allowed');
        expect(state['block'], <String>['*://blocked.example/*']);
        if (browser == 'firefox') {
          expect(state['install'], <String>['https://other.example/addon.xpi']);
          expect(state['locked'], <String>['other@test']);
          final dynamic document = jsonDecode(await policyFile.readAsString());
          expect(
            document['policies']['WebsiteFilter'],
            original['policies']['WebsiteFilter'],
          );
          expect(
            document['policies']['ExtensionSettings'][id]['installation_mode'],
            'blocked',
          );
          expect(document['policies']['Extensions']['Install'], <String>[
            'https://other.example/addon.xpi',
          ]);
        } else {
          expect(
            state['settings'][ChromeExtensionIdentity
                .legacyExtensionId]['installation_mode'],
            'removed',
          );
          expect(state['force'], <String>[
            'other-extension;https://other.example/update.xml',
          ]);
        }
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'elevated guard respects late disable and never repacks a signed Firefox XPI',
    () async {
      final Directory chrome = await Directory(
        p.join(temp.path, 'source', 'chrome_blocker'),
      ).create(recursive: true);
      final Directory firefox = await Directory(
        p.join(temp.path, 'source', 'firefox_blocker'),
      ).create(recursive: true);
      await File(
        p.join(chrome.path, 'manifest.json'),
      ).writeAsString('{"version":"1.0.21"}');
      await File(p.join(firefox.path, 'manifest.json')).writeAsString('{}');
      final File xpi = await File(
        'assets/browser_extensions/firefox/sixvpn_blocker_signed.xpi',
      ).copy(p.join(temp.path, 'signed.xpi'));
      final String originalHash = sha256
          .convert(await xpi.readAsBytes())
          .toString();
      final String programData = p.join(temp.path, 'programdata');
      final String roaming = p.join(temp.path, 'roaming');
      final String programFiles = p.join(temp.path, 'programfiles');
      final Directory profile = await Directory(
        p.join(roaming, 'Mozilla', 'Firefox', 'Profiles', 'test'),
      ).create(recursive: true);
      final File policies = File(
        p.join(
          programFiles,
          'Mozilla Firefox',
          'distribution',
          'policies.json',
        ),
      );
      await policies.parent.create(recursive: true);
      final Map<String, dynamic> before = <String, dynamic>{
        'policies': <String, dynamic>{
          'WebsiteFilter': <String, dynamic>{
            'Block': <String>['*://keep.example/*'],
          },
          'ExtensionSettings': <String, dynamic>{
            'other@test': <String, dynamic>{'installation_mode': 'allowed'},
          },
          'Extensions': <String, dynamic>{
            'Install': <String>['https://other.example/addon.xpi'],
            'Locked': <String>['other@test'],
          },
        },
      };
      await policies.writeAsString(jsonEncode(before));
      final String xpiUrl = 'file:///${xpi.path.replaceAll(r'\', '/')}';
      final String policyJson =
          WindowsExtensionGuardService.buildFirefoxGuardPolicyJson(
            installSourcesParent: firefox.parent.path,
            xpiInstallUrl: xpiUrl,
          );
      String script = WindowsExtensionGuardService.elevatedGuardScript(
        chromeExtensionPath: chrome.path,
        firefoxExtensionPath: firefox.path,
        firefoxXpiPath: xpi.path,
        firefoxPolicyJson: policyJson,
        firefoxRegistryExtensionSettingsJson:
            WindowsExtensionGuardService.buildFirefoxRegistryExtensionSettingsJson(
              xpiInstallUrl: xpiUrl,
            ),
        onlyBrowserId: 'firefox',
        prefsForTesting: prefs,
      );
      script = _isolateGuard(script, registry);
      expect(script, isNot(contains(r'HKLM:\')));
      expect(script, isNot(contains(r'HKCU:\SOFTWARE')));
      final File guard = File(p.join(temp.path, 'guard.ps1'));
      await guard.writeAsString('''
\$env:ProgramData=${_quote(programData)}
\$env:APPDATA=${_quote(roaming)}
\$env:ProgramFiles=${_quote(programFiles)}
\${env:ProgramFiles(x86)}=${_quote(p.join(temp.path, 'programfiles86'))}
$script''');
      // The script was already generated: its runtime check must see this change.
      await prefs.setBrowserEnabled('firefox', false);
      final ProcessResult disabled = await _run(guard);
      expect(
        disabled.exitCode,
        1,
        reason: '${disabled.stdout}\n${disabled.stderr}',
      );
      expect(
        await File(
          p.join(profile.path, 'extensions', FirefoxXpiPackager.kXpiFileName),
        ).exists(),
        isFalse,
      );
      expect(jsonDecode(await policies.readAsString()), before);
      expect(sha256.convert(await xpi.readAsBytes()).toString(), originalHash);
      await prefs.setBrowserEnabled('firefox', true);
      final ProcessResult enabled = await _run(guard);
      expect(
        enabled.exitCode,
        0,
        reason: '${enabled.stdout}\n${enabled.stderr}',
      );
      expect(sha256.convert(await xpi.readAsBytes()).toString(), originalHash);
      final File installed = File(
        p.join(profile.path, 'extensions', FirefoxXpiPackager.kXpiFileName),
      );
      expect(
        sha256.convert(await installed.readAsBytes()).toString(),
        originalHash,
      );
      final dynamic after = jsonDecode(await policies.readAsString());
      expect(
        after['policies']['WebsiteFilter'],
        before['policies']['WebsiteFilter'],
      );
      expect(
        after['policies']['ExtensionSettings']['other@test']['installation_mode'],
        'allowed',
      );
      expect(
        after['policies']['ExtensionSettings'][kFirefoxExtensionId]['installation_mode'],
        'force_installed',
      );
      expect(
        after['policies']['Extensions']['Install'],
        contains('https://other.example/addon.xpi'),
      );
      expect(after['policies']['Extensions']['Locked'], contains('other@test'));

      // The CRX bytes are only a file-copy fixture here; no browser is launched.
      await File(
        '${chrome.path}.crx',
      ).writeAsBytes(<int>[67, 114, 50, 52, 3, 0, 0, 0]);
      final String chromeRoot =
          '$registry\\Machine\\SOFTWARE\\Policies\\Google\\Chrome';
      final File seedChrome = File(p.join(temp.path, 'seed-chrome.ps1'));
      await seedChrome.writeAsString('''
\$root=${_quote(chromeRoot)}
New-Item -Path (Join-Path \$root 'ExtensionInstallForcelist') -Force | Out-Null
Set-ItemProperty -Path \$root -Name ExtensionSettings -Value '{"other-extension":{"installation_mode":"allowed"}}' -Type String
Set-ItemProperty -Path (Join-Path \$root 'ExtensionInstallForcelist') -Name '1' -Value 'other-extension;https://other.example/update.xml' -Type String
Set-ItemProperty -Path (Join-Path \$root 'ExtensionInstallForcelist') -Name '2' -Value '${ChromeExtensionIdentity.extensionId};file:///old.xml' -Type String
Set-ItemProperty -Path (Join-Path \$root 'ExtensionInstallForcelist') -Name '5' -Value '${ChromeExtensionIdentity.extensionId};file:///older.xml' -Type String
Set-ItemProperty -Path (Join-Path \$root 'ExtensionInstallForcelist') -Name '6' -Value '${ChromeExtensionIdentity.legacyExtensionId};file:///legacy.xml' -Type String
''');
      expect((await _run(seedChrome)).exitCode, 0);
      final String chromeScript = _isolateGuard(
        WindowsExtensionGuardService.elevatedGuardScript(
          chromeExtensionPath: chrome.path,
          firefoxExtensionPath: firefox.path,
          firefoxXpiPath: xpi.path,
          firefoxPolicyJson: policyJson,
          firefoxRegistryExtensionSettingsJson:
              WindowsExtensionGuardService.buildFirefoxRegistryExtensionSettingsJson(
                xpiInstallUrl: xpiUrl,
              ),
          onlyBrowserId: 'chrome',
          prefsForTesting: prefs,
        ),
        registry,
      );
      expect(chromeScript, isNot(contains(r'HKLM:\')));
      final String previousScript = await guard.readAsString();
      final String environment = previousScript.substring(
        0,
        previousScript.indexOf(r'$ErrorActionPreference'),
      );
      await guard.writeAsString(environment + chromeScript);
      for (int attempt = 0; attempt < 2; attempt++) {
        final ProcessResult applied = await _run(guard);
        expect(
          applied.exitCode,
          0,
          reason: '${applied.stdout}\n${applied.stderr}',
        );
      }
      final File readChrome = File(p.join(temp.path, 'read-chrome.ps1'));
      await readChrome.writeAsString('''
\$root=${_quote(chromeRoot)}
@{settings=((Get-ItemProperty \$root).ExtensionSettings|ConvertFrom-Json);force=@((Get-ItemProperty (Join-Path \$root 'ExtensionInstallForcelist')).PSObject.Properties|Where-Object {\$_.Name -match '^\\d+\$'}|ForEach-Object {\$_.Value})}|ConvertTo-Json -Depth 20 -Compress
''');
      final dynamic chromeState = jsonDecode(
        '${(await _run(readChrome)).stdout}'.trim(),
      );
      expect(
        chromeState['settings']['other-extension']['installation_mode'],
        'allowed',
      );
      expect(chromeState['force'], hasLength(3));
      expect(
        chromeState['settings'][ChromeExtensionIdentity
            .legacyExtensionId]['installation_mode'],
        'removed',
      );
      expect(
        (chromeState['force'] as List).any(
          (value) =>
              '$value'.contains(ChromeExtensionIdentity.legacyExtensionId),
        ),
        isFalse,
      );
      expect(
        chromeState['force'],
        contains('other-extension;https://other.example/update.xml'),
      );
      final List own = (chromeState['force'] as List)
          .where(
            (dynamic value) =>
                '$value'.startsWith('${ChromeExtensionIdentity.extensionId};'),
          )
          .toList();
      expect(own, hasLength(2));
      expect(
        own.toSet(),
        hasLength(1),
        reason: 'Every duplicate registration must use the current update URL',
      );
      final String updateXml = await File(
        p.join(programData, 'SixVPNBlocker', 'chrome_blocker', 'updates.xml'),
      ).readAsString();
      expect(updateXml, contains("version='1.0.21'"));
      expect(
        jsonDecode(await policies.readAsString()),
        after,
        reason: 'Chrome-only install must not modify Firefox policies',
      );
    },
    skip: !Platform.isWindows,
  );
}
