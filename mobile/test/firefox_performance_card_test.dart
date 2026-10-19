import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/widgets/firefox_performance_card.dart';

void main() {
  testWidgets(
    'reflects existing preference without writing; light mode only publishes snapshot',
    (tester) async {
      final writes = <bool>[];
      var publishes = 0, backups = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FirefoxPerformanceCard(
              locale: const Locale('ko'),
              readFiltering: () async => false,
              settingsLocked: () async => false,
              writeFiltering: (value) async {
                writes.add(value);
              },
              scheduleBackup: () => backups++,
              publishSnapshot: () async {
                publishes++;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        true,
      );
      expect(find.textContaining('시청 시간 제한은 계속'), findsOneWidget);
      await tester.tap(find.byKey(const Key('firefox-light-mode')));
      await tester.pumpAndSettle();
      expect(writes, [true]);
      expect(publishes, 1);
      expect(backups, 1);
      expect(find.text('설정을 저장하고 Firefox 규칙을 준비했습니다.'), findsOneWidget);
    },
  );
  testWidgets(
    'fresh lock rejects changes without writes or snapshot publication',
    (tester) async {
      var locked = false, writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FirefoxPerformanceCard(
              locale: const Locale('en'),
              readFiltering: () async => true,
              settingsLocked: () async => locked,
              writeFiltering: (_) async {
                writes++;
              },
              publishSnapshot: () async {
                writes++;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      locked = true;
      await tester.tap(find.byKey(const Key('firefox-light-mode')));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(find.textContaining('Unlock protection settings'), findsOneWidget);
    },
  );
  testWidgets('six supported languages show translated performance labels', (
    tester,
  ) async {
    final labels = {
      'en': 'Firefox performance',
      'ko': 'Firefox 성능',
      'ja': 'Firefoxのパフォーマンス',
      'zh': 'Firefox 性能',
      'he': 'ביצועי Firefox',
      'ar': 'أداء Firefox',
    };
    for (final item in labels.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FirefoxPerformanceCard(
              key: ValueKey(item.key),
              locale: Locale(item.key),
              readFiltering: () async => true,
              settingsLocked: () async => false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(item.value), findsOneWidget);
    }
  });
}
