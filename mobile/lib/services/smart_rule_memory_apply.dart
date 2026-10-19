import 'package:flutter/material.dart';

import '../models/quick_block_rule_entries.dart';
import '../models/unified_rule_kind.dart';
import 'smart_rule_bundle_apply.dart';

/// Domain-only wrapper — prefer [SmartRuleBundleApply] for full bundles.
final class SmartRuleMemoryApply {
  SmartRuleMemoryApply._();

  static Future<SmartRuleMemoryResult> applyLine({
    required BuildContext context,
    required String rawLine,
    required Set<String> existingHosts,
    bool domainAsStem = false,
  }) async {
    final SmartRuleBundleResult r = await SmartRuleBundleApply.applyLine(
      context: context,
      rawLine: rawLine,
      existingHosts: existingHosts,
      existingKeywords: <String>{},
      domainAsStem: domainAsStem,
    );
    if (r.keywords.isNotEmpty) {
      return SmartRuleMemoryResult(
        error:
            '이 카드는 도메인만 추가합니다. '
            '채널·키워드는 「퀵 블록 편집」 통합 카드를 사용하세요.',
        kind: r.kind,
      );
    }
    return SmartRuleMemoryResult(
      domain: r.domain,
      error: r.error,
      cancelled: r.cancelled,
      duplicates: r.duplicates,
      lineIgnored: r.lineIgnored,
      kind: r.kind,
      hostTruncationNote: r.hostTruncationNote,
    );
  }
}

final class SmartRuleMemoryResult {
  const SmartRuleMemoryResult({
    this.domain,
    this.error,
    this.cancelled = false,
    this.duplicates = 0,
    this.lineIgnored = false,
    this.kind,
    this.hostTruncationNote,
  });

  final QuickBlockDomainRule? domain;
  final String? error;
  final bool cancelled;
  final int duplicates;
  final bool lineIgnored;
  final UnifiedRuleKind? kind;
  final String? hostTruncationNote;

  bool get ok => domain != null;
}
