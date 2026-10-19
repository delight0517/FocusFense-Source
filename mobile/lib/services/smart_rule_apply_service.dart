import 'dart:io';

import 'package:flutter/material.dart';

import '../models/unified_rule_kind.dart';
import '../utils/url_rule_detector.dart';
import '../utils/youtube_blocklist_parser.dart';
import '../widgets/youtube_host_confirm_dialog.dart';
import 'block_sync_service.dart';
import 'local_database.dart';
import 'schedule_rule_validation.dart';
import 'universal_browser_block_service.dart';
import 'youtube_schedule_block_service.dart';

/// Applies [UrlRuleDetector] results to keywords / domains tables.
final class SmartRuleApplyService {
  SmartRuleApplyService._();
  static final SmartRuleApplyService instance = SmartRuleApplyService._();

  Future<SmartRuleApplyResult> applyLine({
    required BuildContext context,
    required String rawLine,
    String? scheduleId,
    bool domainAsStem = false,
    required Set<String> existingDomains,
    required Set<String> existingKeywords,
    Set<String> existingSearchQueries = const <String>{},
    String Function()? newId,
  }) async {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      return const SmartRuleApplyResult(lineIgnored: true);
    }

    final DetectedRule detected = UrlRuleDetector.detect(line);

    switch (detected.kind) {
      case UnifiedRuleKind.videoURL:
      case UnifiedRuleKind.channelURL:
        if (scheduleId == null) {
          return _applyYouTubeGlobal(line, existingKeywords, newId);
        }
        final yt = await YouTubeScheduleBlockService.instance.addToSchedule(
          scheduleId: scheduleId,
          urlOrHandle: line,
        );
        if (yt.error != null && yt.added == 0) {
          return SmartRuleApplyResult(
            error: yt.error,
            kind: detected.kind,
          );
        }
        for (final String p in yt.patterns) {
          existingKeywords.add(p);
        }
        return SmartRuleApplyResult(
          keywordsAdded: yt.added,
          skippedDuplicates: yt.skipped,
          kind: detected.kind,
          patterns: yt.patterns,
        );

      case UnifiedRuleKind.keyword:
        final String? kwErr =
            ScheduleRuleValidation.validateKeyword(detected.pattern);
        if (kwErr != null) {
          return SmartRuleApplyResult(error: kwErr, kind: detected.kind);
        }
        if (existingKeywords.contains(detected.pattern)) {
          return SmartRuleApplyResult(
            duplicates: 1,
            kind: detected.kind,
          );
        }
        final String kid = newId?.call() ?? _defaultId();
        await LocalDatabase.instance.insertKeyword(
          id: kid,
          pattern: detected.pattern,
          scheduleId: scheduleId,
        );
        existingKeywords.add(detected.pattern);
        return SmartRuleApplyResult(
          keywordsAdded: 1,
          kind: detected.kind,
          patterns: <String>[detected.pattern],
        );

      case UnifiedRuleKind.searchQuery:
        final String term = detected.pattern.trim().toLowerCase();
        if (term.isEmpty) {
          return const SmartRuleApplyResult(error: '검색어를 입력하세요.');
        }
        if (existingSearchQueries.contains(term)) {
          return SmartRuleApplyResult(
            duplicates: 1,
            kind: detected.kind,
          );
        }
        final String sid = newId?.call() ?? _defaultId();
        await LocalDatabase.instance.insertSearchQueryBlock(
          id: sid,
          term: term,
          match: 'contains',
          scheduleId: scheduleId,
        );
        existingSearchQueries.add(term);
        return SmartRuleApplyResult(
          searchQueriesAdded: 1,
          kind: detected.kind,
          patterns: <String>[term],
        );

      case UnifiedRuleKind.host:
      case UnifiedRuleKind.wildcard:
        final String host = detected.pattern;
        if (host.isEmpty) {
          return const SmartRuleApplyResult(error: '값을 입력하세요.');
        }
        if (host == 'youtube.com' && context.mounted) {
          final bool ok = await showYoutubeHostConfirmDialog(context);
          if (!ok) {
            return const SmartRuleApplyResult(cancelled: true);
          }
        }
        final String? hostErr = ScheduleRuleValidation.validateHost(host);
        if (hostErr != null) {
          return SmartRuleApplyResult(error: hostErr, kind: detected.kind);
        }
        final bool asStem = domainAsStem || detected.numericStemEvasion;
        if (existingDomains.contains(host) ||
            (asStem && existingDomains.contains(host))) {
          return SmartRuleApplyResult(
            duplicates: 1,
            kind: detected.kind,
          );
        }
        final String did = newId?.call() ?? _defaultId();
        await LocalDatabase.instance.insertDomain(
          id: did,
          host: host,
          scheduleId: scheduleId,
          isStem: asStem,
        );
        existingDomains.add(host);

        String? applyNote;
        if (Platform.isWindows || Platform.isMacOS) {
          BlockSyncService.instance.requestApply();
          // Only the browser-extension + registry layer applies automatically
          // within seconds, and only if the extension is already installed
          // and synced. The stronger hosts/firewall layer needs a separate
          // manual UAC apply. A flat "반영됩니다" here is exactly what let
          // first-time users assume adding a site = blocked, no more steps.
          applyNote = '사이트 추가됨 — 브라우저 확장이 설치·동기화돼 있으면 몇 초 안에 자동 '
              '차단됩니다. 확실하지 않으면 설정 → 브라우저 차단 현황에서 확인하세요.';
        }

        return SmartRuleApplyResult(
          domainsAdded: 1,
          kind: detected.kind,
          hostTruncationNote: detected.numericEvasionNote ??
              (detected.normalizedFrom != null
                  ? '경로는 무시하고 「$host」 **사이트 전체**를 차단합니다.'
                  : null),
          apexEnforceMessage: applyNote,
        );
    }
  }

  Future<SmartRuleApplyResult> _applyYouTubeGlobal(
    String line,
    Set<String> existingKeywords,
    String Function()? newId,
  ) async {
    final String normalized = YouTubeScheduleBlockService.normalizeInputLine(line);
    final YouTubeBlocklistBatch batch =
        parseYouTubeBlocklistLines(<String>[normalized]);
    if (batch.rules.isEmpty) {
      return const SmartRuleApplyResult(
        error: '인식할 수 없는 YouTube 주소입니다.',
        kind: UnifiedRuleKind.channelURL,
      );
    }
    int added = 0;
    int skipped = 0;
    final List<String> patterns = <String>[];
    for (final rule in batch.rules) {
      final String? pat = rule.keywordPattern?.trim().toLowerCase();
      if (pat == null || pat.isEmpty) continue;
      if (existingKeywords.contains(pat)) {
        skipped++;
        continue;
      }
      await LocalDatabase.instance.insertKeyword(
        id: newId?.call() ?? _defaultId(),
        pattern: pat,
      );
      existingKeywords.add(pat);
      patterns.add(pat);
      added++;
    }
    return SmartRuleApplyResult(
      keywordsAdded: added,
      skippedDuplicates: skipped,
      kind: UrlRuleDetector.detect(line).kind,
      patterns: patterns,
    );
  }

  static String _defaultId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(Object())}';
}

final class SmartRuleApplyResult {
  const SmartRuleApplyResult({
    this.domainsAdded = 0,
    this.keywordsAdded = 0,
    this.searchQueriesAdded = 0,
    this.duplicates = 0,
    this.skippedDuplicates = 0,
    this.lineIgnored = false,
    this.error,
    this.cancelled = false,
    this.kind,
    this.patterns = const <String>[],
    this.hostTruncationNote,
    this.apexEnforceMessage,
  });

  final int domainsAdded;
  final int keywordsAdded;
  final int searchQueriesAdded;
  final int duplicates;
  final int skippedDuplicates;
  final bool lineIgnored;
  final String? error;
  final bool cancelled;
  final UnifiedRuleKind? kind;
  final List<String> patterns;
  final String? hostTruncationNote;
  final String? apexEnforceMessage;

  bool get wasSkipped => lineIgnored ||
      (domainsAdded == 0 &&
          keywordsAdded == 0 &&
          searchQueriesAdded == 0 &&
          error == null &&
          !cancelled &&
          (duplicates > 0 || skippedDuplicates > 0));

  bool get ok =>
      !cancelled &&
      error == null &&
      (domainsAdded > 0 ||
          keywordsAdded > 0 ||
          searchQueriesAdded > 0);

  String summaryMessage() {
    if (cancelled) return '취소됨';
    if (error != null) return error!;
    final StringBuffer sb = StringBuffer();
    if (domainsAdded > 0) sb.write('사이트 $domainsAdded');
    if (keywordsAdded > 0) {
      if (sb.isNotEmpty) sb.write(' · ');
      sb.write('키워드·채널·영상 $keywordsAdded');
    }
    if (searchQueriesAdded > 0) {
      if (sb.isNotEmpty) sb.write(' · ');
      sb.write('검색어 $searchQueriesAdded');
    }
    if (duplicates > 0) {
      if (sb.isNotEmpty) sb.write(' · ');
      sb.write('중복 $duplicates');
    }
    if (sb.isEmpty) return '추가된 항목 없음';
    return '${sb.toString()}개 추가';
  }
}
