import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/data/browser_extension_asset_manifest.dart';
import 'package:six_clean_room/data/chromium_derivative_browsers.dart';
import 'package:six_clean_room/models/block_app.dart';
import 'package:six_clean_room/services/windows_extension_guard_service.dart';
import 'package:six_clean_room/services/chromium_derivative_extension_service.dart';

void main() {
  group('Aside AI Browser support', () {
    test('uses Chromium policy hive and the system install executable', () {
      final aside = chromiumDerivativeById('aside');
      expect(aside, isNotNull);
      expect(aside!.displayName, 'Aside AI Browser');
      expect(aside.policyRoot, r'SOFTWARE\Policies\Chromium');
      expect(
        aside.exeCandidates,
        contains(r'C:\Program Files\Aside\Application\Aside.exe'),
      );
      expect(aside.policyRootHklm, r'HKLM\SOFTWARE\Policies\Chromium');
      expect(
        BrowserExtensionAssetManifest.aside.first,
        'assets/browser_extensions/aside/manifest.json',
      );
      expect(
        BrowserExtensionAssetManifest.aside,
        contains('assets/browser_extensions/chrome/background.js'),
      );
      expect(
        BrowserExtensionAssetManifest.aside,
        isNot(BrowserExtensionAssetManifest.chrome),
      );
    });

    test('is recognized as a Chromium browser for process enforcement', () {
      expect(BlockApp.browserExes, contains('aside.exe'));
      expect(BlockApp.kKnownExeLabels['aside'], 'Aside AI Browser');
    });

    test(
      'admin installer copies a signed CRX before setting force-install policy',
      () {
        final script = WindowsExtensionGuardService.elevatedGuardScript(
          chromeExtensionPath:
              r'C:\Users\user\AppData\Local\FocusFense\chrome_blocker',
          firefoxExtensionPath:
              r'C:\Users\user\AppData\Local\FocusFense\firefox',
          firefoxXpiPath: r'C:\ProgramData\FocusFense\firefox.xpi',
          firefoxPolicyJson: '{}',
          firefoxRegistryExtensionSettingsJson: '{}',
        );

        expect(script, contains(r'$srcCrx = "${src}.crx"'));
        expect(
          script,
          contains(r'Copy-Item -LiteralPath $srcCrx -Destination $destCrx'),
        );
        expect(
          script,
          contains(
            r"Set-ItemProperty -LiteralPath $key -Name 'path' -Value $destCrx",
          ),
        );
        expect(script, contains(r"hash_sha256='$crxHash'"));
        expect(script, contains(r'if (-not $crxReady)'));
        expect(
          script,
          contains(
            r'HKLM:\SOFTWARE\Policies\Chromium\ExtensionInstallForcelist',
          ),
        );
      },
    );

    test(
      'Aside app install and uninstall scripts are scoped and reversible',
      () {
        const id = 'lkmhfebcfeabdfednkliegbincbkidba';
        final install = ChromiumDerivativeExtensionService.asideInstallScript(
          id,
          updateUrl:
              'file:///C:/ProgramData/SixVPNBlocker/aside_blocker/updates.xml',
        );
        final uninstall =
            ChromiumDerivativeExtensionService.asideUninstallScript(
              id,
              resultPath: r'C:\ProgramData\SixVPNBlocker\aside.exit',
            );
        expect(install, contains(r'HKLM:\SOFTWARE\Policies\Chromium'));
        expect(install, contains('force_installed'));
        expect(install, contains('updates.xml'));
        expect(uninstall, contains('ExtensionInstallForcelist'));
        expect(uninstall, contains('ExtensionSettings'));
        expect(uninstall, isNot(contains('URLBlocklist')));
        expect(uninstall, contains('Remove-ItemProperty'));
        expect(uninstall, contains(r'C:\ProgramData\SixVPNBlocker\aside.exit'));
      },
    );

    test('Aside policy scripts install, preserve rules, and uninstall', () async {
      if (!Platform.isWindows) return;
      const String id = 'lkmhfebcfeabdfednkliegbincbkidba';
      final String registryRoot =
          'HKCU:\\Software\\FocusFenseAsidePolicyTest\\${DateTime.now().microsecondsSinceEpoch}';
      final String escapedRoot = registryRoot.replaceAll("'", "''");
      final Directory temp = await Directory.systemTemp.createTemp(
        'ff-aside-policy-',
      );
      Future<ProcessResult> runPs(String path) => Process.run(
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        <String>['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path],
      );
      Future<Map<String, dynamic>> readState() async {
        final File file = File('${temp.path}\\read.ps1');
        await file.writeAsString(
          r'''
$root='__ROOT__'
$p=Get-ItemProperty $root
$fl=Get-ItemProperty (Join-Path $root 'ExtensionInstallForcelist')
$bl=Get-ItemProperty (Join-Path $root 'URLBlocklist')
@{settings=($p.ExtensionSettings|ConvertFrom-Json);forcelist=@($fl.PSObject.Properties|Where-Object {$_.Name -match '^\d+$'}|ForEach-Object {$_.Value});blocklist=@($bl.PSObject.Properties|Where-Object {$_.Name -match '^\d+$'}|ForEach-Object {$_.Value})}|ConvertTo-Json -Depth 8 -Compress
'''
              .replaceAll('__ROOT__', escapedRoot),
        );
        final ProcessResult result = await runPs(file.path);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return jsonDecode('${result.stdout}'.trim()) as Map<String, dynamic>;
      }

      try {
        final File seed = File('${temp.path}\\seed.ps1');
        await seed.writeAsString(
          r'''
$root='__ROOT__'
New-Item -Path $root -Force | Out-Null
Set-ItemProperty -Path $root -Name ExtensionSettings -Value '{"another-extension":{"installation_mode":"allowed"}}' -Type String
$fl=Join-Path $root 'ExtensionInstallForcelist'; New-Item -Path $fl -Force | Out-Null
Set-ItemProperty -Path $fl -Name '1' -Value 'another-extension;https://updates.example/other.xml' -Type String
$bl=Join-Path $root 'URLBlocklist'; New-Item -Path $bl -Force | Out-Null
Set-ItemProperty -Path $bl -Name '1' -Value '*://blocked.example/*' -Type String
'''
              .replaceAll('__ROOT__', escapedRoot),
        );
        final ProcessResult seeded = await runPs(seed.path);
        expect(seeded.exitCode, 0, reason: '${seeded.stderr}');
        expect(await readState().then((state) => state['forcelist']), <String>[
          'another-extension;https://updates.example/other.xml',
        ]);

        final String installExit = '${temp.path}\\install.exit';
        final File install = File('${temp.path}\\install.ps1');
        await install.writeAsString(
          ChromiumDerivativeExtensionService.asideInstallScript(
            id,
            updateUrl: 'file:///C:/test/aside/updates.xml',
            registryRoot: registryRoot,
          ).replaceAll('__FOCUSFENSE_EXIT_PATH__', installExit),
        );
        final ProcessResult installed = await runPs(install.path);
        expect(installed.exitCode, 0, reason: '${installed.stderr}');
        final Map<String, dynamic> installedState = await readState();
        final Map<String, dynamic> installedSettings =
            installedState['settings'] as Map<String, dynamic>;
        expect(installedSettings[id]['installation_mode'], 'force_installed');
        expect(installedSettings.containsKey('another-extension'), isTrue);
        expect(
          (installedState['forcelist'] as List).length,
          2,
          reason: 'Installed policy state: ${jsonEncode(installedState)}',
        );
        expect(installedState['blocklist'], <String>['*://blocked.example/*']);

        final File updatedInstall = File('${temp.path}\\updated-install.ps1');
        await updatedInstall.writeAsString(
          ChromiumDerivativeExtensionService.asideInstallScript(
            id,
            updateUrl: 'file:///C:/test/aside-v2/updates.xml',
            registryRoot: registryRoot,
          ).replaceAll(
            '__FOCUSFENSE_EXIT_PATH__',
            '${temp.path}\\updated-install.exit',
          ),
        );
        final ProcessResult updated = await runPs(updatedInstall.path);
        expect(updated.exitCode, 0, reason: '${updated.stderr}');
        final Map<String, dynamic> updatedState = await readState();
        final Map<String, dynamic> updatedSettings =
            updatedState['settings'] as Map<String, dynamic>;
        expect(
          updatedSettings[id]['update_url'],
          'file:///C:/test/aside-v2/updates.xml',
        );
        expect((updatedState['forcelist'] as List).length, 2);
        expect(
          (updatedState['forcelist'] as List).where(
            (value) => value.toString().startsWith('$id;'),
          ),
          <String>['$id;file:///C:/test/aside-v2/updates.xml'],
        );
        expect(updatedState['blocklist'], <String>['*://blocked.example/*']);

        final String uninstallExit = '${temp.path}\\uninstall.exit';
        final File uninstall = File('${temp.path}\\uninstall.ps1');
        await uninstall.writeAsString(
          ChromiumDerivativeExtensionService.asideUninstallScript(
            id,
            resultPath: uninstallExit,
            registryRoot: registryRoot,
          ),
        );
        final ProcessResult uninstalled = await runPs(uninstall.path);
        expect(uninstalled.exitCode, 0, reason: '${uninstalled.stderr}');
        final Map<String, dynamic> removedState = await readState();
        final Map<String, dynamic> remainingSettings =
            removedState['settings'] as Map<String, dynamic>;
        expect(remainingSettings.containsKey(id), isFalse);
        expect(remainingSettings.containsKey('another-extension'), isTrue);
        expect(removedState['forcelist'], <String>[
          'another-extension;https://updates.example/other.xml',
        ]);
        expect(removedState['blocklist'], <String>['*://blocked.example/*']);
      } finally {
        await Process.run(
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
          <String>[
            '-NoProfile',
            '-Command',
            "Remove-Item -LiteralPath '$escapedRoot' -Recurse -Force -ErrorAction SilentlyContinue",
          ],
        );
        await temp.delete(recursive: true);
      }
    });
  });
}
