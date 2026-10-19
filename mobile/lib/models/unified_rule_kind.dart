/// How a single smart-input line is enforced (hosts vs browser extension).
enum UnifiedRuleKind {
  keyword,
  searchQuery,
  host,
  channelURL,
  videoURL,
  wildcard,
}

extension UnifiedRuleKindX on UnifiedRuleKind {
  String get badgeEmoji {
    switch (this) {
      case UnifiedRuleKind.keyword:
        return '🔑';
      case UnifiedRuleKind.searchQuery:
        return '🔍';
      case UnifiedRuleKind.host:
        return '🌐';
      case UnifiedRuleKind.channelURL:
        return '📺';
      case UnifiedRuleKind.videoURL:
        return '🎬';
      case UnifiedRuleKind.wildcard:
        return '🌐';
    }
  }

  String get shortLabelKo {
    switch (this) {
      case UnifiedRuleKind.keyword:
        return '키워드';
      case UnifiedRuleKind.searchQuery:
        return '검색어';
      case UnifiedRuleKind.host:
        return '도메인';
      case UnifiedRuleKind.channelURL:
        return '채널';
      case UnifiedRuleKind.videoURL:
        return '영상';
      case UnifiedRuleKind.wildcard:
        return '와일드카드';
    }
  }
}
