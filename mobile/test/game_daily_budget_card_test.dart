import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/widgets/game_daily_budget_card.dart';

void main() {
  Map<String, Object?> snapshot({bool locked = false}) => {
    'enabled': true,
    'maxMinutes': 30,
    'warningMinutes': 10,
    'targets': ['DragonSurvival.exe', 'AnotherGame.exe'],
    'usedSeconds': 300,
    'remainingSeconds': 1500,
    'locked': locked,
    'settingsLocked': locked,
    'resetAt': '2026-10-19T00:00:00+09:00',
  };

  testWidgets(
    'renders shared usage without writes and saves values preserving exact games',
    (tester) async {
      final data = snapshot();
      final saved = <Map<String, Object?>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GameDailyBudgetCard(
                locale: const Locale('ko'),
                readStatus: () async => data,
                configure:
                    ({
                      required enabled,
                      required maxMinutes,
                      required warningMinutes,
                      required targets,
                    }) async {
                      saved.add({
                        'enabled': enabled,
                        'maxMinutes': maxMinutes,
                        'warningMinutes': warningMinutes,
                        'targets': targets,
                      });
                      return {'ok': true};
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.text('게임 하루 공통 시간'), findsOneWidget);
      expect(find.textContaining('사용: 5 분 0 초'), findsOneWidget);
      expect(find.text('DragonSurvival.exe'), findsOneWidget);
      expect(find.textContaining('초기화:'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('game-budget-limit')), '25');
      await tester.enterText(find.byKey(const Key('game-budget-warning')), '5');
      await tester.ensureVisible(find.byKey(const Key('game-budget-save')));
      await tester.tap(find.byKey(const Key('game-budget-save')));
      await tester.pumpAndSettle();
      expect(saved.single, {
        'enabled': true,
        'maxMinutes': 25,
        'warningMinutes': 5,
        'targets': ['DragonSurvival.exe', 'AnotherGame.exe'],
      });
      expect(saved.single['targets'], isNot(contains('Steam.exe')));
      expect(find.text('게임 시간 설정을 저장했습니다.'), findsOneWidget);
    },
  );

  testWidgets(
    'invalid input causes no configuration and locked switch cannot disable',
    (tester) async {
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GameDailyBudgetCard(
                locale: const Locale('en'),
                readStatus: () async => snapshot(locked: true),
                configure:
                    ({
                      required enabled,
                      required maxMinutes,
                      required warningMinutes,
                      required targets,
                    }) async {
                      saves++;
                      throw StateError('locked');
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      await tester.enterText(find.byKey(const Key('game-budget-limit')), '0');
      await tester.ensureVisible(find.byKey(const Key('game-budget-save')));
      await tester.tap(find.byKey(const Key('game-budget-save')));
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(find.textContaining('Enter a daily limit'), findsOneWidget);
    },
  );

  testWidgets('all six app languages render translated game allowance labels', (
    tester,
  ) async {
    final titles = {
      'en': 'Daily game allowance',
      'ko': '게임 하루 공통 시간',
      'ja': 'ゲーム共通の1日上限',
      'zh': '游戏每日共用时长',
      'he': 'מכסת משחק יומית משותפת',
      'ar': 'وقت ألعاب يومي مشترك',
    };
    for (final item in titles.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GameDailyBudgetCard(
                key: ValueKey(item.key),
                locale: Locale(item.key),
                readStatus: () async => snapshot(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(item.value), findsOneWidget);
    }
  });

  testWidgets('service lock rejection is reported without claiming a save', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GameDailyBudgetCard(
              locale: const Locale('en'),
              readStatus: () async => snapshot(),
              configure:
                  ({
                    required enabled,
                    required maxMinutes,
                    required warningMinutes,
                    required targets,
                  }) async {
                    saves++;
                    throw StateError('Protection lock forbids weakening');
                  },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('game-budget-limit')), '35');
    await tester.ensureVisible(find.byKey(const Key('game-budget-save')));
    await tester.tap(find.byKey(const Key('game-budget-save')));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(
      find.textContaining('Could not update the allowance'),
      findsOneWidget,
    );
    expect(find.text('Game allowance saved.'), findsNothing);
    expect(find.textContaining('Used: 5 min 0 s'), findsOneWidget);
  });
}
