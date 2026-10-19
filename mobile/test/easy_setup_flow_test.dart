import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/screens/easy_setup_wizard_screen.dart';
import 'package:six_clean_room/widgets/protection_setup_overview.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'easy setup has one visible action and no advanced probes at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          const MaterialApp(home: EasySetupWizardScreen()),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ProtectionSetupOverview), findsOneWidget);
        expect(find.text('보호 설정 시작').hitTestable(), findsOneWidget);
        expect(find.byType(FilledButton), findsOneWidget);
        expect(find.byType(Checkbox), findsNothing);
        expect(find.text('리포트 형식'), findsNothing);
        expect(find.text('"이미 실행 중" 잠금 강제 해제'), findsNothing);
        expect(find.textContaining('모든 단계 완료'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
