import 'block_app.dart';

/// Why an executable is on the active kill list right now.
enum AppBlockSource { schedule, quickBlock, maintenance }

/// Shared tags used by notifications, logs, and diagnostics to explain a block.
enum AppBlockTag {
  appLaunch,
  schedule,
  quickBlock,
  maintenance,
  urlPolicy,
  browserExtension,
  dnsHosts,
  osGuard,
}

extension AppBlockTagCopy on AppBlockTag {
  String get key => switch (this) {
    AppBlockTag.appLaunch => 'app_launch',
    AppBlockTag.schedule => 'schedule',
    AppBlockTag.quickBlock => 'quick_block',
    AppBlockTag.maintenance => 'maintenance',
    AppBlockTag.urlPolicy => 'url_policy',
    AppBlockTag.browserExtension => 'browser_extension',
    AppBlockTag.dnsHosts => 'dns_hosts',
    AppBlockTag.osGuard => 'os_guard',
  };

  String get labelKo => switch (this) {
    AppBlockTag.appLaunch => '앱 실행 차단',
    AppBlockTag.schedule => '스케줄',
    AppBlockTag.quickBlock => '빠른 차단',
    AppBlockTag.maintenance => '정책 적용',
    AppBlockTag.urlPolicy => 'URL 정책',
    AppBlockTag.browserExtension => '브라우저 플러그인',
    AppBlockTag.dnsHosts => 'DNS/hosts',
    AppBlockTag.osGuard => '시스템 보호',
  };
}

/// Human-facing block reason for notifications.
final class AppBlockContext {
  const AppBlockContext({
    required this.source,
    required this.scheduleLabels,
    this.endsAt,
    this.maintenanceTitle,
    this.maintenanceDetail,
    this.extraTags = const <AppBlockTag>[],
    this.browserReleaseHold = false,
  });

  final AppBlockSource source;
  final List<String> scheduleLabels;
  final DateTime? endsAt;
  final String? maintenanceTitle;
  final String? maintenanceDetail;
  final List<AppBlockTag> extraTags;
  final bool browserReleaseHold;

  List<AppBlockTag> get tags {
    final Set<AppBlockTag> out = <AppBlockTag>{AppBlockTag.appLaunch};
    switch (source) {
      case AppBlockSource.schedule:
        out.add(AppBlockTag.schedule);
      case AppBlockSource.quickBlock:
        out.add(AppBlockTag.quickBlock);
      case AppBlockSource.maintenance:
        out.add(AppBlockTag.maintenance);
    }
    if (scheduleLabels.isNotEmpty) out.add(AppBlockTag.schedule);
    if ((maintenanceTitle?.trim().isNotEmpty ?? false) ||
        (maintenanceDetail?.trim().isNotEmpty ?? false)) {
      out.add(AppBlockTag.maintenance);
    }
    out.addAll(extraTags);
    return out.toList(growable: false);
  }

  List<String> get tagKeys =>
      tags.map((AppBlockTag tag) => tag.key).toList(growable: false);

  String get tagLineKo =>
      tags.map((AppBlockTag tag) => tag.labelKo).join(' · ');

  AppBlockContext merge(AppBlockContext other) {
    return AppBlockContext(
      source:
          source == AppBlockSource.quickBlock ||
              other.source == AppBlockSource.quickBlock
          ? AppBlockSource.quickBlock
          : source,
      scheduleLabels: <String>{
        ...scheduleLabels,
        ...other.scheduleLabels,
      }.toList(),
      endsAt: _earlierEnd(endsAt, other.endsAt),
      maintenanceTitle: maintenanceTitle ?? other.maintenanceTitle,
      maintenanceDetail: maintenanceDetail ?? other.maintenanceDetail,
      extraTags: <AppBlockTag>{
        ...extraTags,
        ...other.extraTags,
        ...tags,
        ...other.tags,
      }.toList(),
      browserReleaseHold: browserReleaseHold || other.browserReleaseHold,
    );
  }

  static DateTime? _earlierEnd(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isBefore(b) ? a : b;
  }
}

/// [BlockApp] plus the schedules / sessions that block it now.
final class ActiveAppBlockEntry {
  const ActiveAppBlockEntry({required this.app, required this.context});

  final BlockApp app;
  final AppBlockContext context;

  String get dedupeKey {
    final BlockApp b = app;
    if (b.exeName.isEmpty) {
      return 'lt:${(b.windowTitleMatch ?? b.displayName).toLowerCase()}';
    }
    if (b.isPwa) return '${b.exeName}?${b.chromeAppId}';
    return b.exeName;
  }
}
