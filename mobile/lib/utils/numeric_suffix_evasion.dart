/// 음란 사이트가 `linkdamoa01.com` → `linkdamoa02.com` 처럼 **끝 숫자만 바꿔**
/// 차단을 우회하는 패턴을 감지·확장합니다.
abstract final class NumericSuffixEvasion {
  static const int minStemLength = 5;
  static const int maxSuffixDigits = 4;

  static final RegExp _labelWithTrailingDigits = RegExp(
    r'^([a-z][a-z0-9-]*?)(\d+)$',
    caseSensitive: false,
  );

  /// `linkdamoa01.com` → stem `linkdamoa`, `yagong91.net` → `yagong`.
  static NumericSuffixEvasionMatch? fromHost(String input) {
    String host = input.trim().toLowerCase();
    host = host.replaceFirst(RegExp(r'^https?://'), '');
    host = host.split('/').first;
    host = host.replaceFirst(RegExp(r':\d+$'), '');
    if (host.startsWith('www.') && host.split('.').length >= 3) {
      host = host.substring(4);
    }

    final List<String> parts = host.split('.');
    if (parts.length < 2) return null;

    final String label = parts.first;
    if (label.isEmpty) return null;

    final RegExpMatch? m = _labelWithTrailingDigits.firstMatch(label);
    if (m == null) return null;

    final String stem = m.group(1)!.toLowerCase();
    final String digits = m.group(2)!;
    if (stem.length < minStemLength) return null;
    if (digits.isEmpty || digits.length > maxSuffixDigits) return null;
    if (stem == digits) return null;

    final String tld = parts.sublist(1).join('.');
    return NumericSuffixEvasionMatch(
      stem: stem,
      numericSuffix: digits,
      exampleHost: '$label.$tld',
      tld: tld,
    );
  }

  /// 브라우저 확장 키워드(호스트 glob).
  static List<String> keywordPatternsForStem(String stem) {
    final String s = stem.trim().toLowerCase();
    if (s.isEmpty) return const <String>[];
    const List<String> tlds = <String>[
      'com',
      'net',
      'org',
      'xyz',
      'top',
      'live',
      'tv',
      'cc',
      'site',
    ];
    final Set<String> out = <String>{};
    for (final String tld in tlds) {
      out.add('$s*.$tld');
      out.add('www.$s*.$tld');
      out.add('m.$s*.$tld');
    }
    return out.toList()..sort();
  }

  /// Chrome/Edge URLBlocklist — `*://linkdamoa*.com/*` 형태.
  static List<String> urlBlocklistPatternsForStem(String stem) {
    final String s = stem.trim().toLowerCase();
    if (s.isEmpty) return const <String>[];
    const List<String> tlds = <String>[
      'com',
      'net',
      'org',
      'xyz',
      'top',
      'live',
      'tv',
    ];
    final List<String> out = <String>[];
    for (final String tld in tlds) {
      out.add('*://$s*.$tld/*');
      out.add('*://www.$s*.$tld/*');
      out.add('*://m.$s*.$tld/*');
      out.add('*://*.$s*.$tld/*');
    }
    return out;
  }

  /// Windows hosts — stem + 숫자 접미(1~99, 01~09) × 주요 TLD.
  /// Chrome URLBlocklist host filters for concrete numeric hosts.
  ///
  /// Chromium URLBlocklist accepts bare hosts such as `mingky01.live`, which
  /// cover both the apex and subdomains. Keep this list dense so important
  /// rotating mirrors survive Chrome's URLBlocklist row cap.
  static List<String> chromiumPolicyHostFiltersForStem(
    String stem, {
    int maxHosts = 8,
  }) {
    final List<String> hosts = priorityConcreteApexForStem(
      stem,
      maxHosts: maxHosts,
    );
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final String host in hosts) {
      final String h = host.trim().toLowerCase();
      if (h.isEmpty) continue;
      if (seen.add(h)) out.add(h);
    }
    return out;
  }

  static Set<String> expandedHostsForStem(String stem, {int maxHosts = 200}) {
    return priorityConcreteApexForStem(stem, maxHosts: maxHosts).toSet();
  }

  /// Chrome/Edge URLBlocklist는 `mingky*.live` 같은 호스트 중간 `*`를
  /// 막지 않습니다 — `mingky01.live` 등 **구체 apex**를 먼저 씁니다.
  ///
  /// 접미(01~99) 바깥 루프 · `.live`·`.com` 우선 — 예산 72가 `.com`만
  /// 채우고 `.live`가 빠지는 문제를 방지합니다.
  static List<String> priorityConcreteApexForStem(
    String stem, {
    int maxHosts = 200,
  }) {
    final String s = stem.replaceAll(RegExp(r'[^a-z0-9-]'), '').toLowerCase();
    if (s.isEmpty || maxHosts <= 0) return const <String>[];
    const List<String> tlds = <String>[
      'live',
      'com',
      'net',
      'org',
      'xyz',
      'top',
      'tv',
      'site',
      'cc',
    ];
    final List<String> out = <String>[];
    void push(String host) {
      if (out.length >= maxHosts) return;
      final String h = host.trim().toLowerCase();
      if (h.isEmpty || out.contains(h)) return;
      out.add(h);
    }

    for (int i = 1; i <= 99; i++) {
      if (out.length >= maxHosts) break;
      final List<String> labels = <String>[
        if (i <= 9) '$s${i.toString().padLeft(2, '0')}',
        '$s$i',
      ];
      final Set<String> seenLabels = <String>{};
      for (final String label in labels) {
        if (!seenLabels.add(label)) continue;
        for (final String tld in tlds) {
          push('$label.$tld');
          push('www.$label.$tld');
          if (out.length >= maxHosts) break;
        }
        if (out.length >= maxHosts) break;
      }
    }
    return out;
  }

  /// Health probe — `*://mingky01.live/*` 등 숫자 우회 apex URLBlocklist 행.
  static bool isConcreteNumericApexBlocklistPattern(String pattern) {
    final RegExpMatch? m = RegExp(
      r'^\*://(?:\*\.)?([a-z][a-z0-9-]*\d+)\.([a-z]{2,})/\*$',
      caseSensitive: false,
    ).firstMatch(pattern.trim());
    return m != null && !m.group(1)!.contains('*');
  }
}

final class NumericSuffixEvasionMatch {
  const NumericSuffixEvasionMatch({
    required this.stem,
    required this.numericSuffix,
    required this.exampleHost,
    required this.tld,
  });

  final String stem;
  final String numericSuffix;
  final String exampleHost;
  final String tld;

  String get userMessageKo =>
      '「$exampleHost」은 숫자 우회 음란 사이트 패턴으로 인식했습니다.\n'
      '「$stem」+숫자($numericSuffix 등) 전체를 한 번에 차단합니다.';
}
