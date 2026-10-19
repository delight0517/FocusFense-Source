import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/chat_schedule_intent.dart';
import 'package:six_clean_room/services/chat_schedule_intent_parser.dart';

void main() {
  final ChatScheduleIntentParser parser = ChatScheduleIntentParser.instance;

  test('parses daily YouTube block from 10 to midnight', () {
    final ChatScheduleIntent intent = parser.parse('매일 아침 10시 유튜브 막아줘');

    expect(intent.category, ChatScheduleCategory.streaming);
    expect(intent.weekdays, <int>[0, 1, 2, 3, 4, 5, 6]);
    expect(intent.startMinutes, 600);
    expect(intent.endMinutes, 1440);
    expect(intent.mode, ChatScheduleMode.block);
  });

  test('parses named overnight game schedule', () {
    final ChatScheduleIntent intent = parser.parse(
      'Game 스케줄에 매일 밤 10시부터 새벽 2시까지 게임 막아줘',
    );

    expect(intent.scheduleNameHint, 'Game');
    expect(intent.category, ChatScheduleCategory.gaming);
    expect(intent.startMinutes, 1320);
    expect(intent.endMinutes, 120);
  });

  test('parses weekday limit command', () {
    final ChatScheduleIntent intent = parser.parse('평일 오전 10시 유튜브 10분만');

    expect(intent.category, ChatScheduleCategory.streaming);
    expect(intent.weekdays, <int>[0, 1, 2, 3, 4]);
    expect(intent.startMinutes, 600);
    expect(intent.mode, ChatScheduleMode.limit);
    expect(intent.limitMinutesPerHour, 10);
    expect(intent.usageBudgetPolicy?.burstCapMinutes, 10);
  });

  test('parses custom domain', () {
    final ChatScheduleIntent intent = parser.parse(
      '주말 9시-18시 gmarket.co.kr 쇼핑 막아줘',
    );

    expect(intent.category, ChatScheduleCategory.shopping);
    expect(intent.customDomains, contains('gmarket.co.kr'));
    expect(intent.weekdays, <int>[5, 6]);
    expect(intent.startMinutes, 540);
    expect(intent.endMinutes, 1080);
  });

  test('parses adult block with time lock request', () {
    final ChatScheduleIntent intent = parser.parse('모든 음란물을 차단하고 타임락 설정해줘');

    expect(intent.category, ChatScheduleCategory.adult);
    expect(intent.mode, ChatScheduleMode.block);
    expect(intent.blockAlways, isTrue);
    expect(intent.requestsTimeLock, isTrue);
  });

  test('parses gaming channel block request', () {
    final ChatScheduleIntent intent = parser.parse('모든 게임 채널 차단해줘');

    expect(intent.category, ChatScheduleCategory.gaming);
    expect(intent.mode, ChatScheduleMode.block);
  });

  test('parses morning finance block and follow-up target category', () {
    final ChatScheduleIntent intent = parser.parse('매일 아침 주식 관련 앱들을 차단해주라');

    expect(intent.category, ChatScheduleCategory.finance);
    expect(intent.weekdays, <int>[0, 1, 2, 3, 4, 5, 6]);
    expect(intent.startMinutes, 360);
    expect(intent.endMinutes, 540);
  });

  test('parses YouTube Music reset and overwrite command', () {
    final ChatScheduleIntent intent = parser.parse(
      '유튜브 뮤직 블락 관련 스케줄 전부 초토화, 리셋 이후에 다시 아래 스케줄으로 덮어쓰기 해줘',
    );

    expect(intent.category, ChatScheduleCategory.streaming);
    expect(intent.customDomains, contains('music.youtube.com'));
    expect(intent.resetExisting, isTrue);
  });

  test('parses KakaoTalk interval viewing command', () {
    final ChatScheduleIntent intent = parser.parse(
      '카카오톡 밤에 통째로 블락 말고, 밤에는 10분 마다 3분만 보기로 변형해줘',
    );

    expect(intent.appNameHints, contains('kakaotalk'));
    expect(intent.usageBudgetTargetsApp, isTrue);
    expect(intent.mode, ChatScheduleMode.limit);
    expect(intent.usageBudgetPolicy?.burstCapMinutes, 3);
    expect(intent.usageBudgetPolicy?.refillIntervalMinutes, 10);
    expect(intent.startMinutes, 1260);
    expect(intent.endMinutes, 1440);
  });
}
