import '../models/chat_schedule_intent.dart';

final class ChatScheduleIntentParser {
  ChatScheduleIntentParser._();
  static final ChatScheduleIntentParser instance = ChatScheduleIntentParser._();

  ChatScheduleIntent parse(String rawMessage) {
    final String message = rawMessage.trim();
    if (message.isEmpty) {
      throw const FormatException('명령을 입력해주세요.');
    }
    final String compact = _compact(message);
    if (isYoutubeBudgetExemptionRequest(message)) {
      final list = RegExp(r'(목록|리스트|보여|조회|list)').hasMatch(compact);
      final remove = RegExp(
        r'(예외(?:에서|를|설정)?(?:제외|삭제|해제|취소)|예외목록에서.*(?:빼|삭제)|remove)',
      ).hasMatch(compact);
      final targets =
          RegExp(r'(?:https?://|www\.)[^\s<>"\x27]+', caseSensitive: false)
              .allMatches(message)
              .map((m) => m.group(0)!.replaceAll(RegExp(r'[),.!?]+$'), ''))
              .toSet()
              .toList();
      if (!list && targets.isEmpty) {
        throw const FormatException(
          '시간 집계에서 예외로 할 채널·영상 또는 사이트 주소를 함께 입력해 주세요.',
        );
      }
      return ChatScheduleIntent(
        customDomains: const [],
        customKeywords: const [],
        weekdays: const [],
        startMinutes: 0,
        endMinutes: 1440,
        mode: ChatScheduleMode.limit,
        limitMinutesPerHour: 10,
        blockAlways: false,
        confidence: 1,
        youtubeBudgetExemption: true,
        removeYoutubeBudgetExemption: remove,
        listYoutubeBudgetExemptions: list && targets.isEmpty,
        youtubeBudgetExemptionTargets: targets,
      );
    }

    final ChatScheduleCategory? category = _detectCategory(compact);
    final List<String> domains = _extractDomains(message);
    final List<String> keywords = _extractKeywords(message);
    if (compact.contains('유튜브뮤직') || compact.contains('youtubemusic')) {
      domains.add('music.youtube.com');
    }
    final List<int> weekdays = _extractWeekdays(compact);
    final ({int start, int end, bool always}) window = _extractWindow(message);
    final List<String> appNameHints = _extractAppNameHints(message);
    final ({int burst, int refill})? appInterval = _extractAppIntervalBudget(
      compact,
    );
    final bool usageBudgetTargetsApp =
        appNameHints.isNotEmpty && appInterval != null;
    final ChatScheduleMode mode = usageBudgetTargetsApp
        ? ChatScheduleMode.limit
        : _detectMode(compact);
    final int limit = usageBudgetTargetsApp
        ? appInterval.burst
        : _extractLimitMinutes(compact);
    final ChatUsageBudgetPolicy? budget = mode != ChatScheduleMode.limit
        ? null
        : usageBudgetTargetsApp
        ? ChatUsageBudgetPolicy(
            enabled: true,
            dailyCapMinutes: (appInterval.burst * (1440 ~/ appInterval.refill))
                .clamp(1, 1440),
            burstCapMinutes: appInterval.burst,
            refillIntervalMinutes: appInterval.refill,
            cooldownMinutes: appInterval.refill,
          )
        : _extractBudget(compact, limit);
    final bool requestsTimeLock = _detectRequestsTimeLock(compact);
    final bool resetExisting = _detectResetExisting(compact);
    final String? nameHint =
        _extractScheduleName(message) ??
        (compact.contains('유튜브뮤직') ? 'YouTube Music' : null);
    final String proposedName =
        nameHint ?? _defaultScheduleName(category, domains, keywords);

    double confidence = 0.2;
    if (category != null) confidence += 0.25;
    if (domains.isNotEmpty || keywords.isNotEmpty) confidence += 0.25;
    if (!window.always || compact.contains('매일') || compact.contains('평일')) {
      confidence += 0.15;
    }
    if (mode == ChatScheduleMode.limit || compact.contains('막')) {
      confidence += 0.10;
    }
    if (nameHint != null) confidence += 0.05;
    confidence = confidence.clamp(0, 0.98).toDouble();

    if (category == null &&
        domains.isEmpty &&
        keywords.isEmpty &&
        appNameHints.isEmpty) {
      throw const FormatException('막을 대상이 필요합니다. 예: "평일 9시-18시 SNS 막아줘"');
    }

    return ChatScheduleIntent(
      scheduleNameHint: nameHint,
      category: category,
      customDomains: domains,
      customKeywords: keywords,
      weekdays: weekdays,
      startMinutes: window.start,
      endMinutes: window.end,
      mode: mode,
      limitMinutesPerHour: limit,
      blockAlways: window.always,
      proposedScheduleName: proposedName,
      usageBudgetPolicy: budget,
      confidence: confidence,
      requestsTimeLock: requestsTimeLock,
      resetExisting: resetExisting,
      usageBudgetTargetsApp: usageBudgetTargetsApp,
      appNameHints: appNameHints,
    );
  }

  static bool _detectRequestsTimeLock(String compact) =>
      RegExp(r'(타임락|타임락설정|timelock)').hasMatch(compact);

  static bool _detectResetExisting(String compact) =>
      RegExp(r'(초토화|리셋|재설정|전부삭제|모두삭제|덮어쓰|덮어써)').hasMatch(compact);

  /// Recognizes a small dictionary of app names by keyword — enough for the
  /// "카카오톡 밤에... 10분마다 3분만" style commands. Extend this map as more
  /// apps need chat-driven interval limits.
  static List<String> _extractAppNameHints(String message) {
    final Set<String> out = <String>{};
    if (RegExp(
      r'(카카오톡|카톡|kakaotalk)',
      caseSensitive: false,
    ).hasMatch(message)) {
      out.add('kakaotalk');
    }
    return out.toList();
  }

  /// "10분마다 3분만" → refill every 10 minutes, allow a 3-minute burst.
  static ({int burst, int refill})? _extractAppIntervalBudget(String compact) {
    final RegExpMatch? m = RegExp(
      r'(\d{1,3})분마다(\d{1,3})분만',
    ).firstMatch(compact);
    if (m == null) return null;
    final int refill = int.tryParse(m.group(1)!)?.clamp(1, 1440) ?? 10;
    final int burst = int.tryParse(m.group(2)!)?.clamp(1, 1440) ?? 3;
    return (burst: burst, refill: refill);
  }

  static String _compact(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  /// Preserve exact pasted URLs before any LLM schedule normalization.
  static bool isYoutubeBudgetExemptionRequest(String message) {
    final compact = _compact(message);
    return RegExp(r'(예외|면제|집계제외|측정제외|카운트제외|exempt)').hasMatch(compact) &&
        RegExp(
          r'(유튜브|youtube|youtu\.be|시간.*(?:재는|측정|집계|카운트)|시청시간|사용시간|budget)',
        ).hasMatch(compact);
  }

  static ChatScheduleCategory? _detectCategory(String s) {
    if (RegExp(
      r'(인터넷|브라우저|browser|browsers|webbrowser|웹브라우저|크롬|chrome|파이어폭스|firefox|엣지|edge|brave|브레이브|opera|오페라|vivaldi|비발디|whale|웨일)',
    ).hasMatch(s)) {
      return ChatScheduleCategory.browser;
    }
    if (RegExp(r'(성인|음란|야동|porn|adult|19금)').hasMatch(s)) {
      return ChatScheduleCategory.adult;
    }
    if (RegExp(
      r'(sns|인스타|instagram|틱톡|tiktok|트위터|twitter|x\.com|페북|facebook|reddit|레딧)',
    ).hasMatch(s)) {
      return ChatScheduleCategory.sns;
    }
    if (RegExp(
      r'(유튜브|youtube|넷플릭스|netflix|트위치|twitch|스트리밍|영상|쇼츠|shorts)',
    ).hasMatch(s)) {
      return ChatScheduleCategory.streaming;
    }
    if (RegExp(
      r'(게임|game|steam|스팀|epic|에픽|battle\.net|배틀넷|롤|lol|roblox|로블록스)',
    ).hasMatch(s)) {
      return ChatScheduleCategory.gaming;
    }
    if (RegExp(
      r'(쇼핑|shopping|쿠팡|coupang|amazon|아마존|gmarket|지마켓|11번가|temu|테무|aliexpress)',
    ).hasMatch(s)) {
      return ChatScheduleCategory.shopping;
    }
    if (RegExp(
      r'(주식|증권|증권사|주식앱|stock|finance|nasdaq|나스닥|코스피|코스닥|토스증권|키움|영웅문)',
    ).hasMatch(s)) {
      return ChatScheduleCategory.finance;
    }
    return null;
  }

  static List<String> _extractDomains(String message) {
    final Set<String> out = <String>{};
    final RegExp re = RegExp(
      r'(?:(?:https?:\/\/)?(?:www\.)?)((?:[a-z0-9-]+\.)+[a-z]{2,})(?:[\/?#][^\s]*)?',
      caseSensitive: false,
    );
    for (final RegExpMatch m in re.allMatches(message)) {
      final String? host = m.group(1);
      if (host == null) continue;
      out.add(host.toLowerCase().replaceFirst(RegExp(r'^www\.'), ''));
    }
    return out.toList()..sort();
  }

  static List<String> _extractKeywords(String message) {
    final Set<String> out = <String>{};
    final RegExp handle = RegExp(r'(^|\s)(@[A-Za-z0-9._-]{2,})');
    for (final RegExpMatch m in handle.allMatches(message)) {
      final String? h = m.group(2);
      if (h != null) out.add(h.toLowerCase());
    }
    return out.toList()..sort();
  }

  static List<int> _extractWeekdays(String compact) {
    if (compact.contains('평일')) return <int>[0, 1, 2, 3, 4];
    if (compact.contains('주말')) return <int>[5, 6];
    if (compact.contains('매일') || compact.contains('항상')) {
      return <int>[0, 1, 2, 3, 4, 5, 6];
    }

    final Map<String, int> map = <String, int>{
      '월': 0,
      '화': 1,
      '수': 2,
      '목': 3,
      '금': 4,
      '토': 5,
      '일': 6,
    };
    final Set<int> days = <int>{};
    for (final MapEntry<String, int> e in map.entries) {
      if (compact.contains(e.key)) days.add(e.value);
    }
    if (days.isEmpty) return <int>[0, 1, 2, 3, 4, 5, 6];
    final List<int> sorted = days.toList()..sort();
    return sorted;
  }

  /// Default clock windows for a time-of-day word used with no attached
  /// digit hour (e.g. "매일 아침 ... 차단해줘" — no "7시", just "아침"). Without
  /// this, a message like that would silently fall through to "하루 종일".
  static const Map<String, (int, int)> _timeWordDefaultWindow =
      <String, (int, int)>{
        '새벽': (0, 360),
        '아침': (360, 540),
        '오전': (360, 720),
        '점심': (660, 780),
        '오후': (720, 1080),
        '저녁': (1080, 1260),
        '밤': (1260, 1440),
      };

  static ({int start, int end, bool always}) _extractWindow(String message) {
    final List<_TimeHit> hits = _timeHits(message);
    if (hits.isEmpty) {
      for (final MapEntry<String, (int, int)> e
          in _timeWordDefaultWindow.entries) {
        if (message.contains(e.key)) {
          return (start: e.value.$1, end: e.value.$2, always: false);
        }
      }
    }
    if (hits.length >= 2) {
      return (start: hits[0].minute, end: hits[1].minute, always: false);
    }
    if (hits.length == 1) {
      final String tail = message.substring(hits.first.end);
      final String head = message.substring(0, hits.first.start);
      if (tail.contains('까지') || tail.contains('전까지')) {
        return (start: 0, end: hits.first.minute, always: false);
      }
      if (head.contains('까지')) {
        return (start: 0, end: hits.first.minute, always: false);
      }
      return (start: hits.first.minute, end: 1440, always: false);
    }
    return (start: 0, end: 1440, always: true);
  }

  static List<_TimeHit> _timeHits(String message) {
    final List<_TimeHit> out = <_TimeHit>[];
    final RegExp re = RegExp(
      r'(새벽|아침|오전|점심|오후|저녁|밤)?\s*(\d{1,2})(?::|시)\s*(\d{1,2})?분?',
      caseSensitive: false,
    );
    for (final RegExpMatch m in re.allMatches(message)) {
      int hour = int.tryParse(m.group(2) ?? '') ?? 0;
      final int minute = int.tryParse(m.group(3) ?? '') ?? 0;
      final String prefix = (m.group(1) ?? '').toLowerCase();
      if ((prefix == '오후' || prefix == '저녁' || prefix == '밤') && hour < 12) {
        hour += 12;
      }
      if (prefix == '점심' && hour < 11) hour += 12;
      if (hour == 24) {
        out.add(_TimeHit(1440, m.start, m.end));
      } else if (hour >= 0 && hour < 24 && minute >= 0 && minute < 60) {
        out.add(_TimeHit(hour * 60 + minute, m.start, m.end));
      }
    }
    final RegExp koRe = RegExp(
      r'(새벽|아침|오전|점심|오후|저녁|밤)?\s*(\d{1,2})(?::|시)\s*(\d{1,2})?분?',
      caseSensitive: false,
    );
    for (final RegExpMatch m in koRe.allMatches(message)) {
      if (out.any((_TimeHit h) => h.start == m.start && h.end == m.end)) {
        continue;
      }
      int hour = int.tryParse(m.group(2) ?? '') ?? 0;
      final int minute = int.tryParse(m.group(3) ?? '') ?? 0;
      final String prefix = (m.group(1) ?? '').toLowerCase();
      if ((prefix == '오후' || prefix == '저녁' || prefix == '밤') && hour < 12) {
        hour += 12;
      }
      if (prefix == '점심' && hour < 11) hour += 12;
      if (hour == 24) {
        out.add(_TimeHit(1440, m.start, m.end));
      } else if (hour >= 0 && hour < 24 && minute >= 0 && minute < 60) {
        out.add(_TimeHit(hour * 60 + minute, m.start, m.end));
      }
    }
    out.sort((_TimeHit a, _TimeHit b) => a.start.compareTo(b.start));
    return out;
  }

  static ChatScheduleMode _detectMode(String compact) {
    if (RegExp(
      r'(\d+분만|\d+분제한|하루\d+시간|하루\d+분|제한|쿼터|quota)',
    ).hasMatch(compact)) {
      return ChatScheduleMode.limit;
    }
    return ChatScheduleMode.block;
  }

  static int _extractLimitMinutes(String compact) {
    final RegExpMatch? min = RegExp(r'(\d{1,3})분(?:만|제한)?').firstMatch(compact);
    if (min != null) return int.tryParse(min.group(1)!)?.clamp(1, 720) ?? 20;
    final RegExpMatch? hour = RegExp(
      r'(\d{1,2})시간(?:만|제한)?',
    ).firstMatch(compact);
    if (hour != null) {
      final int h = int.tryParse(hour.group(1)!) ?? 1;
      return (h * 60).clamp(1, 720);
    }
    return 20;
  }

  static ChatUsageBudgetPolicy _extractBudget(String compact, int limit) {
    int daily = 0;
    final RegExpMatch? dailyHour = RegExp(r'하루(\d{1,2})시간').firstMatch(compact);
    final RegExpMatch? dailyMin = RegExp(r'하루(\d{1,3})분').firstMatch(compact);
    if (dailyHour != null) {
      daily = (int.tryParse(dailyHour.group(1)!) ?? 1) * 60;
    } else if (dailyMin != null) {
      daily = int.tryParse(dailyMin.group(1)!) ?? 0;
    }
    if (daily <= 0) daily = limit * 8;

    int refill = 60;
    final RegExpMatch? refillHour = RegExp(r'(\d{1,2})시간뒤').firstMatch(compact);
    final RegExpMatch? refillMin = RegExp(r'(\d{1,3})분뒤').firstMatch(compact);
    if (refillHour != null) {
      refill = (int.tryParse(refillHour.group(1)!) ?? 1) * 60;
    } else if (refillMin != null) {
      refill = int.tryParse(refillMin.group(1)!) ?? 60;
    }

    int cooldown = refill;
    final RegExpMatch? lockMin = RegExp(r'(\d{1,3})분잠').firstMatch(compact);
    if (lockMin != null) cooldown = int.tryParse(lockMin.group(1)!) ?? refill;

    return ChatUsageBudgetPolicy(
      enabled: true,
      dailyCapMinutes: daily.clamp(1, 1440),
      burstCapMinutes: limit.clamp(1, 720),
      refillIntervalMinutes: refill.clamp(1, 1440),
      cooldownMinutes: cooldown.clamp(1, 1440),
    );
  }

  static String? _extractScheduleName(String message) {
    final List<RegExp> patterns = <RegExp>[
      RegExp(r'([A-Za-z0-9가-힣 _-]{1,24})\s*스케줄(?:에|을|를)?'),
      RegExp(r'\(([A-Za-z0-9가-힣 _-]{1,24})\s*스케줄\)'),
    ];
    for (final RegExp re in patterns) {
      final RegExpMatch? m = re.firstMatch(message);
      final String? raw = m?.group(1)?.trim();
      if (raw != null && raw.isNotEmpty) return raw;
    }
    return null;
  }

  static String _defaultScheduleName(
    ChatScheduleCategory? category,
    List<String> domains,
    List<String> keywords,
  ) {
    if (category != null) {
      switch (category) {
        case ChatScheduleCategory.sns:
          return 'SNS';
        case ChatScheduleCategory.streaming:
          return 'Streaming';
        case ChatScheduleCategory.gaming:
          return 'Game';
        case ChatScheduleCategory.shopping:
          return 'Shopping';
        case ChatScheduleCategory.adult:
          return 'Adult';
        case ChatScheduleCategory.browser:
          return 'Browsers';
        case ChatScheduleCategory.finance:
          return 'Finance';
      }
    }
    if (domains.isNotEmpty) return domains.first;
    if (keywords.isNotEmpty) return keywords.first;
    return 'Chat Schedule';
  }
}

final class _TimeHit {
  const _TimeHit(this.minute, this.start, this.end);
  final int minute;
  final int start;
  final int end;
}
