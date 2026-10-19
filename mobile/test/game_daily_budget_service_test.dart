import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/game_daily_budget_service.dart';
import 'package:six_clean_room/services/usage_tracking_service.dart';
import 'package:six_clean_room/services/frontmost_app_channel.dart';

class Fixture {
  DateTime now = DateTime(2026, 10, 18, 12);
  Map<String, Object?> prefs = <String, Object?>{};
  final Map<String, int> usage = <String, int>{};
  final List<int> warnings = <int>[];
  bool settingsLocked = false;
  late GameDailyBudgetService service = make();
  String day(DateTime at) => '${at.year}-${at.month}-${at.day}';
  GameDailyBudgetService make() => GameDailyBudgetService.forTesting(
    clock: () => now,
    load: () async => Map<String, Object?>.from(prefs),
    save: (value) async {
      prefs = Map<String, Object?>.from(value);
    },
    readUsage: (at) async => usage[day(at)] ?? 0,
    writeUsage: (seconds, at) async {
      usage.update(day(at), (n) => n + seconds, ifAbsent: () => seconds);
    },
    notify: (remaining, used, max) async {
      warnings.add(remaining);
    },
    settingsLocked: () async => settingsLocked,
  );
  Future<void> enable() async {
    await service.configure(
      enabled: true,
      maxMinutes: 30,
      warningMinutes: 10,
      targets: <String>['SC2_X64.EXE', 'dsv.exe', 'stray.exe'],
    );
  }

  Future<void> tick(String exe, [int seconds = 60]) async {
    now = now.add(Duration(seconds: seconds));
    await service.onForegroundUsage(
      bundleId: exe,
      seconds: seconds,
      observedAt: now,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'foreground sampler excludes switch, missing/locked desktop and suspended gaps',
    () {
      const FrontmostAppSnapshot game = FrontmostAppSnapshot(
        bundleId: 'win|dsv.exe',
        localizedName: 'dsv.exe',
        processIdentifier: 1,
      );
      const FrontmostAppSnapshot other = FrontmostAppSnapshot(
        bundleId: 'win|stray.exe',
        localizedName: 'stray.exe',
        processIdentifier: 2,
      );
      expect(
        UsageTrackingService.verifiedForegroundSeconds(
          previous: game,
          current: game,
          elapsedSeconds: 5,
        ),
        5,
      );
      expect(
        UsageTrackingService.verifiedForegroundSeconds(
          previous: game,
          current: other,
          elapsedSeconds: 5,
        ),
        0,
      );
      expect(
        UsageTrackingService.verifiedForegroundSeconds(
          previous: game,
          current: null,
          elapsedSeconds: 5,
        ),
        0,
      );
      expect(
        UsageTrackingService.verifiedForegroundSeconds(
          previous: null,
          current: game,
          elapsedSeconds: 5,
        ),
        0,
      );
      expect(
        UsageTrackingService.verifiedForegroundSeconds(
          previous: game,
          current: game,
          elapsedSeconds: 60,
        ),
        0,
      );
    },
  );
  test(
    'disabled empty default backup restores without inventing targets or usage',
    () async {
      final Fixture f = Fixture();
      final Map<String, Object?> backup = await f.service.toBackupMap();
      await f.service.restoreFromBackup(backup);
      expect((await f.service.status())['enabled'], false);
      expect((await f.service.status())['targets'], isEmpty);
      expect(f.usage, isEmpty);
    },
  );
  test(
    'default disabled and observation is sanitized without counting browsers',
    () async {
      final Fixture f = Fixture();
      expect((await f.service.status())['enabled'], false);
      await f.tick(r'win|C:\Program Files\Firefox\FIREFOX.EXE');
      final Map<String, Object?> state = await f.service.status();
      expect(state['usedSeconds'], 0);
      expect(state['lastObservedExecutable'], 'firefox.exe');
      expect(state['lastObservedAt'], f.now.toIso8601String());
      expect(f.prefs, isEmpty);
    },
  );
  test(
    'exact aliases pool different games once, excludes launcher browser editor and other exe',
    () async {
      final Fixture f = Fixture();
      await f.enable();
      await f.tick('win|SC2_X64.EXE');
      await f.tick(r'C:\Games\DSV.exe');
      await f.tick('stray.exe');
      for (final String exe in <String>[
        'steam.exe',
        'battle.net.exe',
        'firefox.exe',
        'UnrealEditor.exe',
        'not-stray.exe',
      ]) {
        await f.tick(exe);
      }
      expect((await f.service.status())['usedSeconds'], 180);
      expect(f.usage.values.single, 180);
      expect(f.service.isProcessLocked('stray.exe'), false);
    },
  );
  test('first-run prompt is limited to likely game executables', () async {
    final Fixture f = Fixture();
    await f.enable();

    expect(GameDailyBudgetService.isLikelyGameExecutable('fmodel.exe'), false);
    expect(
      GameDailyBudgetService.isLikelyGameExecutable(
        'photoshop.exe',
        executablePath: r'C:\Program Files\Adobe\Photoshop.exe',
      ),
      false,
    );
    expect(await f.service.claimFirstRunQuestion('fmodel.exe'), false);
    expect(f.prefs['firstRunQuestions'], isNull);

    const String gamePath =
        r'E:\SteamLibrary\steamapps\common\My Game\bin\game.exe';
    expect(
      GameDailyBudgetService.isLikelyGameExecutable(
        'game.exe',
        executablePath: gamePath,
      ),
      true,
    );
    expect(
      await f.service.claimFirstRunQuestion(
        'game.exe',
        executablePath: gamePath,
      ),
      true,
    );
    expect(await f.service.claimFirstRunQuestion('game.exe'), false);
  });
  test(
    'warning at ten minutes remaining persists once per day across restart and concurrency',
    () async {
      final Fixture f = Fixture();
      await f.enable();
      for (int i = 0; i < 19; i++) {
        await f.tick('dsv.exe');
      }
      expect(f.warnings, isEmpty);
      await f.tick('sc2_x64.exe');
      expect(f.warnings, <int>[600]);
      f.service = f.make();
      await Future.wait(<Future<void>>[
        f.service.refresh(),
        f.service.refresh(),
      ]);
      await f.tick('stray.exe');
      expect(f.warnings, <int>[600]);
      expect((await f.service.status())['warnedToday'], true);
      for (int i = 0; i < 9; i++) {
        await f.tick('dsv.exe');
      }
      final Map<String, Object?> state = await f.service.status();
      expect(state['usedSeconds'], 1800);
      expect(state['remainingSeconds'], 0);
      expect(state['locked'], true);
      expect(f.service.isProcessLocked('win|DSV.EXE'), true);
      expect(f.service.isProcessLocked('firefox.exe'), false);
    },
  );
  test(
    'midnight releases lock and split sample charges only each local calendar day',
    () async {
      final Fixture f = Fixture();
      await f.enable();
      f.usage[f.day(f.now)] = 1800;
      await f.service.refresh();
      expect(f.service.isProcessLocked('dsv.exe'), true);
      f.now = DateTime(2026, 10, 19, 0, 0, 3);
      expect(f.service.isProcessLocked('dsv.exe'), false);
      await f.service.onForegroundUsage(
        bundleId: 'dsv.exe',
        seconds: 5,
        observedAt: f.now,
      );
      expect(f.usage['2026-10-18'], 1800);
      expect(f.usage['2026-10-19'], 3);
      final Map<String, Object?> state = await f.service.status();
      expect(state['usedSeconds'], 3);
      expect(state['warnedToday'], false);
      expect(state['resetAt'], DateTime(2026, 10, 20).toIso8601String());
    },
  );
  test(
    'a long sample never records beyond the remaining daily allowance',
    () async {
      final Fixture f = Fixture();
      await f.enable();
      f.usage[f.day(f.now)] = 1795;
      await f.tick('dsv.exe', 15);
      final Map<String, Object?> state = await f.service.status();
      expect(state['usedSeconds'], 1800);
      expect(state['remainingSeconds'], 0);
      expect(state['locked'], true);
    },
  );
  test(
    'sleep gaps ignored and disabling/reconfiguring never resets ledger',
    () async {
      final Fixture f = Fixture();
      await f.enable();
      await f.tick('dsv.exe');
      await f.tick('dsv.exe', 600);
      expect((await f.service.status())['usedSeconds'], 60);
      await f.service.configure(
        enabled: false,
        maxMinutes: 30,
        warningMinutes: 10,
        targets: <String>['dsv.exe'],
      );
      await f.tick('dsv.exe');
      await f.enable();
      expect((await f.service.status())['usedSeconds'], 60);
    },
  );
  test(
    'locked settings reject weaker budgets and target removal but permit tightening',
    () async {
      final Fixture f = Fixture();
      await f.enable();
      f.settingsLocked = true;
      for (final Future<Map<String, Object?>> Function() update
          in <Future<Map<String, Object?>> Function()>[
            () => f.service.configure(
              enabled: false,
              maxMinutes: 30,
              warningMinutes: 10,
              targets: <String>['dsv.exe'],
            ),
            () => f.service.configure(
              enabled: true,
              maxMinutes: 40,
              warningMinutes: 10,
              targets: <String>['dsv.exe', 'stray.exe', 'sc2_x64.exe'],
            ),
            () => f.service.configure(
              enabled: true,
              maxMinutes: 30,
              warningMinutes: 10,
              targets: <String>['dsv.exe'],
            ),
          ]) {
        await expectLater(update(), throwsStateError);
      }
      await f.service.configure(
        enabled: true,
        maxMinutes: 25,
        warningMinutes: 10,
        targets: <String>['dsv.exe', 'stray.exe', 'sc2_x64.exe'],
      );
      expect((await f.service.status())['maxMinutes'], 25);
    },
  );
  test(
    'backup restores warning day without resetting usage and rejects unsafe targets',
    () async {
      final Fixture f = Fixture();
      await f.enable();
      f.usage[f.day(f.now)] = 1200;
      await f.service.refresh();
      final Map<String, Object?> saved = await f.service.toBackupMap();
      f.service = f.make();
      await f.service.restoreFromBackup(saved);
      expect((await f.service.status())['usedSeconds'], 1200);
      expect(f.warnings.length, 1);
      for (final String exe in <String>[
        'steam.exe',
        'chrome.exe',
        'unrealeditor.exe',
        '*.exe',
        'oops',
      ]) {
        await expectLater(
          f.service.configure(
            enabled: true,
            maxMinutes: 30,
            warningMinutes: 10,
            targets: <String>[exe],
          ),
          throwsArgumentError,
        );
      }
      await expectLater(
        f.service.configure(
          enabled: true,
          maxMinutes: 10,
          warningMinutes: 10,
          targets: <String>['dsv.exe'],
        ),
        throwsArgumentError,
      );
    },
  );
}
