enum ScheduledRuleKind { domain, keyword }

/// A persisted request to remove one rule after a delay.
final class ScheduledRuleRemoval {
  const ScheduledRuleRemoval({
    required this.ruleKind,
    required this.ruleId,
    required this.label,
    required this.dueAt,
  });

  final ScheduledRuleKind ruleKind;
  final String ruleId;
  final String label;
  final DateTime dueAt;

  String get key => '${ruleKind.name}:$ruleId';

  Map<String, Object?> toJson() => <String, Object?>{
    'ruleKind': ruleKind.name,
    'ruleId': ruleId,
    'label': label,
    'dueAt': dueAt.millisecondsSinceEpoch,
  };

  static ScheduledRuleRemoval? fromJson(Map<String, Object?> json) {
    final ScheduledRuleKind? kind = switch (json['ruleKind']) {
      'domain' => ScheduledRuleKind.domain,
      'keyword' => ScheduledRuleKind.keyword,
      _ => null,
    };
    final String id = '${json['ruleId'] ?? ''}';
    final int? dueAt = (json['dueAt'] as num?)?.toInt();
    if (kind == null || id.isEmpty || dueAt == null) return null;
    return ScheduledRuleRemoval(
      ruleKind: kind,
      ruleId: id,
      label: '${json['label'] ?? ''}',
      dueAt: DateTime.fromMillisecondsSinceEpoch(dueAt),
    );
  }
}
