/// One domain rule in a quick-block bundle (same fields as schedule domains).
class QuickBlockDomainRule {
  const QuickBlockDomainRule({required this.host, this.isStem = false});

  final String host;
  final bool isStem;

  Map<String, Object?> toJson() => <String, Object?>{
        'host': host,
        'isStem': isStem,
      };

  static QuickBlockDomainRule fromJson(Map<String, Object?> json) {
    return QuickBlockDomainRule(
      host: '${json['host'] ?? ''}',
      isStem: json['isStem'] == true,
    );
  }
}

/// Browser-extension keyword / YouTube channel·video pattern in a quick-block bundle.
class QuickBlockKeywordRule {
  const QuickBlockKeywordRule({required this.pattern});

  final String pattern;

  Map<String, Object?> toJson() => <String, Object?>{'pattern': pattern};

  static QuickBlockKeywordRule fromJson(Map<String, Object?> json) {
    return QuickBlockKeywordRule(pattern: '${json['pattern'] ?? ''}'.trim());
  }
}

/// One app rule in a quick-block bundle (display name + optional win bundle).
class QuickBlockAppRule {
  const QuickBlockAppRule({
    required this.displayName,
    this.bundleId,
  });

  final String displayName;
  final String? bundleId;

  Map<String, Object?> toJson() => <String, Object?>{
        'displayName': displayName,
        if (bundleId != null && bundleId!.isNotEmpty) 'bundleId': bundleId,
      };

  static QuickBlockAppRule fromJson(Map<String, Object?> json) {
    return QuickBlockAppRule(
      displayName: '${json['displayName'] ?? json['name'] ?? ''}',
      bundleId: json['bundleId'] as String?,
    );
  }
}
