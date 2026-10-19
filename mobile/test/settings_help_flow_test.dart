import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/screens/settings_diagnostics_tab.dart';
import 'package:six_clean_room/widgets/live_block_status_card.dart';
import 'package:six_clean_room/widgets/url_live_test_card.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets('help starts without probes or overflow at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsDiagnosticsTab(buildTagLine: 'test build'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('차단 설정 점검·복구'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(LiveBlockStatusCard), findsNothing);
      expect(find.byType(UrlLiveTestCard), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('차단 설정 점검·복구'));
      await tester.pumpAndSettle();
      expect(find.text('보호 설정 시작'), findsOneWidget);
      expect(find.text('"이미 실행 중" 잠금 강제 해제'), findsNothing);
      expect(find.text('리포트 형식'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
