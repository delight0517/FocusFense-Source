import 'package:flutter/material.dart';

import '../models/unified_rule_kind.dart';
import '../utils/url_rule_detector.dart';

/// Small badge for a stored domain or keyword pattern.
class UnifiedRuleKindChip extends StatelessWidget {
  const UnifiedRuleKindChip({
    super.key,
    required this.value,
    this.isDomainRow = false,
    this.compact = true,
    this.kind,
  });

  final String value;
  final bool isDomainRow;
  final bool compact;

  /// When set (e.g. search_query_blocks rows), skips [inferStoredKind].
  final UnifiedRuleKind? kind;

  @override
  Widget build(BuildContext context) {
    final UnifiedRuleKind resolved = kind ??
        UrlRuleDetector.inferStoredKind(
          value: value,
          isDomainRow: isDomainRow,
        );
    final String label = '${resolved.badgeEmoji} ${resolved.shortLabelKo}';
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
