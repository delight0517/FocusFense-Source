import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:six_clean_room/services/chrome_extension_identity.dart';
import 'package:six_clean_room/services/chrome_extension_install_verifier.dart';
import 'package:six_clean_room/services/chrome_extension_state_probe.dart';

Map<String, dynamic> document(Map<String, dynamic> entries) =>
    <String, dynamic>{
      'extensions': <String, dynamic>{'settings': entries},
    };
Map<String, dynamic> entry(int state, {int location = 1}) => <String, dynamic>{
  'state': state,
  'location': location,
};

void main() {
  test(
    'repair preserves manual OFF but repairs disabled installs while ON',
    () {
      const disabled = ChromeInstallVerifyReport(
        ok: false,
        installedInProfile: true,
        enabledInProfile: false,
        policyReady: true,
        launchersReady: true,
        verdict: 'disabled fixture',
      );
      expect(
        ChromeExtensionInstallVerifier.shouldRepairInstallation(
          disabled,
          protectionEnabled: true,
        ),
        true,
      );
      for (final force in <bool>[false, true]) {
        expect(
          ChromeExtensionInstallVerifier.shouldRepairInstallation(
            disabled,
            protectionEnabled: false,
            force: force,
          ),
          false,
        );
      }
    },
  );
  for (final String browser in <String>['chrome', 'edge']) {
    final String storeId = browser == 'chrome'
        ? ChromeExtensionIdentity.chromeStoreExtensionId
        : ChromeExtensionIdentity.edgeStoreExtensionId;
    final String wrongStoreId = browser == 'chrome'
        ? ChromeExtensionIdentity.edgeStoreExtensionId
        : ChromeExtensionIdentity.chromeStoreExtensionId;

    test(
      '$browser secure disabled entry defeats stale enabled Preferences',
      () async {
        final Directory root = await Directory.systemTemp.createTemp(
          'ff-$browser-precedence-',
        );
        final Directory profile = await Directory(
          p.join(root.path, 'Default'),
        ).create();
        try {
          await File(p.join(profile.path, 'Preferences')).writeAsString(
            jsonEncode(document(<String, dynamic>{storeId: entry(1)})),
          );
          await File(p.join(profile.path, 'Secure Preferences')).writeAsString(
            jsonEncode(document(<String, dynamic>{storeId: entry(0)})),
          );
          final ChromeExtensionProbeResult read =
              await ChromeExtensionStateProbe.readProfilePreferences(
                profile,
                browser: browser,
              );
          expect(read.extensionNotPresent, false);
          expect(read.hasStoreCopy, true);
          expect(read.hasEnabledCopy, false);
          expect(read.hasRegistryManaged, false);
          expect(
            ChromeExtensionInstallVerifier.profileInstallationIsEnabled(read),
            false,
          );
          final ChromeExtensionProbeResult scan =
              await ChromeExtensionStateProbe.probe(
                browser: browser,
                userDataRootForTesting: root.path,
              );
          expect(scan.hasEnabledCopy, false);
          expect(scan.matchedExtensionIds, <String>[storeId]);
        } finally {
          await root.delete(recursive: true);
        }
      },
    );

    test(
      '$browser secure enabled entry defeats stale disabled Preferences',
      () async {
        final Directory profile = await Directory.systemTemp.createTemp(
          'ff-$browser-enabled-',
        );
        try {
          await File(p.join(profile.path, 'Preferences')).writeAsString(
            jsonEncode(document(<String, dynamic>{storeId: entry(0)})),
          );
          await File(p.join(profile.path, 'Secure Preferences')).writeAsString(
            jsonEncode(document(<String, dynamic>{storeId: entry(1)})),
          );
          final ChromeExtensionProbeResult read =
              await ChromeExtensionStateProbe.readProfilePreferences(
                profile,
                browser: browser,
              );
          expect(read.hasEnabledCopy, true);
          expect(read.hasStoreCopy, true);
          expect(read.hasRegistryManaged, false);
          expect(
            ChromeExtensionInstallVerifier.profileInstallationIsEnabled(read),
            true,
          );
        } finally {
          await profile.delete(recursive: true);
        }
      },
    );

    test(
      '$browser secure whole entry does not inherit stale enabled state',
      () {
        final ChromeExtensionProbeResult read =
            ChromeExtensionStateProbe.fromPreferenceDocuments(
              document(<String, dynamic>{storeId: entry(1)}),
              document(<String, dynamic>{
                storeId: <String, dynamic>{'location': 1},
              }),
              browser: browser,
            );
        expect(read.extensionNotPresent, false);
        expect(read.hasEnabledCopy, false);
      },
    );

    test('$browser merge preserves unrelated IDs and rejects other store', () {
      final ChromeExtensionProbeResult read =
          ChromeExtensionStateProbe.fromPreferenceDocuments(
            document(<String, dynamic>{
              storeId: entry(1),
              wrongStoreId: entry(1),
            }),
            document(<String, dynamic>{
              ChromeExtensionIdentity.extensionId: entry(0, location: 3),
            }),
            browser: browser,
          );
      expect(read.hasEnabledCopy, true);
      expect(
        read.matchedExtensionIds,
        containsAll(<String>[storeId, ChromeExtensionIdentity.extensionId]),
      );
      expect(read.matchedExtensionIds, isNot(contains(wrongStoreId)));
    });

    test('$browser explicit disable reason defeats enabled state', () {
      final Map<String, dynamic> record = entry(1)
        ..['disable_reasons'] = <int>[1];
      final ChromeExtensionProbeResult read =
          ChromeExtensionStateProbe.fromPreferences(
            document(<String, dynamic>{storeId: record}),
            browser: browser,
          );
      expect(read.hasEnabledCopy, false);
      expect(read.properlyInstalled, false);
    });
  }

  test('registry or shortcuts alone cannot verify installed-enabled state', () {
    const ChromeExtensionProbeResult registryOnly = ChromeExtensionProbeResult(
      hasUnpackedCopy: false,
      hasRegistryManaged: true,
      extensionNotPresent: true,
      hasEnabledCopy: false,
      detail: 'fixture registration only',
    );
    expect(
      ChromeExtensionInstallVerifier.profileInstallationIsEnabled(registryOnly),
      false,
    );
    const ChromeInstallVerifyReport report = ChromeInstallVerifyReport(
      ok: false,
      installedInProfile: false,
      policyReady: true,
      launchersReady: true,
      payloadReady: true,
      verdict: 'available but not installed',
    );
    expect(report.available, true);
    expect(report.toJson()['installedInProfile'], false);
    expect(report.toJson()['enabledInProfile'], false);
    expect(report.toJson()['activeVerified'], false);
    expect(report.toJson()['enforcementVerified'], false);
    final ChromeInstallVerifyReport copied = report.copyWith(repaired: true);
    expect(copied.activeVerified, false);
    expect(copied.enforcementVerified, false);
  });

  test(
    'enabled store record does not assert runtime activity or enforcement',
    () {
      final ChromeExtensionProbeResult probe =
          ChromeExtensionStateProbe.fromPreferences(
            document(<String, dynamic>{
              ChromeExtensionIdentity.chromeStoreExtensionId: entry(1),
            }),
          );
      expect(probe.hasStoreCopy, true);
      expect(probe.hasRegistryManaged, false);
      const ChromeInstallVerifyReport report = ChromeInstallVerifyReport(
        ok: true,
        installedInProfile: true,
        enabledInProfile: true,
        policyReady: false,
        launchersReady: false,
        verdict: 'store profile record',
      );
      expect(report.activeVerified, false);
      expect(report.enforcementVerified, false);
    },
  );

  test(
    'all three readers delegate to the shared precedence implementation',
    () {
      final String state = File(
        'lib/services/chrome_extension_state_probe.dart',
      ).readAsStringSync();
      expect(
        state,
        contains('fromPreferenceDocuments(ordinary, secure, browser: browser)'),
      );
      for (final String browser in <String>['chrome', 'edge']) {
        final String source = File(
          'lib/services/${browser}_channel_apply_probe_service.dart',
        ).readAsStringSync();
        expect(
          source,
          contains('ChromeExtensionStateProbe.readProfilePreferences('),
        );
        expect(source, isNot(contains('final bool disabled = stateInt == 1')));
      }
    },
  );
}
