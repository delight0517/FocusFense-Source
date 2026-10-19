import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/active_app_block_entry.dart';
import 'package:six_clean_room/services/app_block_notice_builder.dart';

void main() {
  test('schedule app block notice includes unified reason tags', () {
    final ({String detail, String headline}) notice =
        AppBlockNoticeBuilder.build(
          appDisplayName: 'Firefox',
          context: const AppBlockContext(
            source: AppBlockSource.schedule,
            scheduleLabels: <String>['집중 시간'],
          ),
        );

    expect(notice.headline, contains('스케줄 차단'));
    expect(notice.detail, contains('집중 시간'));
    expect(notice.detail, contains('원인 태그:'));
    expect(notice.detail, contains('앱 실행 차단'));
    expect(notice.detail, contains('스케줄'));
  });

  test('merged app block context keeps both schedule and maintenance tags', () {
    final AppBlockContext merged =
        const AppBlockContext(
          source: AppBlockSource.schedule,
          scheduleLabels: <String>['저녁 차단'],
        ).merge(
          const AppBlockContext(
            source: AppBlockSource.maintenance,
            scheduleLabels: <String>[],
            maintenanceTitle: '정책 적용',
          ),
        );

    expect(merged.tagKeys, contains('schedule'));
    expect(merged.tagKeys, contains('maintenance'));
  });
}
