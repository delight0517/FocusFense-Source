import 'package:flutter/material.dart';

import '../models/quick_block_rule_entries.dart';
import '../services/schedule_rule_validation.dart';
import '../services/smart_rule_bundle_apply.dart';
import '../theme/app_colors.dart';
import '../utils/cold_turkey_rule_parser.dart';
import 'bulk_add_domains_dialog.dart';
import 'smart_rule_input_bar.dart';
import 'unified_rule_kind_chip.dart';

/// 퀵 블록 묶음 — 통합 입력으로 사이트(hosts) + 확장 키워드·채널·영상.
class QuickBlockBundleRulesCard extends StatefulWidget {
  const QuickBlockBundleRulesCard({
    super.key,
    required this.domains,
    required this.keywords,
    required this.onDomainsChanged,
    required this.onKeywordsChanged,
  });

  final List<QuickBlockDomainRule> domains;
  final List<QuickBlockKeywordRule> keywords;
  final ValueChanged<List<QuickBlockDomainRule>> onDomainsChanged;
  final ValueChanged<List<QuickBlockKeywordRule>> onKeywordsChanged;

  @override
  State<QuickBlockBundleRulesCard> createState() =>
      _QuickBlockBundleRulesCardState();
}

class _QuickBlockBundleRulesCardState extends State<QuickBlockBundleRulesCard> {
  final TextEditingController _inputCtrl = TextEditingController();
  bool _addAsStem = false;
  String? _warning;

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  Set<String> get _existingHosts =>
      widget.domains.map((QuickBlockDomainRule d) => d.host.toLowerCase()).toSet();

  Set<String> get _existingKeywords => widget.keywords
      .map((QuickBlockKeywordRule k) => k.pattern.toLowerCase())
      .toSet();

  Future<void> _addLine() async {
    final String raw = _inputCtrl.text.trim();
    if (!mounted) return;
    final SmartRuleBundleResult result = await SmartRuleBundleApply.applyLine(
      context: context,
      rawLine: raw,
      existingHosts: Set<String>.from(_existingHosts),
      existingKeywords: Set<String>.from(_existingKeywords),
      domainAsStem: _addAsStem,
    );
    if (!mounted) return;
    if (result.cancelled) return;
    if (result.error != null) {
      setState(() => _warning = result.error);
      return;
    }
    if (!result.ok) {
      if (result.duplicates > 0) {
        setState(() => _warning = '이미 목록에 있어요.');
      }
      return;
    }

    if (result.domain != null) {
      widget.onDomainsChanged(<QuickBlockDomainRule>[
        ...widget.domains,
        result.domain!,
      ]);
    }
    if (result.keywords.isNotEmpty) {
      widget.onKeywordsChanged(<QuickBlockKeywordRule>[
        ...widget.keywords,
        ...result.keywords,
      ]);
    }

    _inputCtrl.clear();
    setState(() => _warning = null);

    if (result.hostTruncationNote != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.hostTruncationNote!)),
      );
    }
  }

  Future<void> _bulkImport() async {
    final BulkAddDomainsResult? result = await showDialog<BulkAddDomainsResult>(
      context: context,
      builder: (_) => const BulkAddDomainsDialog(),
    );
    if (result == null || result.lines.isEmpty) return;

    final Set<String> hosts = Set<String>.from(_existingHosts);
    final Set<String> kws = Set<String>.from(_existingKeywords);
    final List<QuickBlockDomainRule> nextDomains =
        <QuickBlockDomainRule>[...widget.domains];
    final List<QuickBlockKeywordRule> nextKeywords =
        <QuickBlockKeywordRule>[...widget.keywords];
    int added = 0;
    int skipped = 0;
    final List<String> coldFallback = <String>[];

    for (final String line in result.lines) {
      if (!mounted) break;
      final SmartRuleBundleResult smart = await SmartRuleBundleApply.applyLine(
        context: context,
        rawLine: line,
        existingHosts: hosts,
        existingKeywords: kws,
        domainAsStem: result.asStem,
      );
      if (smart.cancelled) break;
      if (smart.domain != null) {
        nextDomains.add(smart.domain!);
        hosts.add(smart.domain!.host);
        added++;
      }
      for (final QuickBlockKeywordRule k in smart.keywords) {
        nextKeywords.add(k);
        kws.add(k.pattern);
        added++;
      }
      if (smart.lineIgnored) continue;
      skipped += smart.duplicates + smart.skippedDuplicates;
      if (!smart.ok && smart.error == null) {
        coldFallback.add(line);
      }
    }

    final ColdTurkeyImportBatch batch = parseColdTurkeyLines(coldFallback);
    for (final ColdTurkeyParsedRule rule in batch.rules) {
      if (rule.kind == ColdTurkeyRuleKind.domain) {
        final String host = rule.domainHost!;
        if (hosts.contains(host)) {
          skipped++;
          continue;
        }
        if (ScheduleRuleValidation.validateHost(host) != null) {
          skipped++;
          continue;
        }
        nextDomains.add(QuickBlockDomainRule(host: host, isStem: result.asStem));
        hosts.add(host);
        added++;
      } else if (rule.keywordPattern != null) {
        final String pat = rule.keywordPattern!;
        if (kws.contains(pat)) {
          skipped++;
          continue;
        }
        nextKeywords.add(QuickBlockKeywordRule(pattern: pat));
        kws.add(pat);
        added++;
      }
    }

    widget.onDomainsChanged(nextDomains);
    widget.onKeywordsChanged(nextKeywords);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('대량 추가: $added개${skipped > 0 ? ' · 건너뜀 $skipped' : ''}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '차단 규칙 (${widget.domains.length} 사이트 · ${widget.keywords.length} 확장)',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'URL / 도메인 / 채널 / 키워드 — 자동 감지. 퀵 블록 ON 시 hosts + 브라우저 확장에 반영됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 10),
            SmartRuleInputBar(
              controller: _inputCtrl,
              onAdd: () {
                if (_warning != null) setState(() => _warning = null);
                _addLine();
              },
            ),
            Row(
              children: <Widget>[
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _bulkImport,
                  icon: const Icon(Icons.playlist_add, size: 16),
                  label: const Text('대량'),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                Switch(
                  value: _addAsStem,
                  onChanged: (bool v) => setState(() => _addAsStem = v),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _addAsStem
                        ? '패턴 모드 — 회전 도메인 (.com/.xyz 변형)'
                        : '패턴 모드 (회전 도메인)',
                    style: theme.textTheme.bodySmall?.copyWith(
                          color: _addAsStem ? AppColors.warning : AppColors.muted,
                        ),
                  ),
                ),
              ],
            ),
            if (_warning != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _warning!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 12),
                ),
              ),
            if (widget.domains.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('사이트 (hosts)', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              ...widget.domains.map(_domainTile),
            ],
            if (widget.keywords.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('확장 (검색·YouTube)', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              ...widget.keywords.map(_keywordTile),
            ],
            if (widget.domains.isEmpty && widget.keywords.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '아직 규칙이 없어요.',
                  style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _domainTile(QuickBlockDomainRule d) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(d.isStem ? Icons.auto_awesome : Icons.language, size: 20),
      title: Row(
        children: <Widget>[
          Expanded(child: Text(d.host)),
          UnifiedRuleKindChip(value: d.host, isDomainRow: true),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => widget.onDomainsChanged(
          widget.domains.where((QuickBlockDomainRule x) => x != d).toList(),
        ),
      ),
    );
  }

  Widget _keywordTile(QuickBlockKeywordRule k) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.tag, size: 20),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(k.pattern, overflow: TextOverflow.ellipsis),
          ),
          UnifiedRuleKindChip(value: k.pattern, isDomainRow: false),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => widget.onKeywordsChanged(
          widget.keywords.where((QuickBlockKeywordRule x) => x != k).toList(),
        ),
      ),
    );
  }
}
