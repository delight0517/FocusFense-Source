import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/chat_schedule_intent_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/services/chat_schedule_apply_service.dart';
import 'package:six_clean_room/services/youtube_budget_exemption_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final parser = ChatScheduleIntentParser.instance;
  test(
    'exact user request preserves video ID and chooses accounting exemption',
    () {
      final intent = parser.parse(
        '이 아래 채널들은 유튜브 시간 재는거에서 예외로 해줘 https://www.youtube.com/watch?v=YKi9KlVDInQ',
      );
      expect(intent.youtubeBudgetExemption, true);
      expect(intent.youtubeBudgetExemptionTargets, [
        'https://www.youtube.com/watch?v=YKi9KlVDInQ',
      ]);
      expect(intent.customDomains, isEmpty);
      expect(intent.customKeywords, isEmpty);
      expect(intent.category, isNull);
      expect(intent.removeYoutubeBudgetExemption, false);
      expect(intent.requestsTimeLock, false);
    },
  );
  test(
    'remove and list distinguish accounting actions from schedule rules',
    () {
      final remove = parser.parse(
        '유튜브 시간 예외에서 삭제 https://www.youtube.com/@onlylord',
      );
      expect(remove.removeYoutubeBudgetExemption, true);
      expect(remove.listYoutubeBudgetExemptions, false);
      expect(
        parser.parse('유튜브 시간 예외 목록 보여줘').listYoutubeBudgetExemptions,
        true,
      );
      expect(
        parser.parse('평일 9시부터 18시까지 유튜브 막아줘').youtubeBudgetExemption,
        false,
      );
      expect(parser.parse('성인 사이트 항상 차단').youtubeBudgetExemption, false);
    },
  );
  test('unresolved target does not become blanket YouTube allowance', () {
    expect(() => parser.parse('유튜브 시간 예외로 해줘'), throwsFormatException);
    final intent = parser.parse('시청 시간 예외로 해줘 https://example.org/education');
    expect(intent.youtubeBudgetExemptionTargets, [
      'https://example.org/education',
    ]);
    expect(intent.customDomains, isEmpty);
  });
  test(
    'chat preview and apply change only accounting entries, not schedules',
    () async {
      SharedPreferences.setMockInitialValues({
        'unchanged_rule_marker': 'adult-on',
      });
      const request = '유튜브 시간 예외로 해줘 https://www.youtube.com/@onlylord';
      final service = ChatScheduleApplyService.instance;
      final preview = await service.preview(
        request,
        parserMessage: '유튜브 항상 차단',
      );
      expect(preview.intent.youtubeBudgetExemption, true);
      expect(preview.willCreateSchedule, false);
      expect(preview.requiresTimeLock, false);
      expect(preview.youtubeBudgetExemptionEntries.single['value'], 'onlylord');
      expect(await YoutubeBudgetExemptionStore.instance.entries(), isEmpty);
      final result = await service.apply(request);
      expect(result.ok, true);
      expect(
        result.domainsAdded +
            result.keywordsAdded +
            result.appsAdded +
            result.slotsAdded +
            result.usageLimitsAdded,
        0,
      );
      expect(
        (await YoutubeBudgetExemptionStore.instance.entries()).single['value'],
        'onlylord',
      );
      final listed = await service.preview('유튜브 시간 예외 목록 보여줘');
      expect(listed.summary, contains('@onlylord'));
      await service.apply('유튜브 시간 예외 삭제 https://www.youtube.com/@onlylord');
      expect(await YoutubeBudgetExemptionStore.instance.entries(), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'unchanged_rule_marker',
        ),
        'adult-on',
      );
    },
  );
}
