import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_emergency_block_service.dart';
import 'package:six_clean_room/services/extension_rules_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stage in [
    'entry-off',
    'apply-off',
    'apply-failed',
    'firefox-off',
    'success',
  ]) {
    test(
      'emergency PAC stage $stage uses one owned writer and honors OFF',
      () async {
        bool off = stage == 'entry-off';
        int applies = 0;
        int firefox = 0;
        final service = WindowsEmergencyBlockService.forTesting(
          protectionOff: () => off,
          applyPac: (path) async {
            expect(path, r'C:\isolated\fixture.pac');
            applies++;
            if (stage == 'apply-off') off = true;
            return stage != 'apply-failed';
          },
          configureFirefox: (uri) async {
            expect(uri, Uri.file(r'C:\isolated\fixture.pac').toString());
            firefox++;
            if (stage == 'firefox-off') off = true;
          },
        );
        expect(
          await service.applyPreparedPac(r'C:\isolated\fixture.pac'),
          stage == 'success',
        );
        expect(applies, stage == 'entry-off' ? 0 : 1);
        expect(firefox, ['success', 'firefox-off'].contains(stage) ? 1 : 0);
      },
      skip: !Platform.isWindows,
    );
  }

  for (final globalOff in [true, false]) {
    test(
      'disabled emergency entry skips database, PAC files and browser config; global=$globalOff',
      () async {
        int calls = 0;
        final service = WindowsEmergencyBlockService.forTesting(
          protectionOff: () => globalOff,
          applyPac: (_) async {
            calls++;
            return true;
          },
          configureFirefox: (_) async {
            calls++;
          },
        );
        const disabled = ExtensionRulesPayload(
          blockedDomains: [],
          keywords: [],
          searchQueries: [],
          precisionContentFilter: false,
          updatedAtMs: 0,
          protectionEnabled: false,
        );
        expect((await service.applyFromRules(disabled)).pacApplied, false);
        if (globalOff) expect((await service.applyNow()).pacApplied, false);
        expect(calls, 0);
      },
      skip: !Platform.isWindows,
    );
  }
}
