import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/models/block_app.dart';
import 'package:six_clean_room/models/active_app_block_entry.dart';
import 'package:six_clean_room/models/quick_block_user_bundle.dart';
import 'package:six_clean_room/models/quick_block_rule_entries.dart';
import 'package:six_clean_room/services/quick_block_prefs_store.dart';
import 'package:six_clean_room/services/quick_block_session_service.dart';
import 'package:six_clean_room/services/app_control_contract.dart';

void main() {
  test(
    'release hold remains explicit when a schedule or maintenance context merges',
    () {
      const held = AppBlockContext(
        source: AppBlockSource.quickBlock,
        scheduleLabels: ['hold'],
        browserReleaseHold: true,
      );
      const schedule = AppBlockContext(
        source: AppBlockSource.schedule,
        scheduleLabels: ['schedule'],
      );
      expect(held.merge(schedule).browserReleaseHold, true);
      expect(schedule.merge(held).browserReleaseHold, true);
      expect(schedule.browserReleaseHold, false);
    },
  );
  test(
    'expired browser hold survives persistence and restart; ordinary timer expires',
    () async {
      SharedPreferences.setMockInitialValues({});
      final past = DateTime.now()
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch;
      final normal = QuickBlockSession(
        startedAtMs: past - 100,
        untilMs: past,
        cancelNotBeforeMs: past,
        bundleIds: ['browser'],
        appNames: [],
      );
      final held = QuickBlockSession.fromJson({
        ...normal.toJson(),
        'releaseRequired': true,
      })!;
      expect(normal.isActive, false);
      expect(held.isActive, true);
      expect(held.remaining, Duration.zero);
      await QuickBlockPrefsStore.instance.saveSession(held);
      expect(
        (await QuickBlockPrefsStore.instance.loadSession())?.releaseRequired,
        true,
      );
      await QuickBlockPrefsStore.instance.saveSession(normal);
      expect(await QuickBlockPrefsStore.instance.loadSession(), isNull);
    },
  );
  test(
    'browser hold control cannot accept arbitrary executable or release overrides',
    () {
      for (final action in ['app.holdBrowsers', 'app.releaseBrowserHold']) {
        AppControlContract.validate(action, {});
        expect(
          () => AppControlContract.validate(action, {'force': true}),
          throwsFormatException,
        );
      }
    },
  );
  test('authenticated debug release can opt out of the hold minimum', () {
    AppControlContract.validate('app.releaseBrowserHold', {
      'debugOverride': true,
    });
    expect(
      () => AppControlContract.validate('app.releaseBrowserHold', {
        'debugOverride': 'yes',
      }),
      throwsFormatException,
    );
    AppControlContract.validate('quickBlock.clear', {'debugOverride': true});
  });
  test(
    'browser test lease is bounded, explicit, and persisted for recovery',
    () async {
      AppControlContract.validate('quickBlock.testLease.begin', {
        'durationMinutes': 10,
        'debugOverride': true,
      });
      AppControlContract.validate('quickBlock.testLease.end', {
        'debugOverride': true,
      });
      for (final args in [
        {'durationMinutes': 0, 'debugOverride': true},
        {'durationMinutes': 61, 'debugOverride': true},
        {'durationMinutes': 10},
        {'durationMinutes': 10, 'debugOverride': false},
      ]) {
        expect(
          () => AppControlContract.validate('quickBlock.testLease.begin', args),
          throwsFormatException,
        );
      }

      SharedPreferences.setMockInitialValues({});
      final store = QuickBlockPrefsStore.instance;
      await store.saveTestLeaseUntilMs(1700000000000);
      expect(await store.loadTestLeaseUntilMs(), 1700000000000);
      await store.clearTestLease();
      expect(await store.loadTestLeaseUntilMs(), isNull);
    },
  );
  test('Codex can validate exact rule, schedule and browser debug edits', () {
    AppControlContract.validate('chat.apply', {
      'message': 'move game block to 10pm',
      'debugOverride': true,
    });
    AppControlContract.validate('rule.remove', {
      'type': 'domain',
      'value': 'example.com',
      'debugOverride': true,
    });
    AppControlContract.validate('rule.setEnabled', {
      'type': 'keyword',
      'value': 'winterstarcraft',
      'enabled': false,
      'debugOverride': true,
    });
    AppControlContract.validate('schedule.setEnabled', {
      'scheduleId': 'schedule-1',
      'enabled': false,
      'debugOverride': true,
    });
    AppControlContract.validate('browser.disable', {
      'browser': 'chrome',
      'debugOverride': true,
    });
    expect(
      () => AppControlContract.validate('rule.setEnabled', {
        'type': 'domain',
        'value': 'example.com',
        'enabled': 'false',
      }),
      throwsFormatException,
    );
  });
  test('test lease accepts only the exact Chrome/Aside hold bundle', () {
    const session = QuickBlockSession(
      startedAtMs: 1,
      untilMs: 2,
      cancelNotBeforeMs: 2,
      bundleIds: ['hold'],
      appNames: [],
      releaseRequired: true,
    );
    const exact = QuickBlockUserBundle(
      id: 'hold',
      label: 'Chrome · Aside hold',
      apps: [
        QuickBlockAppRule(
          displayName: 'Google Chrome',
          bundleId: 'win|chrome.exe|_main',
        ),
        QuickBlockAppRule(
          displayName: 'Aside',
          bundleId: 'win|aside.exe|_main',
        ),
      ],
    );
    expect(
      QuickBlockSessionService.isBrowserHoldTestTarget(session, exact),
      isTrue,
    );
    expect(
      QuickBlockSessionService.isBrowserHoldTestTarget(
        QuickBlockSession.fromJson({
          ...session.toJson(),
          'releaseRequired': false,
        })!,
        exact,
      ),
      isFalse,
    );
    expect(
      QuickBlockSessionService.isBrowserHoldTestTarget(
        session,
        exact.copyWith(
          domains: [const QuickBlockDomainRule(host: 'example.com')],
        ),
      ),
      isFalse,
    );
    expect(
      QuickBlockSessionService.isBrowserHoldTestTarget(
        session,
        exact.copyWith(
          apps: const [
            QuickBlockAppRule(
              displayName: 'Google Chrome',
              bundleId: 'win|chrome.exe|_main',
            ),
          ],
        ),
      ),
      isFalse,
    );
  });
  test(
    'expired lease restores its persisted browser hold after service restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final QuickBlockPrefsStore store = QuickBlockPrefsStore.instance;
      final int now = DateTime.now().millisecondsSinceEpoch;
      const QuickBlockUserBundle bundle = QuickBlockUserBundle(
        id: 'hold',
        label: 'Chrome · Aside hold',
        apps: <QuickBlockAppRule>[
          QuickBlockAppRule(
            displayName: 'Google Chrome',
            bundleId: 'win|chrome.exe|_main',
          ),
          QuickBlockAppRule(
            displayName: 'Aside',
            bundleId: 'win|aside.exe|_main',
          ),
        ],
      );
      final QuickBlockSession original = QuickBlockSession(
        startedAtMs: now,
        untilMs: now + const Duration(hours: 72).inMilliseconds,
        cancelNotBeforeMs: now + const Duration(hours: 72).inMilliseconds,
        bundleIds: const <String>['hold'],
        appNames: const <String>[],
        releaseRequired: true,
      );
      await store.saveBundles(const <QuickBlockUserBundle>[bundle]);
      await store.saveSession(original);
      var clearCalls = 0;
      final List<String> restoredBundles = <String>[];
      final QuickBlockSessionService beforeRestart =
          QuickBlockSessionService.forTesting(
            clearQuickBlocks: () async {
              clearCalls++;
            },
            applyBundle: (String id) async {
              restoredBundles.add(id);
              return 0;
            },
            requestApply: () {},
          );
      await beforeRestart.beginBrowserHoldTestLease(durationMinutes: 5);
      expect(clearCalls, 1);
      expect((await store.loadSession())?.toJson(), original.toJson());
      expect(await beforeRestart.activeSession(), isNull);
      await expectLater(
        beforeRestart.startWithBundles(const <String>['other']),
        throwsStateError,
      );

      // A fresh service instance reads the same persisted deadline and session.
      final QuickBlockSessionService afterRestart =
          QuickBlockSessionService.forTesting(
            clearQuickBlocks: () async {},
            applyBundle: (String id) async {
              restoredBundles.add(id);
              return 0;
            },
            requestApply: () {},
          );
      expect(await afterRestart.activeSession(), isNull);
      await store.saveTestLeaseUntilMs(
        DateTime.now()
            .subtract(const Duration(milliseconds: 1))
            .millisecondsSinceEpoch,
      );
      final QuickBlockSession? recovered = await afterRestart.activeSession();
      expect(recovered?.releaseRequired, isTrue);
      expect(recovered?.bundleIds, const <String>['hold']);
      expect(restoredBundles, const <String>['hold']);
      expect(await store.loadTestLeaseUntilMs(), isNull);
    },
  );
  test('Aside CLI executable is distinguished from browser and URL text', () {
    expect(
      BlockApp.isAsideCliCommandLine(
        r'"C:\Users\user\AppData\Local\Aside\CLI\current\aside.exe" daemon',
      ),
      true,
    );
    expect(
      BlockApp.isAsideCliCommandLine(
        r'"C:\Program Files\Aside\Application\Aside.exe" https://example.com',
      ),
      false,
    );
    expect(
      BlockApp.isAsideCliCommandLine(
        r'"C:\Program Files\Aside\Application\Aside.exe" "C:\Aside\CLI\current\aside.exe"',
      ),
      false,
    );
  });
}
