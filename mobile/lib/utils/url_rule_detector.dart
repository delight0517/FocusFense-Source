import '../models/unified_rule_kind.dart';
import '../services/mac_system_block_service.dart';
import 'numeric_suffix_evasion.dart';

/// Result of [UrlRuleDetector.detect] — one line → kind + stored pattern.
final class DetectedRule {
  const DetectedRule({
    required this.pattern,
    required this.kind,
    this.normalizedFrom,
    this.numericStemEvasion = false,
    this.numericEvasionNote,
  });

  final String pattern;
  final UnifiedRuleKind kind;

  /// When host detection stripped URL path (for UI snack).
  final String? normalizedFrom;

  /// `linkdamoa01.com` → stem `linkdamoa` + 숫자 변형 전체 차단.
  final bool numericStemEvasion;
  final String? numericEvasionNote;
}

/// Classifies user input (URL / domain / channel / keyword) per unified blueprint.
abstract final class UrlRuleDetector {
  static final RegExp _searchPrefix = RegExp(
    r'^(q|search|검색)\s*[:：]\s*(.+)$',
    caseSensitive: false,
  );
  static final RegExp _keywordPrefix = RegExp(
    r'^(kw|keyword|키워드)\s*[:：]\s*(.+)$',
    caseSensitive: false,
  );

  static DetectedRule detect(String raw) {
    final String input = _safeDecodeUrl(raw.trim());
    if (input.isEmpty) {
      return const DetectedRule(pattern: '', kind: UnifiedRuleKind.keyword);
    }

    final RegExpMatch? searchPref = _searchPrefix.firstMatch(input);
    if (searchPref != null) {
      final String term = searchPref.group(2)!.trim().toLowerCase();
      return DetectedRule(
        pattern: term,
        kind: UnifiedRuleKind.searchQuery,
      );
    }

    final RegExpMatch? kwPref = _keywordPrefix.firstMatch(input);
    if (kwPref != null) {
      final String term = kwPref.group(2)!.trim().toLowerCase();
      return DetectedRule(
        pattern: term,
        kind: UnifiedRuleKind.keyword,
      );
    }

    if (_isYouTubeVideoUrl(input)) {
      return DetectedRule(
        pattern: _lowerUrl(input),
        kind: UnifiedRuleKind.videoURL,
      );
    }

    final String? channel = _extractYouTubeChannel(input);
    if (channel != null) {
      return DetectedRule(
        pattern: channel,
        kind: UnifiedRuleKind.channelURL,
      );
    }

    if (_isWildcardDomain(input)) {
      final String host =
          MacSystemBlockService.canonicalHost(input.replaceFirst('*.', ''));
      return DetectedRule(
        pattern: host,
        kind: UnifiedRuleKind.wildcard,
      );
    }

    // `pornhub.com/any-path` (no scheme) must become apex host block, not keyword.
    if (_looksLikeDomainWithPath(input)) {
      final String host = MacSystemBlockService.canonicalHost(input);
      final NumericSuffixEvasionMatch? evasion =
          NumericSuffixEvasion.fromHost(host);
      if (evasion != null) {
        return DetectedRule(
          pattern: evasion.stem,
          kind: UnifiedRuleKind.host,
          normalizedFrom: input.trim(),
          numericStemEvasion: true,
          numericEvasionNote: evasion.userMessageKo,
        );
      }
      return DetectedRule(
        pattern: host,
        kind: UnifiedRuleKind.host,
        normalizedFrom: input.trim(),
      );
    }

    if (_looksLikeKeyword(input)) {
      final String normalized = input.toLowerCase();
      final bool multiWord = RegExp(r'\s').hasMatch(input.trim());
      return DetectedRule(
        pattern: normalized,
        kind: multiWord
            ? UnifiedRuleKind.searchQuery
            : UnifiedRuleKind.keyword,
      );
    }

    final String before = input;
    final String host = MacSystemBlockService.canonicalHost(
      input.contains('://') || input.contains('/')
          ? input
          : input.split(RegExp(r'\s')).first,
    );
    final bool strippedPath = before != host &&
        (before.contains('/') || before.contains('://'));

    final NumericSuffixEvasionMatch? evasion =
        NumericSuffixEvasion.fromHost(host);
    if (evasion != null) {
      return DetectedRule(
        pattern: evasion.stem,
        kind: UnifiedRuleKind.host,
        normalizedFrom: strippedPath ? before : host,
        numericStemEvasion: true,
        numericEvasionNote: evasion.userMessageKo,
      );
    }

    return DetectedRule(
      pattern: host,
      kind: UnifiedRuleKind.host,
      normalizedFrom: strippedPath ? before : null,
    );
  }

  /// Live hint while typing (Schedules / Rules smart bar).
  static String? smartRuleHint(String input) {
    final String t = input.trim();
    if (t.isEmpty) return null;
    final DetectedRule d = detect(t);
    switch (d.kind) {
      case UnifiedRuleKind.channelURL:
        return '📺 채널 — 이 채널 페이지·영상 (스케줄 ON + 확장)';
      case UnifiedRuleKind.videoURL:
        return '🎬 영상 — 이 watch 링크 (스케줄 ON + 확장)';
      case UnifiedRuleKind.host:
        if (d.numericStemEvasion) {
          return '🔢 숫자 우회 패턴 — **${d.pattern}**+숫자·TLD 전체 차단 (hosts+URLBlocklist)';
        }
        if (d.pattern == 'youtube.com') {
          return '🌐 youtube.com **전체** DNS 차단 (모든 채널·영상)';
        }
        if (d.normalizedFrom != null) {
          return '🌐 URL 붙여넣기 → **${d.pattern} 전체** 차단 (경로 무시 · hosts+PAC)';
        }
        return '🌐 도메인 차단: ${d.pattern} **사이트 전체** (hosts)';
      case UnifiedRuleKind.wildcard:
        return '🌐 와일드카드: ${d.pattern} 및 하위 호스트 (hosts)';
      case UnifiedRuleKind.keyword:
        return '🔑 키워드 — 검색·피드 **결과**에서 숨김 (브라우저 확장)';
      case UnifiedRuleKind.searchQuery:
        return '🔍 검색어 차단 — Google/YouTube **검색창**에 이 문구가 들어가면 막음';
    }
  }

  static bool _isYouTubeVideoUrl(String input) {
    final String t = input.toLowerCase();
    if (t.contains('youtu.be/')) return true;
    if (!t.contains('youtube')) return false;
    if (t.contains('/shorts/')) return true;
    if (t.contains('/embed/')) return true;
    if (RegExp(r'/v/[a-z0-9_-]+').hasMatch(t)) return true;
    if (t.contains('watch?v=') || t.contains('watch?') && t.contains('v=')) {
      return true;
    }
    return false;
  }

  static String _lowerUrl(String input) {
    String t = input.trim().toLowerCase();
    if (!t.contains('://')) {
      t = 'https://$t';
    }
    return t.replaceFirst(RegExp(r'^https?://'), '');
  }

  /// Channel id/handle pattern when URL contains youtube or bare @ / UC id.
  static String? _extractYouTubeChannel(String input) {
    final String t = _safeDecodeUrl(input.trim());
    final String lower = t.toLowerCase();

    // Bare @handle — supports Korean/Unicode (e.g. @뷰티풀너드).
    final RegExpMatch? bareAt =
        RegExp(r'^@([^/?#\s]+)$').firstMatch(t);
    if (bareAt != null) {
      final String handle = bareAt.group(1)!.trim();
      if (handle.isNotEmpty) return '@$handle';
    }

    if (RegExp(r'^UC[\w-]{10,}$', caseSensitive: false).hasMatch(t)) {
      return t.toUpperCase();
    }

    if (!lower.contains('youtube.com') && !lower.contains('youtu.be')) {
      return null;
    }

    String path = lower;
    path = path.replaceFirst(RegExp(r'^https?://'), '');
    path = path.replaceFirst(RegExp(r'^www\.'), '');
    final int yt = path.indexOf('youtube.com');
    if (yt >= 0) {
      path = path.substring(yt + 'youtube.com'.length);
    }

    if (path.contains('/watch') ||
        path.contains('/shorts/') ||
        path.contains('watch?v=')) {
      return null;
    }

    // /@handle — decode %EB… so copy-paste URLs match address-bar @뷰티풀너드.
    final RegExp atHandle = RegExp(r'/@([^/?#\s]+)', caseSensitive: false);
    final RegExpMatch? atM = atHandle.firstMatch(path);
    if (atM != null) {
      final String handle = _safeDecodeUrl(atM.group(1)!.trim());
      if (handle.isNotEmpty) return '@$handle';
    }

    final RegExp channelId = RegExp(r'/channel/(UC[\w-]+)', caseSensitive: false);
    final RegExpMatch? chM = channelId.firstMatch(path);
    if (chM != null) {
      return chM.group(1)!.toUpperCase();
    }

    final RegExp legacyC = RegExp(r'/c/([^/?#\s]+)', caseSensitive: false);
    final RegExpMatch? cM = legacyC.firstMatch(path);
    if (cM != null) {
      final String slug = _safeDecodeUrl(cM.group(1)!.trim());
      if (slug.isNotEmpty) return '@$slug';
    }

    final RegExp userPath = RegExp(r'/user/([^/?#\s]+)', caseSensitive: false);
    final RegExpMatch? uM = userPath.firstMatch(path);
    if (uM != null) {
      final String slug = _safeDecodeUrl(uM.group(1)!.trim());
      if (slug.isNotEmpty) return '@$slug';
    }

    return null;
  }

  static String _safeDecodeUrl(String s) {
    if (s.isEmpty || !s.contains('%')) return s;
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }

  static bool _isWildcardDomain(String input) {
    final String t = input.trim().toLowerCase();
    return t.startsWith('*.') && t.length > 2 && !t.contains(' ');
  }

  /// Classify an already-saved row for list badges (domains vs keywords table).
  static UnifiedRuleKind inferStoredKind({
    required String value,
    required bool isDomainRow,
  }) {
    if (isDomainRow) {
      return UnifiedRuleKind.host;
    }
    final String p = value.trim().toLowerCase();
    if (p.isEmpty) return UnifiedRuleKind.keyword;
    if (p.contains('watch?v=') ||
        p.contains('youtu.be/') ||
        p.contains('/shorts/') ||
        p.contains('/embed/')) {
      return UnifiedRuleKind.videoURL;
    }
    if (p.startsWith('@') ||
        p.contains('youtube.com/@') ||
        p.contains('/channel/uc') ||
        p.contains('youtube.com/channel/')) {
      return UnifiedRuleKind.channelURL;
    }
    if (p.contains('youtube.com/') && !p.endsWith('youtube.com')) {
      return UnifiedRuleKind.channelURL;
    }
    return UnifiedRuleKind.keyword;
  }

  /// `example.com/foo` or `sub.example.co.kr/bar` without `https://`.
  static bool _looksLikeDomainWithPath(String input) {
    final String first = input.trim().split(RegExp(r'\s+')).first;
    if (!first.contains('/')) return false;
    if (first.contains('://')) return false;
    if (first.startsWith('@')) return false;
    final String hostPart = first.split('/').first;
    if (hostPart.isEmpty) return false;
    return RegExp(
      r'^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$',
      caseSensitive: false,
    ).hasMatch(hostPart);
  }

  static bool _looksLikeKeyword(String input) {
    final String t = input.trim();
    if (t.contains('://')) return false;
    if (t.startsWith('*.') || t.contains('*')) return false;
    if (_looksLikeDomainWithPath(t)) return false;

    final String first = t.split(RegExp(r'\s+')).first.toLowerCase();
    if (RegExp(r'^[a-z0-9][-a-z0-9]*\.[a-z]{2,}$').hasMatch(first)) {
      return false;
    }
    if (RegExp(r'^[a-z0-9-]+\.[a-z]{2,}\.[a-z]{2,}$').hasMatch(first)) {
      return false;
    }
    return true;
  }
}
