import 'dart:convert';

/// Contract aligned with Step 1 blueprint (schemaVersion + rule arrays).
class RulesBundle {
  const RulesBundle({
    required this.schemaVersion,
    required this.updatedAt,
    required this.strictness,
    this.keywordRules = const [],
    this.domainRules = const [],
    this.serpFilters = const [],
    this.searchQueryBlocklist = const [],
    this.focusEnabled = false,
    this.unlockPinRequired = true,
    this.unlockCooldownSeconds = 60,
  });

  final int schemaVersion;
  final DateTime updatedAt;
  final String strictness;
  final List<KeywordRule> keywordRules;
  final List<DomainRule> domainRules;
  final List<SerpFilter> serpFilters;
  final List<SearchQueryBlock> searchQueryBlocklist;
  final bool focusEnabled;
  final bool unlockPinRequired;
  final int unlockCooldownSeconds;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'strictness': strictness,
        'keywordRules': keywordRules.map((e) => e.toJson()).toList(),
        'domainRules': domainRules.map((e) => e.toJson()).toList(),
        'serpFilters': serpFilters.map((e) => e.toJson()).toList(),
        'searchQueryBlocklist': searchQueryBlocklist.map((e) => e.toJson()).toList(),
        'focus': <String, Object?>{
          'enabled': focusEnabled,
          'unlock': <String, Object?>{
            'pinRequired': unlockPinRequired,
            'cooldownSeconds': unlockCooldownSeconds,
          },
        },
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class KeywordRule {
  const KeywordRule({
    required this.id,
    required this.pattern,
    this.match = 'contains',
    this.caseSensitive = false,
    this.action = 'redact',
    this.enabled = true,
  });

  final String id;
  final String pattern;
  final String match;
  final bool caseSensitive;
  final String action;
  final bool enabled;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'pattern': pattern,
        'match': match,
        'caseSensitive': caseSensitive,
        'action': action,
        'enabled': enabled,
      };
}

class DomainRule {
  const DomainRule({
    required this.id,
    required this.host,
    this.includeSubdomains = true,
    this.action = 'block_document',
    this.enabled = true,
    this.source = 'user',
  });

  final String id;
  final String host;
  final bool includeSubdomains;
  final String action;
  final bool enabled;
  final String source;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'host': host,
        'includeSubdomains': includeSubdomains,
        'action': action,
        'enabled': enabled,
        'source': source,
      };
}

class SerpFilter {
  const SerpFilter({
    required this.id,
    required this.hostSuffix,
    required this.pathPrefix,
    this.removeSelectors = const <String>[],
    this.enabled = false,
  });

  final String id;
  final String hostSuffix;
  final String pathPrefix;
  final List<String> removeSelectors;
  final bool enabled;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'hostSuffix': hostSuffix,
        'pathPrefix': pathPrefix,
        'removeSelectors': removeSelectors,
        'enabled': enabled,
      };
}

class SearchQueryBlock {
  const SearchQueryBlock({
    required this.id,
    required this.term,
    this.match = 'exact',
    this.enabled = true,
    this.scope = 'in_app_browser_only',
  });

  final String id;
  final String term;
  final String match;
  final bool enabled;
  final String scope;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'term': term,
        'match': match,
        'enabled': enabled,
        'scope': scope,
      };
}
