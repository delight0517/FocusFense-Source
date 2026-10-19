import 'url_rule_matcher.dart';

/// How a Cold Turkey / blocklist line should be enforced in 6 VPN Blocker.
enum ColdTurkeyRuleKind {
  /// Full site — written to `domains` → DNS/`hosts` + extension domain list.
  domain,

  /// `host/path` — keyword only (DNS cannot see path); extension URL match.
  path,

  /// `*.*/*q=*…*` or `youtube.*/*search_query=*…*` — keyword glob pattern.
  urlPattern,
}

final class ColdTurkeyParsedRule {
  const ColdTurkeyParsedRule({
    required this.raw,
    required this.kind,
    this.domainHost,
    this.keywordPattern,
    this.includeSubdomains = true,
  });

  final String raw;
  final ColdTurkeyRuleKind kind;
  final String? domainHost;
  final String? keywordPattern;
  final bool includeSubdomains;
}

final class ColdTurkeyImportBatch {
  ColdTurkeyImportBatch({List<ColdTurkeyParsedRule>? rules})
    : rules = rules ?? <ColdTurkeyParsedRule>[];

  final List<ColdTurkeyParsedRule> rules;

  int get domainCount => rules
      .where((ColdTurkeyParsedRule r) => r.kind == ColdTurkeyRuleKind.domain)
      .length;

  int get pathCount => rules
      .where((ColdTurkeyParsedRule r) => r.kind == ColdTurkeyRuleKind.path)
      .length;

  int get urlPatternCount => rules
      .where(
        (ColdTurkeyParsedRule r) => r.kind == ColdTurkeyRuleKind.urlPattern,
      )
      .length;

  List<String> get domainHosts => rules
      .where((ColdTurkeyParsedRule r) => r.kind == ColdTurkeyRuleKind.domain)
      .map((ColdTurkeyParsedRule r) => r.domainHost!)
      .toList();

  List<String> get keywordPatterns => rules
      .where(
        (ColdTurkeyParsedRule r) =>
            r.kind == ColdTurkeyRuleKind.path ||
            r.kind == ColdTurkeyRuleKind.urlPattern,
      )
      .map((ColdTurkeyParsedRule r) => r.keywordPattern!)
      .toList();
}

/// Classifies one non-comment line from a Cold Turkey export or generic list.
ColdTurkeyParsedRule? parseColdTurkeyLine(String line) {
  String t = line.trim();
  if (t.isEmpty || t.startsWith('#')) return null;

  final bool hasColdTurkeyRegexSyntax =
      t.contains('[?&]') ||
      t.contains('[*]') ||
      RegExp(r'\([^()]*\|[^()]*\)').hasMatch(t);
  if (!hasColdTurkeyRegexSyntax && (t.contains('[') || t.contains(']'))) {
    t = t.replaceAll(RegExp(r'\[.*?\]|\(.*?\)'), '').trim();
  }
  if (t.isEmpty) return null;

  // Skip obvious IPs.
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(t.split('/').first)) {
    return null;
  }
  if (t.startsWith('127.') || t.startsWith('0.')) return null;

  final bool hasStar = t.contains('*');
  final int slash = t.indexOf('/');
  final String hostPattern = slash >= 0 ? t.substring(0, slash) : t;
  final bool simpleTldWildcard = RegExp(
    r'^[a-z0-9-]+\.\*$',
  ).hasMatch(hostPattern);
  final bool wildcardHostPattern =
      hasStar && hostPattern.contains('*') && !simpleTldWildcard;

  // Layer 3 — wildcard query / platform patterns.
  if (hasStar &&
      (t.contains('*q=*') ||
          t.contains('*p=*') ||
          t.contains('search_query=') ||
          t.startsWith('*.*') ||
          wildcardHostPattern ||
          RegExp(r'[a-z0-9-]+\.\*').hasMatch(t))) {
    return ColdTurkeyParsedRule(
      raw: line,
      kind: ColdTurkeyRuleKind.urlPattern,
      keywordPattern: t.toLowerCase(),
    );
  }

  // Layer 2 — surgical path (no leading *.*).
  if (slash > 0 && !t.startsWith('*.*')) {
    String hostPart = t.substring(0, slash).toLowerCase().replaceAll('*', '');
    if (hostPart.startsWith('www.')) {
      hostPart = hostPart.substring(4);
    }
    final String pathPart = t.substring(slash).toLowerCase();
    if (hostPart.contains('.') && pathPart.length > 1) {
      return ColdTurkeyParsedRule(
        raw: line,
        kind: ColdTurkeyRuleKind.path,
        keywordPattern: '$hostPart$pathPart',
      );
    }
  }

  // Layer 1 — domain / host lockdown.
  String hostOnly = t;
  if (slash > 0) {
    hostOnly = t.substring(0, slash);
  }
  hostOnly = hostOnly.split('?').first.replaceAll('*', '').trim().toLowerCase();
  if (hostOnly.startsWith('www.')) {
    hostOnly = hostOnly.substring(4);
  }
  if (hostOnly.isEmpty || !hostOnly.contains('.') || hostOnly.contains('://')) {
    return null;
  }

  // `youtube.*` without path → DNS youtube.com + extension `youtube.*` host glob.
  if (t.endsWith('.*') && slash < 0) {
    String base = hostOnly;
    if (base.endsWith('.')) base = base.substring(0, base.length - 1);
    final String dnsHost = base.contains('.') && !base.endsWith('.com')
        ? base
        : '$base.com';
    return ColdTurkeyParsedRule(
      raw: line,
      kind: ColdTurkeyRuleKind.domain,
      domainHost: dnsHost,
      keywordPattern: t.toLowerCase(),
      includeSubdomains: true,
    );
  }

  return ColdTurkeyParsedRule(
    raw: line,
    kind: ColdTurkeyRuleKind.domain,
    domainHost: hostOnly,
    includeSubdomains: true,
  );
}

ColdTurkeyImportBatch parseColdTurkeyLines(Iterable<String> lines) {
  final List<ColdTurkeyParsedRule> out = <ColdTurkeyParsedRule>[];
  final Set<String> seenDomains = <String>{};
  final Set<String> seenKeywords = <String>{};

  for (final String line in lines) {
    final ColdTurkeyParsedRule? rule = parseColdTurkeyLine(line);
    if (rule == null) continue;

    switch (rule.kind) {
      case ColdTurkeyRuleKind.domain:
        final String h = rule.domainHost!;
        if (seenDomains.add(h)) {
          out.add(rule);
        }
        final String? extra = rule.keywordPattern;
        if (extra != null && extra != h && seenKeywords.add(extra)) {
          out.add(
            ColdTurkeyParsedRule(
              raw: rule.raw,
              kind: ColdTurkeyRuleKind.urlPattern,
              keywordPattern: extra,
            ),
          );
        }
        break;
      case ColdTurkeyRuleKind.path:
      case ColdTurkeyRuleKind.urlPattern:
        final String k = rule.keywordPattern!;
        if (seenKeywords.add(k)) {
          out.add(rule);
        }
        break;
    }
  }
  return ColdTurkeyImportBatch(rules: out);
}

/// Quick sanity check used after import (optional diagnostics).
bool coldTurkeyPatternWouldBlock(String pattern, String exampleUrl) =>
    urlMatchesColdTurkeyPattern(exampleUrl, pattern);
