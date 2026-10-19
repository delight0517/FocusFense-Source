import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/active_app_block_entry.dart';
import 'package:six_clean_room/models/block_app.dart';
import 'package:six_clean_room/services/windows_app_block_service.dart';

ActiveAppBlockEntry _entry(BlockApp app) => ActiveAppBlockEntry(
  app: app,
  context: const AppBlockContext(
    source: AppBlockSource.schedule,
    scheduleLabels: <String>['테스트 스케줄'],
  ),
);

void main() {
  group('WindowsAppBlockService.ifeoEligibleDisplayNames', () {
    const Set<String> alwaysProtected = <String>{
      'explorer.exe',
      'dwm.exe',
      'six_clean_room.exe',
    };

    test('includes a normal blocked exe with its display name', () {
      final Map<String, String> out = WindowsAppBlockService.ifeoEligibleDisplayNames(
        <ActiveAppBlockEntry>[
          _entry(
            const BlockApp(exeName: 'discord.exe', displayName: 'Discord'),
          ),
        ],
        alwaysProtected,
      );
      expect(out, <String, String>{'discord.exe': 'Discord'});
    });

    test('excludes always-protected exes even if a schedule targets them', () {
      final Map<String, String> out = WindowsAppBlockService.ifeoEligibleDisplayNames(
        <ActiveAppBlockEntry>[
          _entry(
            const BlockApp(exeName: 'explorer.exe', displayName: 'Explorer'),
          ),
        ],
        alwaysProtected,
      );
      expect(out, isEmpty);
    });

    test('excludes window-title-only legacy rows (empty exeName)', () {
      final Map<String, String> out = WindowsAppBlockService.ifeoEligibleDisplayNames(
        <ActiveAppBlockEntry>[
          _entry(
            const BlockApp(
              exeName: '',
              displayName: '레거시 창',
              windowTitleMatch: '야동',
            ),
          ),
        ],
        alwaysProtected,
      );
      expect(out, isEmpty);
    });

    test('excludes Chrome/Edge PWA sub-entries (share the parent exe)', () {
      final Map<String, String> out = WindowsAppBlockService.ifeoEligibleDisplayNames(
        <ActiveAppBlockEntry>[
          _entry(
            const BlockApp(
              exeName: 'chrome.exe',
              displayName: 'YouTube Music',
              chromeAppId: 'cinhimbnkkaeohfgghhklpknlkffjgod',
            ),
          ),
        ],
        alwaysProtected,
      );
      expect(out, isEmpty);
    });

    test('includes the main-browser-only entry (not a PWA)', () {
      final Map<String, String> out = WindowsAppBlockService.ifeoEligibleDisplayNames(
        <ActiveAppBlockEntry>[
          _entry(
            const BlockApp(
              exeName: 'chrome.exe',
              displayName: 'Google Chrome',
              chromeAppId: BlockApp.mainBrowserKey,
            ),
          ),
        ],
        alwaysProtected,
      );
      expect(out, <String, String>{'chrome.exe': 'Google Chrome'});
    });

    test('dedupes repeated exe names across multiple schedule entries', () {
      final Map<String, String> out = WindowsAppBlockService.ifeoEligibleDisplayNames(
        <ActiveAppBlockEntry>[
          _entry(
            const BlockApp(exeName: 'brave.exe', displayName: 'Brave'),
          ),
          _entry(
            const BlockApp(exeName: 'brave.exe', displayName: 'Brave (dup)'),
          ),
        ],
        alwaysProtected,
      );
      expect(out.length, 1);
      expect(out['brave.exe'], 'Brave');
    });

    test('mixed set: only the eligible normal exes survive', () {
      final Map<String, String> out = WindowsAppBlockService.ifeoEligibleDisplayNames(
        <ActiveAppBlockEntry>[
          _entry(const BlockApp(exeName: 'discord.exe', displayName: 'Discord')),
          _entry(const BlockApp(exeName: 'dwm.exe', displayName: 'dwm')),
          _entry(
            const BlockApp(
              exeName: '',
              displayName: '레거시',
              windowTitleMatch: '차단어',
            ),
          ),
          _entry(
            const BlockApp(
              exeName: 'msedge.exe',
              displayName: 'YouTube Music (Edge PWA)',
              chromeAppId: 'somepwahash1234567890',
            ),
          ),
        ],
        alwaysProtected,
      );
      expect(out, <String, String>{'discord.exe': 'Discord'});
    });
  });
}
