import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_firefox_extension_install_service.dart';

void main() {
  test('Firefox policy disables private browsing instead of forcing it', () {
    final document =
        jsonDecode(
              WindowsFirefoxExtensionInstallService.buildPoliciesJson(
                xpiInstallUrl: 'file:///C:/fixture/signed.xpi',
              ),
            )
            as Map<String, dynamic>;
    final policies = document['policies'] as Map<String, dynamic>;
    expect(policies['PrivateBrowsingModeAvailability'], 1);
    expect(policies['DisablePrivateBrowsing'], true);
    final extensionSettings = policies['ExtensionSettings'] as Map;
    expect(
      extensionSettings.values.single['installation_mode'],
      'force_installed',
    );
  });

  test('all shipped Firefox repair writers use the same private-mode value', () {
    // Repair scripts must not restore the old value 2 (forced private mode).
    for (final file in <String>[
      'lib/services/windows_extension_guard_service.dart',
      'lib/services/windows_firefox_extension_install_service.dart',
      'tools/Apply-Firefox-SignedXpi-Now.ps1',
      'tools/Apply-Firefox-Blueprint-Now.ps1',
      'tools/Offline-Block-Policy-Maintain.ps1',
      'tools/Repair-Firefox-Policies.ps1',
    ]) {
      final source = File(file).readAsStringSync();
      expect(
        source,
        isNot(
          matches(
            r'''PrivateBrowsingModeAvailability['"]?\s*(?::|=|['"]?\s+-Value)\s*2\b''',
          ),
        ),
        reason: file,
      );
    }
  });
}
