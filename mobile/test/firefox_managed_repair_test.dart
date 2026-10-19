import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_firefox_extension_install_service.dart';

void main() {
  test(
    'single UAC command quotes script paths containing spaces and apostrophes',
    () {
      final command =
          WindowsFirefoxExtensionInstallService.buildManagedElevationCommand(
            psExe: r'C:\Windows\powershell.exe',
            scriptPath: r"C:\User's Name\repair.ps1",
          );
      expect(RegExp('-Verb RunAs').allMatches(command).length, 1);
      expect(command, contains('"C:\\User\'\'s Name\\repair.ps1"'));
      expect(command, isNot(contains('Stop-Process')));
      expect(command, isNot(contains('taskkill')));
    },
  );
  test(
    'reads only FocusFense entry and preserves observed signature/active/version',
    () {
      final addon = WindowsFirefoxExtensionInstallService.parseManagedAddon({
        'addons': [
          {'id': 'other@example', 'version': '999', 'active': true},
          {
            'id': WindowsFirefoxExtensionInstallService.kExtensionId,
            'version': '1.0.22',
            'active': true,
            'signedState': 2,
            'defaultLocale': {'name': 'FocusFense'},
            'path': r'C:\test\addon.xpi',
          },
        ],
      }, profilePath: r'C:\test');
      expect(addon!.name, 'FocusFense');
      expect(addon.version, '1.0.22');
      expect(addon.signedState, 2);
      expect(addon.withSha256('exact').matches('1.0.22', 'exact'), isTrue);
      expect(addon.withSha256('other').matches('1.0.22', 'exact'), isFalse);
      expect(addon.withSha256('exact').matches('1.0.23', 'exact'), isFalse);
    },
  );
  test('disabled metadata and unrelated entries never prove activation', () {
    final addon = WindowsFirefoxExtensionInstallService.parseManagedAddon({
      'addons': [
        {
          'id': WindowsFirefoxExtensionInstallService.kExtensionId,
          'version': '1.0.22',
          'active': true,
          'signedState': 2,
          'userDisabled': true,
        },
      ],
    }, profilePath: 'profile');
    expect(addon!.active, isFalse);
    expect(
      WindowsFirefoxExtensionInstallService.parseManagedAddon({
        'addons': [
          {'id': 'other'},
        ],
      }, profilePath: 'profile'),
      isNull,
    );
  });
  test(
    'prepared files/policies never imply activation or complete profile coverage',
    () {
      final report = FirefoxManagedRepairReport(
        filesPrepared: true,
        policiesApplied: true,
        firefoxRunning: true,
        expectedVersion: '1.0.22',
        expectedSha256: 'sha',
        profileTotal: 2,
        profiles: [
          const FirefoxProfileAddonStatus(
            profilePath: 'one',
            name: 'FocusFense',
            version: '1.0.22',
            active: true,
            signedState: 2,
            xpiPath: 'one.xpi',
            sha256: 'sha',
          ),
        ],
      );
      expect(report.activeProfileCount, 1);
      expect(report.activationVerified, isFalse);
      expect(report.nextRestartNeeded, isTrue);
      expect(report.browserConfirmationNeeded, isTrue);
      expect(report.ok, isFalse);
      expect(
        const FirefoxManagedRepairReport(profileTotal: 0).activationVerified,
        isFalse,
      );
    },
  );
  test('unsigned matching bytes are not activation proof', () {
    for (final signature in [null, 0, 1]) {
      final status = FirefoxProfileAddonStatus(
        profilePath: 'one',
        name: 'FocusFense',
        version: '1.0.22',
        active: true,
        signedState: signature,
        xpiPath: 'one.xpi',
        sha256: 'sha',
      );
      expect(status.matches('1.0.22', 'sha'), isFalse);
    }
  });
  test(
    'targeted policy merge preserves unrelated policy and extension in sandbox',
    () async {
      final dir = await Directory.systemTemp.createTemp('ff-repair-test-');
      try {
        final source = File('${dir.path}/source.xpi');
        await source.writeAsBytes([1, 2, 3, 4]);
        final policy = File('${dir.path}/distribution/policies.json');
        await policy.parent.create();
        final old = {
          'policies': {
            'WebsiteFilter': {
              'Block': ['https://existing.example/*'],
            },
            'OtherPolicy': true,
            'ExtensionSettings': {
              'other@example': {'installation_mode': 'allowed'},
            },
            'Extensions': {
              'Install': ['https://other.example/other.xpi'],
              'Locked': ['other@example'],
            },
          },
        };
        await policy.writeAsString(jsonEncode(old));
        final config = File('${dir.path}/config.json');
        await config.writeAsString(
          jsonEncode({
            'xpiSource': source.path,
            'xpiTarget': '${dir.path}/installed/ours.xpi',
            'sha256': sha256.convert([1, 2, 3, 4]).toString(),
            'extensionId': WindowsFirefoxExtensionInstallService.kExtensionId,
            'installUrl': 'file:///ours.xpi',
            'policyTargets': [policy.path],
            'exitFile': '${dir.path}/exit.txt',
            'resultFile': '${dir.path}/result.txt',
          }),
        );
        final body =
            WindowsFirefoxExtensionInstallService.buildManagedRepairScript(
              config.path,
            );
        expect(body, isNot(contains('Stop-Process')));
        expect(body, isNot(contains('taskkill')));
        expect(body, isNot(contains('Chrome')));
        final script = File('${dir.path}/repair.ps1');
        await script.writeAsString('\uFEFF$body');
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason:
              '${result.stdout}\n${result.stderr}\n${await File('${dir.path}/result.txt').readAsString()}',
        );
        final updated = jsonDecode(await policy.readAsString()) as Map;
        expect(
          updated['policies']['WebsiteFilter'],
          old['policies']!['WebsiteFilter'],
        );
        expect(updated['policies']['OtherPolicy'], isTrue);
        expect(updated['policies']['ExtensionSettings']['other@example'], {
          'installation_mode': 'allowed',
        });
        expect(
          updated['policies']['Extensions']['Install'],
          contains('https://other.example/other.xpi'),
        );
        expect(
          updated['policies']['Extensions']['Locked'],
          contains('other@example'),
        );
        expect(
          updated['policies']['ExtensionSettings'][WindowsFirefoxExtensionInstallService
              .kExtensionId]['install_url'],
          'file:///ours.xpi',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
