import '../models/active_app_block_entry.dart';

/// Korean copy for schedule / quick-block app launch blocks.
final class AppBlockNoticeBuilder {
  AppBlockNoticeBuilder._();

  static ({String headline, String detail}) build({
    required String appDisplayName,
    required AppBlockContext context,
  }) {
    final String until = _formatUntil(context.endsAt);
    final String tagLine = _formatTags(context);
    switch (context.source) {
      case AppBlockSource.quickBlock:
        return (
          headline: '$appDisplayName - 빠른 차단 중',
          detail: _withTags(
            until.isNotEmpty
                ? '지금은 빠른 차단 세션이 켜져 있어 실행할 수 없습니다. $until'
                : '지금은 빠른 차단 세션이 켜져 있어 실행할 수 없습니다.',
            tagLine,
          ),
        );
      case AppBlockSource.maintenance:
        final String title = context.maintenanceTitle?.trim().isNotEmpty == true
            ? context.maintenanceTitle!.trim()
            : '앱 업데이트/정책 적용';
        final String extra = context.maintenanceDetail?.trim() ?? '';
        return (
          headline: '$appDisplayName - 일시 차단 ($title)',
          detail: _withTags(
            extra.isNotEmpty
                ? '$extra 완료될 때까지 이 앱은 열 수 없습니다.'
                : '$title 작업이 끝날 때까지 이 앱은 열 수 없습니다.',
            tagLine,
          ),
        );
      case AppBlockSource.schedule:
        final String labels = context.scheduleLabels.isEmpty
            ? '활성 스케줄'
            : context.scheduleLabels.map((String s) => '"$s"').join(', ');
        return (
          headline: '$appDisplayName - 스케줄 차단',
          detail: _withTags(
            until.isNotEmpty
                ? '$labels 시간대에 이 앱은 사용할 수 없습니다. $until'
                : '$labels 시간대에 이 앱은 사용할 수 없습니다.',
            tagLine,
          ),
        );
    }
  }

  static String _formatTags(AppBlockContext context) {
    final String tags = context.tagLineKo;
    if (tags.isEmpty) return '';
    return '원인 태그: $tags';
  }

  static String _withTags(String detail, String tagLine) {
    if (tagLine.isEmpty) return detail;
    return '$detail\n$tagLine';
  }

  static String _formatUntil(DateTime? endsAt) {
    if (endsAt == null) return '';
    final DateTime now = DateTime.now();
    if (!endsAt.isAfter(now)) return '';
    final Duration left = endsAt.difference(now);
    final String hm =
        '${endsAt.hour.toString().padLeft(2, '0')}:${endsAt.minute.toString().padLeft(2, '0')}';
    if (left.inHours >= 1) {
      return '해제 예상: 오늘 $hm (${left.inHours}시간 ${left.inMinutes % 60}분 후)';
    }
    if (left.inMinutes >= 1) {
      return '해제 예상: 오늘 $hm (${left.inMinutes}분 후)';
    }
    return '곧 해제 예정 ($hm)';
  }
}
