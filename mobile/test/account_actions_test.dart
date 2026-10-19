import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/widgets/account_actions.dart';

void main() {
  testWidgets(
    'account actions fit narrow and desktop widths and open AI connections',
    (tester) async {
      for (final width in [360.0, 1200.0]) {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Column(children: [AccountActions()])),
          ),
        );
        expect(find.text('블루클라우드 로그인'), findsOneWidget);
        expect(find.text('GPT · AI 로그인'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('ai-account')));
        await tester.pumpAndSettle();
        expect(find.text('Continue with ChatGPT'), findsOneWidget);
        expect(find.text('AI 채팅 열기'), findsOneWidget);
        await tester.tap(find.text('닫기'));
        await tester.pumpAndSettle();
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
}

