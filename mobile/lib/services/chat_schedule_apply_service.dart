import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/schedule_domain_presets.dart';
import '../models/block_app.dart';
import '../models/chat_schedule_intent.dart';
import '../models/rules_meta.dart';
import 'block_sync_service.dart';
import 'chat_schedule_intent_parser.dart';
import 'local_database.dart';
import 'schedule_rule_validation.dart';
import 'usage_quota_enforcer_service.dart';
import 'youtube_budget_exemption_store.dart';

/// Reply values for the "modify existing vs create separate" chat question —
/// see [ChatSchedulePreview.needsResolutionChoice].
///
/// Chat apply has a single-decision contract: preview returns exactly one next
/// action. A normal preview needs one apply click; a resolution preview commits
/// when the user chooses existing/new; a time-locked weakening queues one
/// pending edit. Do not add a second confirmation layer on top of these.
const String kChatScheduleResolutionExisting = 'existing';
const String kChatScheduleResolutionNew = 'new';

final class ChatScheduleApplyService {
  ChatScheduleApplyService._();
  static final ChatScheduleApplyService instance = ChatScheduleApplyService._();

  static const String _pendingEditsKey = 'chat_schedule_pending_edits_v1';

  final LocalDatabase _db = LocalDatabase.instance;
  final ChatScheduleIntentParser _parser = ChatScheduleIntentParser.instance;

  /// [resolution] is the user's answer (once asked) to "modify the existing
  /// similar schedule, or create a separate one?" — see
  /// [kChatScheduleResolutionExisting] / [kChatScheduleResolutionNew]. Pass
  /// null on the first call; if the result comes back with
  /// [ChatSchedulePreview.needsResolutionChoice], ask the user and call again
  /// with their choice.
  ///
  /// [forceScheduleId] pins the target schedule (used by the chat panel
  /// embedded in `ScheduleEditScreen`, scoped to one specific schedule) —
  /// when set, name-matching/similarity resolution and the "modify existing
  /// vs create new" question are skipped entirely; every edit always lands
  /// on that exact schedule.
  Future<ChatSchedulePreview> preview(
    String message, {
    String? resolution,
    String? forceScheduleId,
    String? parserMessage,
  }) async {
    final ChatScheduleIntent intent = _parser.parse(
      ChatScheduleIntentParser.isYoutubeBudgetExemptionRequest(message)
          ? message
          : parserMessage ?? message,
    );
    if (intent.youtubeBudgetExemption) {
      return _previewYoutubeBudgetExemption(intent);
    }
    final _TargetSchedule target = await _resolveSchedule(
      intent,
      resolution: resolution,
      forceScheduleId: forceScheduleId,
    );
    if (target.needsChoice) {
      return ChatSchedulePreview(
        intent: intent,
        scheduleId: target.id,
        scheduleName: target.name,
        willCreateSchedule: false,
        domainTargets: const <String>[],
        keywordTargets: const <String>[],
        appTargets: const <String>[],
        slotCount: 0,
        duplicateRuleCount: 0,
        summary:
            '이미 브라우저 관련 스케줄 "${target.name}"이(가) 있어요 — ${target.similarReason ?? ''} '
            '그 스케줄을 이 내용으로 수정할까요, 아니면 별도 스케줄을 새로 만들까요?',
        warnings: const <String>[],
        changeSafety: ChatScheduleChangeSafety.ambiguous,
        requiresTimeLock: false,
        needsResolutionChoice: true,
        resolutionExistingName: target.name,
        resolutionNewName: target.proposedNewName,
        similarScheduleReason: target.similarReason,
      );
    }
    final _Targets targets = _targetsFor(intent);
    final List<Map<String, Object?>> existingDomains = target.exists
        ? await _db.domainsForSchedule(target.id)
        : const [];
    final List<Map<String, Object?>> existingKeywords = target.exists
        ? await _db.keywordsForSchedule(target.id)
        : const [];
    final List<Map<String, Object?>> existingApps = target.exists
        ? await _db.appsForSchedule(target.id)
        : const [];
    final Set<String> existingDomainSet = existingDomains
        .map((Map<String, Object?> row) => '${row['host']}'.toLowerCase())
        .toSet();
    final Set<String> existingKeywordSet = existingKeywords
        .map((Map<String, Object?> row) => '${row['pattern']}'.toLowerCase())
        .toSet();
    final Set<String> existingAppSet = existingApps
        .map((Map<String, Object?> row) => _appRowKey(row))
        .toSet();
    final int duplicateRules =
        targets.domains
            .where((String host) => existingDomainSet.contains(host))
            .length +
        targets.keywords
            .where((String kw) => existingKeywordSet.contains(kw))
            .length +
        targets.apps
            .where((_AppTarget app) => existingAppSet.contains(app.key))
            .length;
    final _SafetyDecision safety = await _classifySafety(intent, target);
    final List<String> warnings = <String>[];
    if (intent.confidence < 0.45) {
      warnings.add('해석 confidence가 낮습니다. 적용 전에 내용을 확인하세요.');
    }
    if (intent.mode == ChatScheduleMode.limit) {
      warnings.add('사용량 제한은 현재 대상 사이트별 quota로 적용됩니다.');
    }
    if (targets.domains.isEmpty &&
        targets.keywords.isEmpty &&
        targets.apps.isEmpty) {
      warnings.add('대상 규칙이 비어 있습니다. 더 구체적인 사이트나 카테고리를 말해주세요.');
    }
    if (safety.requiresTimeLock) {
      warnings.add(
        '기존 스케줄을 약하게 만들 수 있어 적용하면 ${safety.timeLockMinutes}분 타임락 후 자동 적용됩니다.',
      );
    }
    if (target.lockPhase == ScheduleLockPhase.locked ||
        target.lockPhase == ScheduleLockPhase.countdown) {
      warnings.add('대상 스케줄이 잠겨 있어 지금은 적용할 수 없습니다.');
    }

    if (target.similarReason != null) {
      warnings.add(
        'Similar browser schedule found: ${target.similarReason}. Applying will update that schedule instead of creating a duplicate.',
      );
    }

    return ChatSchedulePreview(
      intent: intent,
      scheduleId: target.id,
      scheduleName: target.name,
      willCreateSchedule: !target.exists,
      domainTargets: targets.domains,
      keywordTargets: targets.keywords,
      appTargets: targets.apps
          .map((_AppTarget app) => app.displayName)
          .toList(),
      slotCount: _slotPieces(intent).length,
      duplicateRuleCount: duplicateRules,
      summary: _summary(intent, target.name, targets),
      warnings: warnings,
      changeSafety: safety.safety,
      requiresTimeLock: safety.requiresTimeLock,
      timeLockMinutes: safety.requiresTimeLock ? safety.timeLockMinutes : null,
      similarScheduleReason: target.similarReason,
    );
  }

  Future<ChatScheduleApplyResult> apply(
    String message, {
    String? resolution,
    String? forceScheduleId,
    String? parserMessage,
    bool debugOverride = false,
  }) async {
    final ChatSchedulePreview p = await preview(
      message,
      resolution: resolution,
      forceScheduleId: forceScheduleId,
      parserMessage: parserMessage,
    );
    if (p.intent.youtubeBudgetExemption) {
      final entries = p.youtubeBudgetExemptionEntries;
      final listing = p.intent.listYoutubeBudgetExemptions;
      final ok = listing || entries.isNotEmpty;
      if (ok && !listing) {
        if (p.intent.removeYoutubeBudgetExemption) {
          await YoutubeBudgetExemptionStore.instance.removeEntries(entries);
        } else {
          await YoutubeBudgetExemptionStore.instance.addEntries(entries);
        }
      }
      return ChatScheduleApplyResult(
        ok: ok,
        preview: p,
        message: ok
            ? (listing
                  ? p.summary
                  : '유튜브 시간 집계 예외 ${p.intent.removeYoutubeBudgetExemption ? '삭제' : '추가'} 완료. 다른 영상의 시간 제한과 기존 차단 규칙은 유지됩니다.')
            : p.summary,
        domainsAdded: 0,
        keywordsAdded: 0,
        appsAdded: 0,
        slotsAdded: 0,
        usageLimitsAdded: 0,
      );
    }
    if (p.needsResolutionChoice) {
      return ChatScheduleApplyResult(
        ok: false,
        preview: p,
        message: p.summary,
        domainsAdded: 0,
        keywordsAdded: 0,
        appsAdded: 0,
        slotsAdded: 0,
        usageLimitsAdded: 0,
      );
    }
    if (p.requiresTimeLock && !debugOverride) {
      final ChatSchedulePendingEdit pending = await _enqueuePendingEdit(
        message: parserMessage ?? message,
        preview: p,
        resolution: resolution,
        forceScheduleId: forceScheduleId,
      );
      return ChatScheduleApplyResult(
        ok: true,
        preview: p,
        message:
            '수정 예약됨: ${p.scheduleName} 변경은 ${p.timeLockMinutes}분 뒤 자동 적용됩니다. 그 전에는 취소할 수 있습니다.',
        domainsAdded: 0,
        keywordsAdded: 0,
        appsAdded: 0,
        slotsAdded: 0,
        usageLimitsAdded: 0,
        pendingEdit: pending,
      );
    }
    return _applyNow(
      message,
      allowTimeLockedWeakening: debugOverride,
      resolution: resolution,
      forceScheduleId: forceScheduleId,
      parserMessage: parserMessage,
    );
  }

  Future<ChatSchedulePreview> _previewYoutubeBudgetExemption(
    ChatScheduleIntent intent,
  ) async {
    List<Map<String, Object?>> entries = const [];
    final warnings = <String>[];
    try {
      entries = intent.listYoutubeBudgetExemptions
          ? await YoutubeBudgetExemptionStore.instance.entries()
          : await YoutubeBudgetExemptionStore.instance.resolveTargets(
              intent.youtubeBudgetExemptionTargets,
            );
      if (entries.isEmpty && !intent.listYoutubeBudgetExemptions) {
        warnings.add('채널 소유자를 확인하지 못했습니다. 정확한 채널 주소를 입력해 주세요.');
      }
    } catch (_) {
      warnings.add(
        '주소의 채널 소유자를 확인하지 못해 예외를 추가하지 않습니다. 채널 주소 또는 연결 상태를 확인해 주세요.',
      );
    }
    final labels = entries
        .map((entry) => '${entry['label'] ?? entry['value'] ?? ''}')
        .where((label) => label.isNotEmpty)
        .toList();
    final action = intent.listYoutubeBudgetExemptions
        ? '목록'
        : intent.removeYoutubeBudgetExemption
        ? '삭제'
        : '추가';
    final summary =
        '유튜브 시간 집계 예외 $action${labels.isEmpty ? ': 없음' : ': ${labels.join(', ')}'}\n'
        '예외 채널·사이트의 재생 시간은 사용량에 더하지 않습니다. 다른 영상의 1시간당 10분 제한과 기존 사이트·성인·채널 차단은 유지합니다.';
    return ChatSchedulePreview(
      intent: intent,
      scheduleId: 'youtube_budget_exemptions',
      scheduleName: '유튜브 시간 집계 예외',
      willCreateSchedule: false,
      domainTargets: labels,
      keywordTargets: const [],
      appTargets: const [],
      slotCount: 0,
      duplicateRuleCount: 0,
      summary: summary,
      warnings: warnings,
      changeSafety: ChatScheduleChangeSafety.ambiguous,
      requiresTimeLock: false,
      youtubeBudgetExemptionEntries: entries,
    );
  }

  Future<ChatScheduleApplyResult> _applyNow(
    String message, {
    required bool allowTimeLockedWeakening,
    String? resolution,
    String? forceScheduleId,
    String? parserMessage,
  }) async {
    final ChatSchedulePreview p = await preview(
      message,
      resolution: resolution,
      forceScheduleId: forceScheduleId,
      parserMessage: parserMessage,
    );
    final ChatScheduleIntent intent = p.intent;
    final ({ScheduleLockPhase phase, DateTime? transitionAt}) lock = await _db
        .scheduleLockPhase(p.scheduleId);
    if (!allowTimeLockedWeakening &&
        p.requiresTimeLock &&
        (lock.phase == ScheduleLockPhase.locked ||
            lock.phase == ScheduleLockPhase.countdown)) {
      return ChatScheduleApplyResult(
        ok: false,
        preview: p,
        message: '잠긴 스케줄입니다. 편집창을 연 뒤 다시 적용해주세요.',
        domainsAdded: 0,
        keywordsAdded: 0,
        appsAdded: 0,
        slotsAdded: 0,
        usageLimitsAdded: 0,
      );
    }

    // "전부 초토화하고 덮어써줘" — wipe this schedule's existing rules first. Only
    // reachable past the lock/time-lock gate above, so a weakening reset
    // still has to go through the normal cooldown like any other change.
    List<String> kakaoTalkRemovedFrom = const <String>[];
    if (intent.resetExisting && !p.willCreateSchedule) {
      await _wipeScheduleRules(p.scheduleId);
    }
    if (intent.usageBudgetTargetsApp &&
        intent.appNameHints.contains('kakaotalk')) {
      kakaoTalkRemovedFrom = await _removeAppFromOtherSchedules(
        appNamePattern: RegExp(r'카카오톡|카톡|kakaotalk', caseSensitive: false),
        exceptScheduleId: p.scheduleId,
      );
    }

    final int daysMask = _daysMask(intent.weekdays);
    await _db.upsertSchedule(
      id: p.scheduleId,
      name: p.scheduleName,
      startMinute: intent.startMinutes,
      endMinute: intent.endMinutes >= 1440 ? 0 : intent.endMinutes,
      daysMask: daysMask,
      enabled: true,
    );

    int slotsAdded = 0;
    if (p.similarScheduleReason != null) {
      await _db.deleteSlotsForSchedule(p.scheduleId);
    }
    final List<Map<String, Object?>> slots = await _db.slotsForSchedule(
      p.scheduleId,
    );
    final Set<String> existingSlots = slots
        .map(
          (Map<String, Object?> row) =>
              '${row['day']}|${row['start_minute']}|${row['end_minute']}',
        )
        .toSet();
    final List<_SlotPiece> slotPieces = intent.usageBudgetTargetsApp
        ? _intervalSlotPieces(intent)
        : _slotPieces(intent);
    for (final _SlotPiece slot in slotPieces) {
      final String key = '${slot.day}|${slot.start}|${slot.end}';
      if (existingSlots.contains(key)) continue;
      await _db.insertSlot(
        id: _newId('chat_slot'),
        scheduleId: p.scheduleId,
        day: slot.day,
        startMinute: slot.start,
        endMinute: slot.end,
      );
      slotsAdded++;
    }

    int domainsAdded = 0;
    int keywordsAdded = 0;
    int appsAdded = 0;
    int usageLimitsAdded = 0;
    final Set<String> existingDomains =
        (await _db.domainsForSchedule(p.scheduleId))
            .map((Map<String, Object?> row) => '${row['host']}'.toLowerCase())
            .toSet();
    final Set<String> existingKeywords =
        (await _db.keywordsForSchedule(p.scheduleId))
            .map(
              (Map<String, Object?> row) => '${row['pattern']}'.toLowerCase(),
            )
            .toSet();
    final Set<String> existingApps = (await _db.appsForSchedule(
      p.scheduleId,
    )).map((Map<String, Object?> row) => _appRowKey(row)).toSet();

    if (intent.mode == ChatScheduleMode.block) {
      for (final _AppTarget app in _targetsFor(intent).apps) {
        if (existingApps.contains(app.key)) continue;
        final String? err = ScheduleRuleValidation.validateAppName(
          app.displayName,
        );
        if (err != null) continue;
        await _db.insertBlockedApp(
          id: _newId('chat_app'),
          name: app.displayName,
          scheduleId: p.scheduleId,
          bundleId: app.bundleId,
        );
        existingApps.add(app.key);
        appsAdded++;
      }
      for (final String host in p.domainTargets) {
        if (existingDomains.contains(host)) continue;
        final String? err = ScheduleRuleValidation.validateHost(host);
        if (err != null) continue;
        await _db.insertDomain(
          id: _newId('chat_d'),
          host: host,
          scheduleId: p.scheduleId,
          source: 'chat',
          presetId: intent.category == null
              ? null
              : 'chat_${intent.category!.name}',
          isStem: _looksLikeStem(host),
        );
        existingDomains.add(host);
        domainsAdded++;
      }
      for (final String kw in p.keywordTargets) {
        if (existingKeywords.contains(kw)) continue;
        final String? err = ScheduleRuleValidation.validateKeyword(kw);
        if (err != null) continue;
        await _db.insertKeyword(
          id: _newId('chat_k'),
          pattern: kw,
          scheduleId: p.scheduleId,
          presetId: intent.category == null
              ? null
              : 'chat_${intent.category!.name}',
        );
        existingKeywords.add(kw);
        keywordsAdded++;
      }
    } else if (intent.usageBudgetTargetsApp) {
      // Interval/duty-cycle app command ("10분마다 3분만") — enforced purely
      // via the dense _intervalSlotPieces() slots inserted above (the
      // existing schedule-slot enforcement already respects these), so no
      // new usage-tracking/enforcement plumbing is needed. Just make sure
      // the target app is actually blocked on this schedule.
      if (intent.appNameHints.contains('kakaotalk')) {
        const _AppTarget kakao = _AppTarget(
          displayName: '카카오톡',
          bundleId: 'win|kakaotalk.exe|',
          key: 'win|kakaotalk.exe|',
        );
        if (!existingApps.contains(kakao.key)) {
          await _db.insertBlockedApp(
            id: _newId('chat_app'),
            name: kakao.displayName,
            scheduleId: p.scheduleId,
            bundleId: kakao.bundleId,
          );
          appsAdded++;
        }
      }
    } else {
      for (final String host in p.domainTargets.take(12)) {
        final ChatUsageBudgetPolicy? budget = intent.usageBudgetPolicy;
        if (budget == null) continue;
        await _db.upsertUsageLimit(
          id: 'chat_limit_${_safeId(host)}',
          subject: LocalDatabase.usageSubjectForWebHost(host),
          displayLabel: '$host 제한',
          maxSecondsPerDay: budget.dailyCapMinutes * 60,
          quotaMode: 'session',
          sessionMaxSeconds: budget.burstCapMinutes * 60,
          sessionPeriodSeconds: budget.refillIntervalMinutes * 60,
          enabled: true,
        );
        usageLimitsAdded++;
      }
      await UsageQuotaEnforcerService.instance.evaluateAndApply();
    }

    if (intent.requestsTimeLock) {
      final RulesMeta meta = await _db.rulesMeta();
      if (meta.bypassTimeLockMinutes < 15) {
        await _db.saveRulesMeta(meta.copyWith(bypassTimeLockMinutes: 15));
      }
    }

    BlockSyncService.instance.requestApply();
    final StringBuffer messageBuf = StringBuffer(
      // "적용됐습니다" alone overclaims: only the browser-extension +
      // registry layer applies automatically, and only if the extension is
      // already installed/synced. First-time users (in-app or via the
      // browser extension chat popup) read a flat "applied" as "done,
      // nothing else to do" - add the same honest caveat used in
      // smart_rule_apply_service.dart's domain-add message.
      '채팅 스케줄이 저장됐습니다 — 브라우저 확장이 설치·동기화돼 있으면 몇 초 안에 '
      '자동 차단됩니다. 확실하지 않으면 설정 → 브라우저 차단 현황에서 확인하세요.',
    );
    if (kakaoTalkRemovedFrom.isNotEmpty) {
      messageBuf.write(
        ' 기존 "${kakaoTalkRemovedFrom.join(', ')}" 스케줄의 카카오톡 전체 차단은 '
        '해제하고 이 간격제 규칙으로 대체했습니다.',
      );
    }
    if (intent.requestsTimeLock) {
      messageBuf.write(' 타임락도 함께 켰습니다(15분).');
    }
    return ChatScheduleApplyResult(
      ok: true,
      preview: p,
      message: messageBuf.toString(),
      domainsAdded: domainsAdded,
      keywordsAdded: keywordsAdded,
      appsAdded: appsAdded,
      slotsAdded: slotsAdded,
      usageLimitsAdded: usageLimitsAdded,
    );
  }

  /// Deletes every domain/keyword/app rule + slot for [scheduleId] — used by
  /// the "전부 초토화" reset-and-overwrite chat command. Does not touch the
  /// schedule row itself (caller re-upserts it right after).
  Future<void> _wipeScheduleRules(String scheduleId) async {
    for (final Map<String, Object?> row in await _db.domainsForSchedule(
      scheduleId,
    )) {
      await _db.deleteDomain('${row['id']}');
    }
    for (final Map<String, Object?> row in await _db.keywordsForSchedule(
      scheduleId,
    )) {
      await _db.deleteKeyword('${row['id']}');
    }
    for (final Map<String, Object?> row in await _db.appsForSchedule(
      scheduleId,
    )) {
      await _db.deleteBlockedApp('${row['id']}');
    }
    await _db.deleteSlotsForSchedule(scheduleId);
  }

  /// Removes every blocked-app row whose name matches [appNamePattern] from
  /// every schedule except [exceptScheduleId]. Used when a chat command
  /// converts an app's existing full block into an interval/duty-cycle rule
  /// on a dedicated schedule — otherwise the old full block would still
  /// apply during the "allowed" minutes of every cycle. Returns the names of
  /// schedules a row was actually removed from (for the reply message).
  Future<List<String>> _removeAppFromOtherSchedules({
    required RegExp appNamePattern,
    required String exceptScheduleId,
  }) async {
    final List<String> touched = <String>[];
    for (final Map<String, Object?> schedule in await _db.schedules()) {
      final String scheduleId = schedule['id']! as String;
      if (scheduleId == exceptScheduleId) continue;
      final List<Map<String, Object?>> apps = await _db.appsForSchedule(
        scheduleId,
      );
      bool removedHere = false;
      for (final Map<String, Object?> row in apps) {
        if (!appNamePattern.hasMatch('${row['name'] ?? ''}')) continue;
        await _db.deleteBlockedApp('${row['id']}');
        removedHere = true;
      }
      if (removedHere) {
        touched.add('${schedule['name'] ?? scheduleId}');
      }
    }
    return touched;
  }

  /// Splits each full block span from [_slotPieces] into a duty cycle: block
  /// for (refill - burst) minutes, then leave the last [burst] minutes of
  /// every [refill]-minute cycle open. Used for "10분마다 3분만" style
  /// commands — enforcement is just the normal schedule-slot mechanism, no
  /// separate usage-tracking path needed.
  static List<_SlotPiece> _intervalSlotPieces(ChatScheduleIntent intent) {
    final int burst = intent.usageBudgetPolicy?.burstCapMinutes ?? 3;
    final int refill = intent.usageBudgetPolicy?.refillIntervalMinutes ?? 10;
    final List<_SlotPiece> out = <_SlotPiece>[];
    for (final _SlotPiece span in _slotPieces(intent)) {
      int offset = span.start;
      while (offset < span.end) {
        final int cycleEnd = min(offset + refill, span.end);
        final int blockedEnd = max(offset, cycleEnd - burst);
        if (blockedEnd > offset) {
          out.add(_SlotPiece(span.day, offset, blockedEnd));
        }
        offset = cycleEnd;
      }
    }
    return out;
  }

  Future<List<ChatSchedulePendingEdit>> pendingEdits() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String raw = prefs.getString(_pendingEditsKey) ?? '[]';
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <ChatSchedulePendingEdit>[];
      return decoded
          .map(ChatSchedulePendingEdit.fromJson)
          .whereType<ChatSchedulePendingEdit>()
          .toList()
        ..sort(
          (ChatSchedulePendingEdit a, ChatSchedulePendingEdit b) =>
              a.applyAfterMs.compareTo(b.applyAfterMs),
        );
    } catch (_) {
      return const <ChatSchedulePendingEdit>[];
    }
  }

  Future<void> cancelPendingEdit(String id) async {
    final List<ChatSchedulePendingEdit> next = (await pendingEdits())
        .where((ChatSchedulePendingEdit e) => e.id != id)
        .toList();
    await _savePendingEdits(next);
  }

  Future<List<ChatScheduleApplyResult>> processDuePendingEdits() async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<ChatSchedulePendingEdit> all = await pendingEdits();
    final List<ChatSchedulePendingEdit> due = all
        .where((ChatSchedulePendingEdit e) => e.applyAfterMs <= now)
        .toList();
    if (due.isEmpty) return const <ChatScheduleApplyResult>[];
    final List<ChatScheduleApplyResult> results = <ChatScheduleApplyResult>[];
    final Set<String> processedIds = <String>{};
    for (final ChatSchedulePendingEdit edit in due) {
      final ChatScheduleApplyResult result = await _applyNow(
        edit.message,
        allowTimeLockedWeakening: true,
        resolution: edit.resolution,
        forceScheduleId: edit.forceScheduleId,
      );
      results.add(result);
      if (result.ok) processedIds.add(edit.id);
    }
    final List<ChatSchedulePendingEdit> remaining = all
        .where((ChatSchedulePendingEdit e) => !processedIds.contains(e.id))
        .toList();
    await _savePendingEdits(remaining);
    return results;
  }

  Future<ChatSchedulePendingEdit> _enqueuePendingEdit({
    required String message,
    required ChatSchedulePreview preview,
    String? resolution,
    String? forceScheduleId,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int waitMinutes = _clampInt(
      preview.timeLockMinutes ?? LocalDatabase.kMinCooldownMinutes,
      LocalDatabase.kMinCooldownMinutes,
      24 * 60,
    );
    final ChatSchedulePendingEdit pending = ChatSchedulePendingEdit(
      id: _newId('chat_pending'),
      message: message,
      scheduleId: preview.scheduleId,
      scheduleName: preview.scheduleName,
      createdAtMs: now,
      applyAfterMs: now + waitMinutes * 60 * 1000,
      summary: preview.summary,
      resolution: resolution,
      forceScheduleId: forceScheduleId,
    );
    final List<ChatSchedulePendingEdit> next =
        (await pendingEdits())
            .where(
              (ChatSchedulePendingEdit e) => e.scheduleId != preview.scheduleId,
            )
            .toList()
          ..add(pending);
    await _savePendingEdits(next);
    return pending;
  }

  Future<void> _savePendingEdits(List<ChatSchedulePendingEdit> edits) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String raw = jsonEncode(
      edits.map((ChatSchedulePendingEdit e) => e.toJson()).toList(),
    );
    await prefs.setString(_pendingEditsKey, raw);
  }

  /// For the chat panel's "타임락 켜기" nudge — current bypass Time Lock
  /// minutes (0 = off). See `RulesMeta.bypassTimeLockMinutes`.
  Future<int> currentTimeLockMinutes() async =>
      (await _db.rulesMeta()).bypassTimeLockMinutes;

  Future<void> enableTimeLock({int minutes = 15}) async {
    final RulesMeta meta = await _db.rulesMeta();
    if (meta.bypassTimeLockMinutes >= minutes) return;
    await _db.saveRulesMeta(meta.copyWith(bypassTimeLockMinutes: minutes));
  }

  Future<List<Map<String, Object?>>> schedulesForApi() async {
    final List<Map<String, Object?>> rows = await _db.schedules();
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final Map<String, Object?> row in rows) {
      final String id = row['id']! as String;
      out.add(<String, Object?>{
        ...row,
        'slots': await _db.slotsForSchedule(id),
        'domains': await _db.domainsForSchedule(id),
        'keywords': await _db.keywordsForSchedule(id),
        'apps': await _db.appsForSchedule(id),
      });
    }
    return out;
  }

  Future<_SafetyDecision> _classifySafety(
    ChatScheduleIntent intent,
    _TargetSchedule target,
  ) async {
    if (!target.exists) {
      return const _SafetyDecision(
        safety: ChatScheduleChangeSafety.stronger,
        requiresTimeLock: false,
        timeLockMinutes: LocalDatabase.kMinCooldownMinutes,
      );
    }
    final Map<String, Object?>? row = await _db.scheduleById(target.id);
    final int rawCooldown =
        (row?['lock_cooldown_minutes'] as int?) ??
        LocalDatabase.kMinCooldownMinutes;
    final int cooldown = max(
      LocalDatabase.kMinCooldownMinutes,
      rawCooldown,
    ).toInt();
    // Fix: adding a brand-new time slot was getting time-locked as if it
    // narrowed coverage, even inside the 2-hour urge window where additions
    // should always go through immediately. _applyNow only ever ADDS
    // slots/domains/keywords/apps — it never deletes existing coverage —
    // EXCEPT for two paths that wipe this schedule's slots before re-adding:
    // an explicit "다 지우고 새로" reset
    // (`intent.resetExisting`), or merging into a similar/matching browser
    // schedule (`target.similarReason != null`, see the
    // `p.similarScheduleReason != null` wipe in _applyNow). Only those two
    // paths can actually narrow time coverage, so only they need the
    // slot-coverage check below — a plain "이것도 추가해줘" message must not
    // trip the cooldown just because it doesn't redescribe every existing
    // hour by itself. Additions are always safe, per the app-wide "잠금은
    // 삭제만 막고 추가는 항상 허용" rule (see schedule_edit_screen.dart doc).
    final bool willReplaceSlots =
        intent.resetExisting || target.similarReason != null;
    final List<_SlotPiece> oldSlots = await _existingSlotPieces(target.id, row);
    final List<_SlotPiece> newSlots = _slotPieces(intent);
    final bool narrowsTime =
        willReplaceSlots && !_coversAll(oldSlots, newSlots);
    final bool ambiguous = intent.mode == ChatScheduleMode.limit;
    if (narrowsTime || ambiguous) {
      return _SafetyDecision(
        safety: ambiguous
            ? ChatScheduleChangeSafety.ambiguous
            : ChatScheduleChangeSafety.weaker,
        requiresTimeLock: true,
        timeLockMinutes: cooldown,
      );
    }
    return _SafetyDecision(
      safety: ChatScheduleChangeSafety.stronger,
      requiresTimeLock: false,
      timeLockMinutes: cooldown,
    );
  }

  Future<List<_SlotPiece>> _existingSlotPieces(
    String scheduleId,
    Map<String, Object?>? row,
  ) async {
    final List<Map<String, Object?>> rows = await _db.slotsForSchedule(
      scheduleId,
    );
    if (rows.isNotEmpty) {
      return rows
          .map(
            (Map<String, Object?> r) => _SlotPiece(
              (r['day'] as int?) ?? -1,
              (r['start_minute'] as int?) ?? 0,
              (r['end_minute'] as int?) ?? 0,
            ),
          )
          .where((_SlotPiece s) => s.day >= 0 && s.start < s.end)
          .toList();
    }
    if (row == null) return const <_SlotPiece>[];
    final int start = (row['start_minute'] as int?) ?? 0;
    final int legacyEnd = (row['end_minute'] as int?) ?? 0;
    final int end = legacyEnd == 0 ? 1440 : legacyEnd;
    final int daysMask = (row['days_mask'] as int?) ?? 0;
    final List<_SlotPiece> out = <_SlotPiece>[];
    for (int d = 0; d < 7; d++) {
      if ((daysMask & (1 << d)) == 0) continue;
      if (start == end) {
        out.add(_SlotPiece(d, 0, 1440));
      } else if (start < end) {
        out.add(_SlotPiece(d, start, end));
      } else {
        out.add(_SlotPiece(d, start, 1440));
        out.add(_SlotPiece((d + 1) % 7, 0, end));
      }
    }
    return out;
  }

  static bool _coversAll(List<_SlotPiece> oldSlots, List<_SlotPiece> newSlots) {
    if (oldSlots.isEmpty) return true;
    final List<List<bool>> covered = List<List<bool>>.generate(
      7,
      (_) => List<bool>.filled(1440, false),
    );
    for (final _SlotPiece slot in newSlots) {
      if (slot.day < 0 || slot.day > 6) continue;
      final int start = _clampInt(slot.start, 0, 1440);
      final int end = _clampInt(slot.end, 0, 1440);
      for (int m = start; m < end; m++) {
        covered[slot.day][m] = true;
      }
    }
    for (final _SlotPiece slot in oldSlots) {
      if (slot.day < 0 || slot.day > 6) continue;
      final int start = _clampInt(slot.start, 0, 1440);
      final int end = _clampInt(slot.end, 0, 1440);
      for (int m = start; m < end; m++) {
        if (!covered[slot.day][m]) return false;
      }
    }
    return true;
  }

  Future<_TargetSchedule> _resolveSchedule(
    ChatScheduleIntent intent, {
    String? resolution,
    String? forceScheduleId,
  }) async {
    final String desired =
        (intent.scheduleNameHint ?? intent.proposedScheduleName ?? 'Chat')
            .trim();
    if (forceScheduleId != null) {
      final Map<String, Object?>? row = await _db.scheduleById(forceScheduleId);
      if (row != null) {
        final String name = '${row['name'] ?? ''}'.trim();
        final lock = await _db.scheduleLockPhase(forceScheduleId);
        // Scoped chat never asks "existing vs new" and never redirects to a
        // different schedule by name/similarity — the user is already
        // looking at this exact schedule and every edit must land here.
        return _TargetSchedule(
          id: forceScheduleId,
          name: name.isEmpty ? desired : name,
          exists: true,
          lockPhase: lock.phase,
        );
      }
      // Forced schedule was deleted out from under the chat (e.g. another
      // session) — fall through to normal resolution rather than crash.
    }
    final List<Map<String, Object?>> rows = await _db.schedules();
    for (final Map<String, Object?> row in rows) {
      final String name = '${row['name'] ?? ''}'.trim();
      if (name.toLowerCase() == desired.toLowerCase()) {
        final String id = row['id']! as String;
        final lock = await _db.scheduleLockPhase(id);
        if (intent.category == ChatScheduleCategory.browser) {
          return _decideBrowserTarget(
            existingId: id,
            existingName: name,
            desired: desired,
            reason: 'schedule name "$name" matches exactly',
            lockPhase: lock.phase,
            resolution: resolution,
          );
        }
        return _TargetSchedule(
          id: id,
          name: name,
          exists: true,
          lockPhase: lock.phase,
        );
      }
    }
    if (intent.category == ChatScheduleCategory.browser) {
      for (final Map<String, Object?> row in rows) {
        final String id = row['id']! as String;
        final String name = '${row['name'] ?? ''}'.trim();
        final String reason = await _browserScheduleSimilarity(id, name);
        if (reason.isEmpty) continue;
        final lock = await _db.scheduleLockPhase(id);
        return _decideBrowserTarget(
          existingId: id,
          existingName: name.isEmpty ? desired : name,
          desired: desired,
          reason: reason,
          lockPhase: lock.phase,
          resolution: resolution,
        );
      }
    }
    return _TargetSchedule(
      id: _newId('chat_schedule'),
      name: desired.isEmpty ? 'Chat Schedule' : desired,
      exists: false,
      lockPhase: ScheduleLockPhase.unlocked,
    );
  }

  /// A similar/matching browser schedule was found. Without an explicit
  /// [resolution] this used to silently guess (auto-overlay if locked,
  /// auto-modify if not) — now it asks instead: see
  /// [ChatSchedulePreview.needsResolutionChoice]. The chosen resolution only
  /// picks WHICH schedule is targeted; the normal lock/time-lock safety
  /// checks in [_applyNow] still apply afterward regardless.
  _TargetSchedule _decideBrowserTarget({
    required String existingId,
    required String existingName,
    required String desired,
    required String reason,
    required ScheduleLockPhase lockPhase,
    required String? resolution,
  }) {
    if (resolution == kChatScheduleResolutionNew) {
      return _TargetSchedule(
        id: _newId('chat_schedule'),
        name: _overlayScheduleName(desired),
        exists: false,
        lockPhase: ScheduleLockPhase.unlocked,
        similarReason: '$reason; user chose to create a separate schedule',
      );
    }
    if (resolution == kChatScheduleResolutionExisting) {
      return _TargetSchedule(
        id: existingId,
        name: existingName,
        exists: true,
        lockPhase: lockPhase,
        similarReason: '$reason; user chose to modify the existing schedule',
      );
    }
    return _TargetSchedule(
      id: existingId,
      name: existingName,
      exists: true,
      lockPhase: lockPhase,
      similarReason: reason,
      needsChoice: true,
      proposedNewName: _overlayScheduleName(desired),
    );
  }

  static _Targets _targetsFor(ChatScheduleIntent intent) {
    final Set<String> domains = <String>{...intent.customDomains};
    final Set<String> keywords = <String>{...intent.customKeywords};
    final List<_AppTarget> apps = <_AppTarget>[];
    switch (intent.category) {
      case ChatScheduleCategory.sns:
        domains.addAll(<String>[
          'instagram.com',
          'tiktok.com',
          'x.com',
          'twitter.com',
          'facebook.com',
          'threads.net',
          'reddit.com',
        ]);
      case ChatScheduleCategory.streaming:
        domains.addAll(<String>[
          'youtube.com',
          'youtu.be',
          'netflix.com',
          'twitch.tv',
          'disneyplus.com',
          'tving.com',
          'wavve.com',
        ]);
      case ChatScheduleCategory.gaming:
        domains.addAll(<String>[
          'steampowered.com',
          'steamcommunity.com',
          'epicgames.com',
          'battle.net',
          'roblox.com',
          'op.gg',
          'twitch.tv',
        ]);
        // "모든 게임 채널 차단해줘" needs the game-related YouTube channel/search
        // keywords too, not just the small hardcoded site list above.
        final ScheduleDomainPreset gamingPack = scheduleDomainPresets()
            .firstWhere((ScheduleDomainPreset p) => p.id == 'gaming_pack_400');
        domains.addAll(gamingPack.domains);
        keywords.addAll(gamingPack.keywords);
      case ChatScheduleCategory.shopping:
        domains.addAll(<String>[
          'coupang.com',
          'gmarket.co.kr',
          '11st.co.kr',
          'amazon.com',
          'aliexpress.com',
          'temu.com',
          'ebay.com',
        ]);
      case ChatScheduleCategory.finance:
        final ScheduleDomainPreset finance = scheduleDomainPresets().firstWhere(
          (ScheduleDomainPreset p) => p.id == 'finance',
        );
        domains.addAll(finance.domains);
      case ChatScheduleCategory.adult:
        final ScheduleDomainPreset adult = scheduleDomainPresets().firstWhere(
          (ScheduleDomainPreset p) => p.id == 'adult_combined',
        );
        domains.addAll(adult.domains.take(250));
        domains.addAll(adult.numericStems.take(80));
        keywords.addAll(adult.keywords.take(120));
      case ChatScheduleCategory.browser:
        apps.addAll(_browserAppTargets());
        break;
      case null:
        break;
    }
    return _Targets(
      domains:
          domains.map(_normalizeHost).where((String h) => h.isNotEmpty).toList()
            ..sort(),
      keywords:
          keywords
              .map((String k) => k.trim().toLowerCase())
              .where((String k) => k.isNotEmpty)
              .toList()
            ..sort(),
      apps: apps,
    );
  }

  static String _normalizeHost(String raw) {
    String h = raw.trim().toLowerCase();
    h = h.replaceFirst(RegExp(r'^https?://'), '');
    h = h.replaceFirst(RegExp(r'^www\.'), '');
    final int slash = h.indexOf('/');
    if (slash >= 0) h = h.substring(0, slash);
    return h;
  }

  static String _overlayScheduleName(String base) {
    final String name = base.trim().isEmpty ? 'Internet Browsers' : base.trim();
    return '$name 23-09';
  }

  Future<String> _browserScheduleSimilarity(
    String scheduleId,
    String scheduleName,
  ) async {
    final String lower = scheduleName.toLowerCase();
    if (RegExp(
      r'(browser|browsers|internet|web|chrome|firefox|edge|brave|opera|whale|vivaldi)',
    ).hasMatch(lower)) {
      return 'schedule name "$scheduleName" looks browser-related';
    }
    final Set<String> browserKeys = _browserAppTargets()
        .map((_AppTarget app) => app.key)
        .toSet();
    final List<Map<String, Object?>> apps = await _db.appsForSchedule(
      scheduleId,
    );
    int hits = 0;
    for (final Map<String, Object?> row in apps) {
      if (browserKeys.contains(_appRowKey(row))) hits++;
    }
    if (hits >= 2) return '$hits browser app targets already exist';
    return '';
  }

  static List<_AppTarget> _browserAppTargets() => <_AppTarget>[
    _AppTarget.browser('Google Chrome', 'chrome.exe', BlockApp.mainBrowserKey),
    _AppTarget.browser('Microsoft Edge', 'msedge.exe', BlockApp.mainBrowserKey),
    _AppTarget.browser('Brave', 'brave.exe', BlockApp.mainBrowserKey),
    _AppTarget.browser('Firefox', 'firefox.exe', null),
    _AppTarget.browser('Opera', 'opera.exe', null),
    _AppTarget.browser('Vivaldi', 'vivaldi.exe', null),
    _AppTarget.browser('Naver Whale', 'whale.exe', null),
    _AppTarget.browser('Naver Whale', 'naverwhale.exe', null),
  ];

  static String _appRowKey(Map<String, Object?> row) {
    final String bundle = '${row['bundle_id'] ?? ''}'.trim();
    if (bundle.startsWith('win|')) {
      final List<String> parts = bundle.split('|');
      if (parts.length >= 3) {
        final String exe = BlockApp.normalizeExeName(parts[1]);
        final String appId = parts.sublist(2).join('|');
        return 'win|$exe|$appId';
      }
    }
    return '${row['name'] ?? ''}'.trim().toLowerCase();
  }

  static List<_SlotPiece> _slotPieces(ChatScheduleIntent intent) {
    final List<_SlotPiece> out = <_SlotPiece>[];
    for (final int day in intent.weekdays) {
      final int start = intent.startMinutes;
      final int end = intent.endMinutes;
      if (intent.blockAlways || (start == 0 && end >= 1440)) {
        out.add(_SlotPiece(day, 0, 1440));
      } else if (start < end) {
        out.add(_SlotPiece(day, start, end));
      } else {
        out.add(_SlotPiece(day, start, 1440));
        out.add(_SlotPiece((day + 1) % 7, 0, end));
      }
    }
    final Map<String, _SlotPiece> dedup = <String, _SlotPiece>{};
    for (final _SlotPiece slot in out) {
      dedup['${slot.day}|${slot.start}|${slot.end}'] = slot;
    }
    return dedup.values.toList()..sort((_SlotPiece a, _SlotPiece b) {
      final int day = a.day.compareTo(b.day);
      if (day != 0) return day;
      return a.start.compareTo(b.start);
    });
  }

  static int _daysMask(List<int> days) {
    int mask = 0;
    for (final int day in days) {
      if (day >= 0 && day <= 6) mask |= 1 << day;
    }
    return mask;
  }

  static String _summary(
    ChatScheduleIntent intent,
    String scheduleName,
    _Targets targets,
  ) {
    final String days = _daysLabel(intent.weekdays);
    final String time = intent.blockAlways
        ? '하루 종일'
        : '${_hhmm(intent.startMinutes)}-${_hhmm(intent.endMinutes)}';
    final String limit =
        intent.mode == ChatScheduleMode.limit &&
            intent.usageBudgetPolicy != null
        ? ' (한 번에 ${intent.usageBudgetPolicy!.burstCapMinutes}분, 하루 ${intent.usageBudgetPolicy!.dailyCapMinutes}분)'
        : '';
    return '스케줄 "$scheduleName"에 ${intent.categoryLabel} 대상 '
        '${targets.domains.length + targets.keywords.length + targets.apps.length}개를 $days $time '
        '${intent.modeLabel}$limit으로 준비합니다.';
  }

  static String _daysLabel(List<int> days) {
    const List<String> names = <String>['월', '화', '수', '목', '금', '토', '일'];
    if (days.length == 7) return '매일';
    if (_same(days, <int>[0, 1, 2, 3, 4])) return '평일';
    if (_same(days, <int>[5, 6])) return '주말';
    return days.map((int d) => names[d]).join('');
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hhmm(int minute) {
    final int m = minute.clamp(0, 1440);
    final int h = m ~/ 60;
    final int mm = m % 60;
    return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
  }

  static String _newId(String prefix) {
    final int now = DateTime.now().microsecondsSinceEpoch;
    final int rnd = Random().nextInt(1 << 20);
    return '${prefix}_${now}_$rnd';
  }

  static String _safeId(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  static int _clampInt(int value, int minValue, int maxValue) {
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
  }

  static bool _looksLikeStem(String host) =>
      !host.contains('.') || RegExp(r'^\d+$').hasMatch(host);
}

final class _TargetSchedule {
  const _TargetSchedule({
    required this.id,
    required this.name,
    required this.exists,
    required this.lockPhase,
    this.similarReason,
    this.needsChoice = false,
    this.proposedNewName,
  });

  final String id;
  final String name;
  final bool exists;
  final ScheduleLockPhase lockPhase;
  final String? similarReason;

  /// True when a similar existing browser schedule was found and the chat
  /// must ask the user (modify it vs create a separate one) before
  /// proceeding — [name]/[id] describe the EXISTING schedule in this case;
  /// [proposedNewName] is what a fresh separate schedule would be called.
  final bool needsChoice;
  final String? proposedNewName;
}

final class _Targets {
  const _Targets({
    required this.domains,
    required this.keywords,
    required this.apps,
  });
  final List<String> domains;
  final List<String> keywords;
  final List<_AppTarget> apps;
}

final class _SafetyDecision {
  const _SafetyDecision({
    required this.safety,
    required this.requiresTimeLock,
    required this.timeLockMinutes,
  });

  final ChatScheduleChangeSafety safety;
  final bool requiresTimeLock;
  final int timeLockMinutes;
}

final class _AppTarget {
  const _AppTarget({
    required this.displayName,
    required this.bundleId,
    required this.key,
  });

  factory _AppTarget.browser(String displayName, String exe, String? appId) {
    final String normalizedExe = BlockApp.normalizeExeName(exe);
    final String normalizedAppId = appId ?? '';
    return _AppTarget(
      displayName: displayName,
      bundleId: 'win|$normalizedExe|$normalizedAppId',
      key: 'win|$normalizedExe|$normalizedAppId',
    );
  }

  final String displayName;
  final String bundleId;
  final String key;
}

final class _SlotPiece {
  const _SlotPiece(this.day, this.start, this.end);
  final int day;
  final int start;
  final int end;
}
