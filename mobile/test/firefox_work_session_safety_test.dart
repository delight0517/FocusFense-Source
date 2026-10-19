import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/active_app_block_entry.dart';
import 'package:six_clean_room/models/block_app.dart';
import 'package:six_clean_room/services/windows_app_block_service.dart';

void main() {
  test('diagnostic and policy scripts never image-kill the user browser', () {
    final probe = File(
      'tools/Test-AllBrowsers-UrlBlock.ps1',
    ).readAsStringSync();
    final policy = File(
      'tools/Apply-Firefox-Blueprint-Now.ps1',
    ).readAsStringSync();
    expect(
      RegExp(r'taskkill\s+/F\s+/IM', caseSensitive: false).hasMatch(probe),
      false,
    );
    expect(
      policy.contains(
        'Get-Process firefox -ErrorAction SilentlyContinue | Stop-Process',
      ),
      false,
    );
    expect(probe.contains(r'Stop-Process -Id $p.Id'), true);
  });
  test(
    'Firefox work exemption excludes launch interception; Chrome hold remains',
    () {
      const context = AppBlockContext(
        source: AppBlockSource.quickBlock,
        scheduleLabels: [],
      );
      final eligible = WindowsAppBlockService.ifeoEligibleDisplayNames(
        [
          const ActiveAppBlockEntry(
            app: BlockApp(exeName: 'firefox.exe', displayName: 'Firefox'),
            context: context,
          ),
          const ActiveAppBlockEntry(
            app: BlockApp(
              exeName: 'chrome.exe',
              displayName: 'Chrome',
              chromeAppId: '_main',
            ),
            context: context,
          ),
        ],
        {'firefox.exe'},
      );
      expect(eligible.containsKey('firefox.exe'), false);
      expect(eligible.containsKey('chrome.exe'), true);
    },
  );
}
