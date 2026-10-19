import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../models/quick_block_rule_entries.dart';
import '../services/schedule_rule_validation.dart';
import '../theme/app_colors.dart';
import '../models/unified_rule_kind.dart';
import '../services/smart_rule_memory_apply.dart';
import '../utils/cold_turkey_rule_parser.dart';
import 'bulk_add_domains_dialog.dart';
import 'smart_rule_input_bar.dart';
import 'unified_rule_kind_chip.dart';

/// In-memory domain list editor — same UX as schedule edit「차단할 사이트」.
class ScheduleDomainsRulesCard extends StatefulWidget {
  const ScheduleDomainsRulesCard({
    super.key,
    required this.domains,
    required this.onChanged,
    this.subtitle,
  });

  final List<QuickBlockDomainRule> domains;
  final ValueChanged<List<QuickBlockDomainRule>> onChanged;
  final String? subtitle;

  @override
  State<ScheduleDomainsRulesCard> createState() => _ScheduleDomainsRulesCardState();
}

class _ScheduleDomainsRulesCardState extends State<ScheduleDomainsRulesCard> {
  final TextEditingController _domainCtrl = TextEditingController();
  bool _addAsStem = false;
  String? _domainWarning;

  @override
  void dispose() {
    _domainCtrl.dispose();
    super.dispose();
  }

  void _emit(List<QuickBlockDomainRule> next) => widget.onChanged(next);

  Set<String> get _existingHosts =>
      widget.domains.map((QuickBlockDomainRule d) => d.host.toLowerCase()).toSet();

  Future<void> _addDomain() async {
    final String raw = _domainCtrl.text.trim();
    if (!mounted) return;
    final SmartRuleMemoryResult result = await SmartRuleMemoryApply.applyLine(
      context: context,
      rawLine: raw,
      existingHosts: _existingHosts,
      domainAsStem: _addAsStem,
    );
    if (!mounted) return;
    if (result.cancelled) return;
    if (result.error != null) {
      setState(() => _domainWarning = result.error);
      return;
    }
    if (result.domain == null) {
      if (result.duplicates > 0) {
        setState(() => _domainWarning = '이미 목록에 있어요.');
      }
      return;
    }
    final List<QuickBlockDomainRule> next = <QuickBlockDomainRule>[
      ...widget.domains,
      result.domain!,
    ];
    _domainCtrl.clear();
    _emit(next);
    setState(() => _domainWarning = null);
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

    final Set<String> existing = _existingHosts;
    final List<QuickBlockDomainRule> next = <QuickBlockDomainRule>[...widget.domains];
    int added = 0;
    int skipped = 0;
    final List<String> coldFallback = <String>[];

    for (final String line in result.lines) {
      if (!mounted) break;
      final SmartRuleMemoryResult smart = await SmartRuleMemoryApply.applyLine(
        context: context,
        rawLine: line,
        existingHosts: existing,
        domainAsStem: result.asStem,
      );
      if (smart.cancelled) break;
      if (smart.domain != null) {
        next.add(smart.domain!);
        existing.add(smart.domain!.host);
        added++;
      } else if (smart.lineIgnored) {
        continue;
      } else if (smart.duplicates > 0) {
        skipped++;
      } else if (smart.error != null &&
          (smart.kind == UnifiedRuleKind.keyword ||
              smart.kind == UnifiedRuleKind.channelURL ||
              smart.kind == UnifiedRuleKind.videoURL)) {
        skipped++;
      } else {
        coldFallback.add(line);
      }
    }

    final ColdTurkeyImportBatch batch = parseColdTurkeyLines(coldFallback);
    for (final ColdTurkeyParsedRule rule in batch.rules) {
      if (rule.kind != ColdTurkeyRuleKind.domain) continue;
      final String host = rule.domainHost!;
      if (existing.contains(host)) {
        skipped++;
        continue;
      }
      if (ScheduleRuleValidation.validateHost(host) != null) {
        skipped++;
        continue;
      }
      next.add(QuickBlockDomainRule(host: host, isStem: result.asStem));
      existing.add(host);
      added++;
    }
    _emit(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('대량 추가: $added개${skipped > 0 ? ' · 건너뜀 $skipped' : ''}')),
    );
  }

  void _remove(QuickBlockDomainRule d) {
    _emit(widget.domains.where((QuickBlockDomainRule x) => x != d).toList());
  }

  void _showBlockingHelp() {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('사이트를 추가하면 어떻게 되나요?'),
        content: SingleChildScrollView(
          child: Text(
            Platform.isWindows
                ? '스케줄과 같이 hosts·DNS·브라우저 확장으로 막습니다. '
                    '구글 검색 자체는 되고, 해당 사이트로 가는 링크만 막힙니다.'
                : '스케줄과 같이 /etc/hosts 로 막습니다.',
            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(height: 1.4),
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('이해했습니다'),
          ),
        ],
      ),
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
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '차단할 사이트 (${widget.domains.length})',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.help_outline, size: 18),
                  tooltip: '차단 방식 설명',
                  onPressed: _showBlockingHelp,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.subtitle ??
                  'URL / 도메인 (자동 감지). 채널·키워드는 퀵 블록 통합 카드·규칙·스케줄에서 추가하세요.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
            ),
            const SizedBox(height: 10),
            SmartRuleInputBar(
              controller: _domainCtrl,
              hintText: _addAsStem
                  ? '예: porn (회전 도메인 패턴)'
                  : 'example.com · youtube.com',
              onAdd: () {
                if (_domainWarning != null) {
                  setState(() => _domainWarning = null);
                }
                _addDomain();
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
            const SizedBox(height: 4),
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
                        ? '패턴 모드 — .com/.net/.xyz 등 TLD + 숫자 변형으로 확장 (회전 도메인)'
                        : '패턴 모드 (회전 도메인 차단용)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _addAsStem ? AppColors.warning : AppColors.muted,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            if (_domainWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _domainWarning!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
            if (widget.domains.isEmpty)
              Text(
                '아직 추가된 사이트가 없어요.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
              )
            else
              ...widget.domains.map((QuickBlockDomainRule d) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    d.isStem ? Icons.auto_awesome : Icons.language,
                    size: 20,
                  ),
                  title: Row(
                    children: <Widget>[
                      Expanded(child: Text(d.host)),
                      UnifiedRuleKindChip(value: d.host, isDomainRow: true),
                    ],
                  ),
                  subtitle: d.isStem
                      ? const Text('패턴 모드', style: TextStyle(fontSize: 11))
                      : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _remove(d),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
