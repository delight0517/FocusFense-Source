import 'quick_block_rule_entries.dart';

/// User-defined quick block preset (sites + apps — same shape as schedule rules).
class QuickBlockUserBundle {
  const QuickBlockUserBundle({
    required this.id,
    required this.label,
    this.domains = const <QuickBlockDomainRule>[],
    this.keywords = const <QuickBlockKeywordRule>[],
    this.apps = const <QuickBlockAppRule>[],
    this.enabled = true,
  });

  final String id;
  final String label;
  final List<QuickBlockDomainRule> domains;
  final List<QuickBlockKeywordRule> keywords;
  final List<QuickBlockAppRule> apps;
  final bool enabled;

  /// Legacy: host strings only (no stem).
  List<String> get hosts =>
      domains.map((QuickBlockDomainRule d) => d.host).toList();

  /// Legacy: display names only.
  List<String> get appNames =>
      apps.map((QuickBlockAppRule a) => a.displayName).toList();

  QuickBlockUserBundle copyWith({
    String? id,
    String? label,
    List<QuickBlockDomainRule>? domains,
    List<QuickBlockKeywordRule>? keywords,
    List<QuickBlockAppRule>? apps,
    bool? enabled,
  }) {
    return QuickBlockUserBundle(
      id: id ?? this.id,
      label: label ?? this.label,
      domains: domains ?? this.domains,
      keywords: keywords ?? this.keywords,
      apps: apps ?? this.apps,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'domains': domains.map((QuickBlockDomainRule d) => d.toJson()).toList(),
    'keywords': keywords.map((QuickBlockKeywordRule k) => k.toJson()).toList(),
    'apps': apps.map((QuickBlockAppRule a) => a.toJson()).toList(),
    'enabled': enabled,
  };

  static QuickBlockUserBundle fromJson(Map<String, Object?> json) {
    List<QuickBlockDomainRule> domainRules = <QuickBlockDomainRule>[];
    if (json['domains'] is List) {
      domainRules = (json['domains'] as List)
          .whereType<Map>()
          .map(
            (Map m) =>
                QuickBlockDomainRule.fromJson(Map<String, Object?>.from(m)),
          )
          .toList();
    } else {
      domainRules = _stringList(
        json['hosts'],
      ).map((String h) => QuickBlockDomainRule(host: h)).toList();
    }

    List<QuickBlockKeywordRule> keywordRules = <QuickBlockKeywordRule>[];
    if (json['keywords'] is List) {
      keywordRules = (json['keywords'] as List)
          .whereType<Map>()
          .map(
            (Map m) =>
                QuickBlockKeywordRule.fromJson(Map<String, Object?>.from(m)),
          )
          .where((QuickBlockKeywordRule k) => k.pattern.isNotEmpty)
          .toList();
    }

    List<QuickBlockAppRule> appRules = <QuickBlockAppRule>[];
    if (json['apps'] is List) {
      appRules = (json['apps'] as List)
          .whereType<Map>()
          .map(
            (Map m) => QuickBlockAppRule.fromJson(Map<String, Object?>.from(m)),
          )
          .toList();
    } else {
      appRules = _stringList(
        json['appNames'],
      ).map((String n) => QuickBlockAppRule(displayName: n)).toList();
    }

    return QuickBlockUserBundle(
      id: '${json['id'] ?? ''}',
      label: '${json['label'] ?? '퀵 블록'}',
      domains: domainRules,
      keywords: keywordRules,
      apps: appRules,
      enabled: json['enabled'] != false,
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return <String>[];
    return raw
        .map((Object? e) => '$e'.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
  }
}

/// Active timed quick-block session (domains + optional app kill list).
class QuickBlockSession {
  const QuickBlockSession({
    required this.startedAtMs,
    required this.untilMs,
    required this.cancelNotBeforeMs,
    required this.bundleIds,
    required this.appNames,
    this.releaseRequired = false,
  });

  final int startedAtMs;
  final int untilMs;
  final int cancelNotBeforeMs;
  final List<String> bundleIds;
  final List<String> appNames;

  /// Keep protection after the minimum period until an explicit release.
  final bool releaseRequired;

  bool get isActive =>
      releaseRequired || DateTime.now().millisecondsSinceEpoch < untilMs;

  Duration get remaining => Duration(
    milliseconds: (untilMs - DateTime.now().millisecondsSinceEpoch).clamp(
      0,
      1 << 31,
    ),
  );

  Duration? get cancelCountdownRemaining {
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now >= cancelNotBeforeMs) return null;
    return Duration(milliseconds: cancelNotBeforeMs - now);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'startedAtMs': startedAtMs,
    'untilMs': untilMs,
    'cancelNotBeforeMs': cancelNotBeforeMs,
    'bundleIds': bundleIds,
    'appNames': appNames,
    'releaseRequired': releaseRequired,
  };

  static QuickBlockSession? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final int until = (json['untilMs'] as num?)?.toInt() ?? 0;
    if (until <= 0) return null;
    return QuickBlockSession(
      startedAtMs: (json['startedAtMs'] as num?)?.toInt() ?? 0,
      untilMs: until,
      cancelNotBeforeMs: (json['cancelNotBeforeMs'] as num?)?.toInt() ?? 0,
      bundleIds: QuickBlockUserBundle._stringList(json['bundleIds']),
      appNames: QuickBlockUserBundle._stringList(json['appNames']),
      releaseRequired: json['releaseRequired'] == true,
    );
  }
}
