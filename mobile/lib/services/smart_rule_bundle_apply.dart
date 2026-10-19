import 'package:flutter/material.dart';

import '../models/quick_block_rule_entries.dart';
import '../models/unified_rule_kind.dart';
import '../utils/url_rule_detector.dart';
import '../utils/youtube_blocklist_parser.dart';
import '../widgets/youtube_host_confirm_dialog.dart';
import 'schedule_rule_validation.dart';
import 'youtube_schedule_block_service.dart';

/// Smart input → in-memory quick-block bundle domains + keywords.
final class SmartRuleBundleApply {
  SmartRuleBundleApply._();

  static Future<SmartRuleBundleResult> applyLine({
    required BuildContext context,
    required String rawLine,
    required Set<String> existingHosts,
    required Set<String> existingKeywords,
    bool domainAsStem = false,
  }) async {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      return const SmartRuleBundleResult(lineIgnored: true);
    }

    final DetectedRule detected = UrlRuleDetector.detect(line);

    switch (detected.kind) {
      case UnifiedRuleKind.videoURL:
      case UnifiedRuleKind.channelURL:
        return _applyYouTubePatterns(
          line,
          existingKeywords,
          detected.kind,
        );

      case UnifiedRuleKind.keyword:
      case UnifiedRuleKind.searchQuery:
        final String pat = detected.pattern;
        final String? kwErr = ScheduleRuleValidation.validateKeyword(pat);
        if (kwErr != null) {
          return SmartRuleBundleResult(error: kwErr, kind: detected.kind);
        }
        if (existingKeywords.contains(pat)) {
          return SmartRuleBundleResult(duplicates: 1, kind: detected.kind);
        }
        return SmartRuleBundleResult(
          keywords: <QuickBlockKeywordRule>[QuickBlockKeywordRule(pattern: pat)],
          kind: detected.kind,
        );

      case UnifiedRuleKind.host:
      case UnifiedRuleKind.wildcard:
        final String host = detected.pattern;
        if (host.isEmpty) {
          return const SmartRuleBundleResult(error: '값을 입력하세요.');
        }
        if (host == 'youtube.com' && context.mounted) {
          final bool ok = await showYoutubeHostConfirmDialog(context);
          if (!ok) {
            return const SmartRuleBundleResult(cancelled: true);
          }
        }
        final String? hostErr = ScheduleRuleValidation.validateHost(host);
        if (hostErr != null) {
          return SmartRuleBundleResult(error: hostErr, kind: detected.kind);
        }
        final bool asStem = domainAsStem || detected.numericStemEvasion;
        if (existingHosts.contains(host)) {
          return SmartRuleBundleResult(duplicates: 1, kind: detected.kind);
        }
        return SmartRuleBundleResult(
          domain: QuickBlockDomainRule(host: host, isStem: asStem),
          kind: detected.kind,
          hostTruncationNote: detected.numericEvasionNote ??
              (detected.normalizedFrom != null
                  ? '경로는 hosts에 쓸 수 없어 "$host" 도메인만 추가했습니다.'
                  : null),
        );
    }
  }

  static SmartRuleBundleResult _applyYouTubePatterns(
    String line,
    Set<String> existingKeywords,
    UnifiedRuleKind kind,
  ) {
    final String normalized = YouTubeScheduleBlockService.normalizeInputLine(line);
    final YouTubeBlocklistBatch batch =
        parseYouTubeBlocklistLines(<String>[normalized]);
    if (batch.rules.isEmpty) {
      return const SmartRuleBundleResult(
        error: '인식할 수 없는 YouTube 주소입니다.',
        kind: UnifiedRuleKind.channelURL,
      );
    }
    final List<QuickBlockKeywordRule> added = <QuickBlockKeywordRule>[];
    int skipped = 0;
    for (final rule in batch.rules) {
      final String? pat = rule.keywordPattern?.trim().toLowerCase();
      if (pat == null || pat.isEmpty) continue;
      if (existingKeywords.contains(pat)) {
        skipped++;
        continue;
      }
      added.add(QuickBlockKeywordRule(pattern: pat));
      existingKeywords.add(pat);
    }
    if (added.isEmpty && skipped > 0) {
      return SmartRuleBundleResult(duplicates: skipped, kind: kind);
    }
    if (added.isEmpty) {
      return const SmartRuleBundleResult(
        error: '추가할 YouTube 패턴이 없습니다.',
        kind: UnifiedRuleKind.channelURL,
      );
    }
    return SmartRuleBundleResult(keywords: added, skippedDuplicates: skipped, kind: kind);
  }
}

final class SmartRuleBundleResult {
  const SmartRuleBundleResult({
    this.domain,
    this.keywords = const <QuickBlockKeywordRule>[],
    this.error,
    this.cancelled = false,
    this.duplicates = 0,
    this.skippedDuplicates = 0,
    this.lineIgnored = false,
    this.kind,
    this.hostTruncationNote,
  });

  final QuickBlockDomainRule? domain;
  final List<QuickBlockKeywordRule> keywords;
  final String? error;
  final bool cancelled;
  final int duplicates;
  final int skippedDuplicates;
  final bool lineIgnored;
  final UnifiedRuleKind? kind;
  final String? hostTruncationNote;

  int get addedCount => (domain != null ? 1 : 0) + keywords.length;

  bool get ok => addedCount > 0;
}
