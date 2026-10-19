enum ChatScheduleCategory {
  sns,
  streaming,
  gaming,
  shopping,
  adult,
  browser,
  finance,
}

enum ChatScheduleMode { block, limit }

enum ChatScheduleChangeSafety { stronger, weaker, ambiguous }

final class ChatUsageBudgetPolicy {
  const ChatUsageBudgetPolicy({
    required this.enabled,
    required this.dailyCapMinutes,
    required this.burstCapMinutes,
    required this.refillIntervalMinutes,
    required this.cooldownMinutes,
  });

  final bool enabled;
  final int dailyCapMinutes;
  final int burstCapMinutes;
  final int refillIntervalMinutes;
  final int cooldownMinutes;

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'dailyCapMinutes': dailyCapMinutes,
    'burstCapMinutes': burstCapMinutes,
    'refillIntervalMinutes': refillIntervalMinutes,
    'cooldownMinutes': cooldownMinutes,
  };
}

final class ChatScheduleIntent {
  const ChatScheduleIntent({
    required this.customDomains,
    required this.customKeywords,
    required this.weekdays,
    required this.startMinutes,
    required this.endMinutes,
    required this.mode,
    required this.limitMinutesPerHour,
    required this.blockAlways,
    required this.confidence,
    this.scheduleNameHint,
    this.category,
    this.proposedScheduleName,
    this.usageBudgetPolicy,
    this.requestsTimeLock = false,
    this.resetExisting = false,
    this.usageBudgetTargetsApp = false,
    this.appNameHints = const <String>[],
    this.youtubeBudgetExemption = false,
    this.removeYoutubeBudgetExemption = false,
    this.listYoutubeBudgetExemptions = false,
    this.youtubeBudgetExemptionTargets = const <String>[],
  });

  final String? scheduleNameHint;
  final ChatScheduleCategory? category;
  final List<String> customDomains;
  final List<String> customKeywords;

  /// App convention: 0=Monday ... 6=Sunday.
  final List<int> weekdays;
  final int startMinutes;
  final int endMinutes;
  final ChatScheduleMode mode;
  final int limitMinutesPerHour;
  final bool blockAlways;
  final String? proposedScheduleName;
  final ChatUsageBudgetPolicy? usageBudgetPolicy;
  final double confidence;

  /// User asked to also enable the app-wide bypass Time Lock alongside this
  /// block (e.g. "음란물 차단하고 타임락 설정해줘") — see
  /// [ChatScheduleApplyService] / `RulesMeta.bypassTimeLockMinutes`.
  final bool requestsTimeLock;

  /// User asked to wipe the matched schedule's existing rules before
  /// applying this message's rules ("전부 초토화하고 덮어써줘").
  final bool resetExisting;

  /// True when [usageBudgetPolicy] should be applied to a matched app
  /// target (e.g. KakaoTalk) instead of the usual web-host targets — see
  /// "카카오톡 밤에... 10분마다 3분만" style commands.
  final bool usageBudgetTargetsApp;

  /// Canonical app ids recognized by name in the message (e.g.
  /// `'kakaotalk'`) — see [ChatScheduleIntentParser] dictionary and
  /// [ChatScheduleApplyService]'s app-target lookup.
  final List<String> appNameHints;
  final bool youtubeBudgetExemption;
  final bool removeYoutubeBudgetExemption;
  final bool listYoutubeBudgetExemptions;
  final List<String> youtubeBudgetExemptionTargets;

  String get categoryLabel {
    switch (category) {
      case ChatScheduleCategory.sns:
        return 'SNS';
      case ChatScheduleCategory.streaming:
        return '스트리밍';
      case ChatScheduleCategory.gaming:
        return '게임';
      case ChatScheduleCategory.shopping:
        return '쇼핑';
      case ChatScheduleCategory.adult:
        return '성인';
      case ChatScheduleCategory.browser:
        return 'Browsers';
      case ChatScheduleCategory.finance:
        return '증권/주식';
      case null:
        return '직접 입력';
    }
  }

  String get modeLabel => mode == ChatScheduleMode.limit ? '사용량 제한' : '완전 차단';

  Map<String, Object?> toJson() => <String, Object?>{
    'scheduleNameHint': scheduleNameHint,
    'category': category?.name,
    'customDomains': customDomains,
    'customKeywords': customKeywords,
    'weekdays': weekdays,
    'startMinutes': startMinutes,
    'endMinutes': endMinutes,
    'mode': mode.name,
    'limitMinutesPerHour': limitMinutesPerHour,
    'blockAlways': blockAlways,
    'proposedScheduleName': proposedScheduleName,
    'usageBudgetPolicy': usageBudgetPolicy?.toJson(),
    'confidence': confidence,
    'requestsTimeLock': requestsTimeLock,
    'resetExisting': resetExisting,
    'usageBudgetTargetsApp': usageBudgetTargetsApp,
    'appNameHints': appNameHints,
    'youtubeBudgetExemption': youtubeBudgetExemption,
    'removeYoutubeBudgetExemption': removeYoutubeBudgetExemption,
    'listYoutubeBudgetExemptions': listYoutubeBudgetExemptions,
    'youtubeBudgetExemptionTargets': youtubeBudgetExemptionTargets,
  };
}

final class ChatSchedulePreview {
  const ChatSchedulePreview({
    required this.intent,
    required this.scheduleId,
    required this.scheduleName,
    required this.willCreateSchedule,
    required this.domainTargets,
    required this.keywordTargets,
    required this.appTargets,
    required this.slotCount,
    required this.duplicateRuleCount,
    required this.summary,
    required this.warnings,
    required this.changeSafety,
    required this.requiresTimeLock,
    this.timeLockMinutes,
    this.similarScheduleReason,
    this.needsResolutionChoice = false,
    this.resolutionExistingName,
    this.resolutionNewName,
    this.youtubeBudgetExemptionEntries = const <Map<String, Object?>>[],
  });

  final ChatScheduleIntent intent;
  final String scheduleId;
  final String scheduleName;
  final bool willCreateSchedule;
  final List<String> domainTargets;
  final List<String> keywordTargets;
  final List<String> appTargets;
  final int slotCount;
  final int duplicateRuleCount;
  final String summary;
  final List<String> warnings;
  final ChatScheduleChangeSafety changeSafety;
  final bool requiresTimeLock;
  final int? timeLockMinutes;
  final String? similarScheduleReason;

  /// True when an existing similar browser schedule was found and the app
  /// can't safely guess whether the user wants to modify it or keep it
  /// untouched and create a separate one — the chat must ask before
  /// [ChatScheduleApplyService.apply] can do anything. See
  /// [resolutionExistingName] / [resolutionNewName] for the two choices.
  final bool needsResolutionChoice;
  final String? resolutionExistingName;
  final String? resolutionNewName;
  final List<Map<String, Object?>> youtubeBudgetExemptionEntries;

  Map<String, Object?> toJson() => <String, Object?>{
    'intent': intent.toJson(),
    'scheduleId': scheduleId,
    'scheduleName': scheduleName,
    'willCreateSchedule': willCreateSchedule,
    'domainTargets': domainTargets,
    'keywordTargets': keywordTargets,
    'appTargets': appTargets,
    'slotCount': slotCount,
    'duplicateRuleCount': duplicateRuleCount,
    'summary': summary,
    'warnings': warnings,
    'changeSafety': changeSafety.name,
    'requiresTimeLock': requiresTimeLock,
    'timeLockMinutes': timeLockMinutes,
    'similarScheduleReason': similarScheduleReason,
    'needsResolutionChoice': needsResolutionChoice,
    'resolutionExistingName': resolutionExistingName,
    'resolutionNewName': resolutionNewName,
    'youtubeBudgetExemptionEntries': youtubeBudgetExemptionEntries,
  };
}

final class ChatSchedulePendingEdit {
  const ChatSchedulePendingEdit({
    required this.id,
    required this.message,
    required this.scheduleId,
    required this.scheduleName,
    required this.createdAtMs,
    required this.applyAfterMs,
    required this.summary,
    this.resolution,
    this.forceScheduleId,
  });

  final String id;
  final String message;
  final String scheduleId;
  final String scheduleName;
  final int createdAtMs;
  final int applyAfterMs;
  final String summary;

  /// The existing-vs-new choice the user already made (if any) before this
  /// edit was queued — replayed unattended by [processDuePendingEdits], so
  /// it must not re-ask the question at that point.
  final String? resolution;

  /// Set when this edit came from a chat scoped to one specific schedule
  /// (e.g. the chat panel inside `ScheduleEditScreen`). Replaying this edit
  /// later via [processDuePendingEdits] must keep targeting that exact
  /// schedule — re-resolving by name at replay time could otherwise land on
  /// a different schedule than the one the user was actually looking at.
  final String? forceScheduleId;

  Duration remaining(DateTime now) {
    final int ms = applyAfterMs - now.millisecondsSinceEpoch;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'message': message,
    'scheduleId': scheduleId,
    'scheduleName': scheduleName,
    'createdAtMs': createdAtMs,
    'applyAfterMs': applyAfterMs,
    'summary': summary,
    'resolution': resolution,
    'forceScheduleId': forceScheduleId,
  };

  static ChatSchedulePendingEdit? fromJson(Object? value) {
    if (value is! Map) return null;
    final String id = '${value['id'] ?? ''}';
    final String message = '${value['message'] ?? ''}';
    final String scheduleId = '${value['scheduleId'] ?? ''}';
    final String scheduleName = '${value['scheduleName'] ?? ''}';
    final int? createdAtMs = _intFrom(value['createdAtMs']);
    final int? applyAfterMs = _intFrom(value['applyAfterMs']);
    final String summary = '${value['summary'] ?? ''}';
    final String? resolution = value['resolution'] == null
        ? null
        : '${value['resolution']}';
    final String? forceScheduleId = value['forceScheduleId'] == null
        ? null
        : '${value['forceScheduleId']}';
    if (id.isEmpty ||
        message.isEmpty ||
        scheduleId.isEmpty ||
        createdAtMs == null ||
        applyAfterMs == null) {
      return null;
    }
    return ChatSchedulePendingEdit(
      id: id,
      message: message,
      scheduleId: scheduleId,
      scheduleName: scheduleName,
      createdAtMs: createdAtMs,
      applyAfterMs: applyAfterMs,
      summary: summary,
      resolution: resolution,
      forceScheduleId: forceScheduleId,
    );
  }

  static int? _intFrom(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }
}

final class ChatScheduleApplyResult {
  const ChatScheduleApplyResult({
    required this.ok,
    required this.preview,
    required this.message,
    required this.domainsAdded,
    required this.keywordsAdded,
    required this.appsAdded,
    required this.slotsAdded,
    required this.usageLimitsAdded,
    this.pendingEdit,
  });

  final bool ok;
  final ChatSchedulePreview preview;
  final String message;
  final int domainsAdded;
  final int keywordsAdded;
  final int appsAdded;
  final int slotsAdded;
  final int usageLimitsAdded;
  final ChatSchedulePendingEdit? pendingEdit;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'preview': preview.toJson(),
    'message': message,
    'domainsAdded': domainsAdded,
    'keywordsAdded': keywordsAdded,
    'appsAdded': appsAdded,
    'slotsAdded': slotsAdded,
    'usageLimitsAdded': usageLimitsAdded,
    'pendingEdit': pendingEdit?.toJson(),
  };
}
