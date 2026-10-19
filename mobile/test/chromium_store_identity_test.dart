import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/chrome_extension_identity.dart';

void main() {
  test('retains the local identity, legacy cleanup identity and public key', () {
    expect(
      ChromeExtensionIdentity.extensionId,
      'popjkofklmidngceakpcokopghehjngo',
    );
    expect(
      ChromeExtensionIdentity.legacyExtensionId,
      'lkmhfebcfeabdfednkliegbincbkidba',
    );
    // Literal captured before adding store detection; do not derive from source.
    expect(
      ChromeExtensionIdentity.manifestPublicKeyBase64,
      'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApsJyuZYxNadMB4llGOFC9iaurDEfIw56fgqzVqUoUihUU8Gqjpe6mEL/CQDM3++4WzD0UmGY21eSPVBo/X1nvY8Fgy5V808pVnSexwsG8tvBfbLPjdhedAL8s1Pevulq0UDNksc38XRqmX54/sOeC+Cjd7255UL9cb8zY8v6i2MIS/+L1y5gHGDVzLT/qJrFDfkbxrq4HYX8iOWy9ghq0SNHR+SfKDoVpZblYab1T+yTubP04ufnvz2OpcUGmiEdHt1MYKaqR2ZQxbBCjthOFBGj68cnRZRhbnAYMWiKniMh+/wmjHegEkN+rq86vpb4wKvurnReufmk00h+YKtDnQIDAQAB',
    );
  });

  test('Chrome recognizes only local and Chrome Web Store identities', () {
    expect(
      ChromeExtensionIdentity.chromeStoreExtensionId,
      'bhljnpgggfgojcahcbphhdbmbibkcmom',
    );
    expect(
      ChromeExtensionIdentity.recognizedExtensionIdsForBrowser('chrome'),
      <String>[
        ChromeExtensionIdentity.extensionId,
        ChromeExtensionIdentity.chromeStoreExtensionId,
      ],
    );
    expect(
      ChromeExtensionIdentity.recognizedExtensionIdsForBrowser('chrome'),
      isNot(contains(ChromeExtensionIdentity.edgeStoreExtensionId)),
    );
  });

  test('Edge recognizes only local and Edge Add-ons identities', () {
    expect(
      ChromeExtensionIdentity.edgeStoreExtensionId,
      'bkhjcoegbppfcgfakokcbcddcaepkodn',
    );
    expect(
      ChromeExtensionIdentity.recognizedExtensionIdsForBrowser('edge'),
      <String>[
        ChromeExtensionIdentity.extensionId,
        ChromeExtensionIdentity.edgeStoreExtensionId,
      ],
    );
    expect(
      ChromeExtensionIdentity.recognizedExtensionIdsForBrowser('edge'),
      isNot(contains(ChromeExtensionIdentity.chromeStoreExtensionId)),
    );
  });

  for (final String browser in <String>[
    'aside',
    'brave',
    'opera',
    'unknown',
    '',
  ]) {
    test('$browser retains only the local identity', () {
      expect(
        ChromeExtensionIdentity.recognizedExtensionIdsForBrowser(browser),
        <String>[ChromeExtensionIdentity.extensionId],
      );
    });
  }

  test('legacy cleanup identity is never recognized for detection', () {
    for (final String browser in <String>[
      'chrome',
      'edge',
      'aside',
      'brave',
      'opera',
      'unknown',
    ]) {
      expect(
        ChromeExtensionIdentity.recognizedExtensionIdsForBrowser(browser),
        isNot(contains(ChromeExtensionIdentity.legacyExtensionId)),
        reason: browser,
      );
    }
  });

  // Read source only: never import installers or invoke live Windows policy APIs.
  for (final String service in <String>[
    'windows_chrome_extension_install_service.dart',
    'windows_extension_guard_service.dart',
    'windows_extension_self_heal_service.dart',
  ]) {
    test(
      '$service keeps local registration and excludes unpublished stores',
      () {
        final String source = File('lib/services/$service').readAsStringSync();
        expect(source, contains('ChromeExtensionIdentity.extensionId'));
        for (final String forbidden in <String>[
          'chromeStoreExtensionId',
          'edgeStoreExtensionId',
          ChromeExtensionIdentity.chromeStoreExtensionId,
          ChromeExtensionIdentity.edgeStoreExtensionId,
        ]) {
          expect(source, isNot(contains(forbidden)), reason: forbidden);
        }
      },
    );
  }
}
