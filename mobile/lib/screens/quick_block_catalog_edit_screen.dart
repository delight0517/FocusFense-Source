import 'dart:async';

import 'package:flutter/material.dart';

import '../models/quick_block_rule_entries.dart';
import '../services/quick_block_controller.dart';
import '../services/quick_block_prefs_store.dart';
import '../services/quick_block_service.dart';
import '../theme/app_colors.dart';
import '../widgets/schedule_domains_rules_card.dart';

/// Edit built-in 「게임·채팅」 / 「영상·SNS」 site lists.
class QuickBlockCatalogEditScreen extends StatefulWidget {
  const QuickBlockCatalogEditScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  State<QuickBlockCatalogEditScreen> createState() =>
      _QuickBlockCatalogEditScreenState();
}

class _QuickBlockCatalogEditScreenState extends State<QuickBlockCatalogEditScreen> {
  List<QuickBlockDomainRule> _domains = <QuickBlockDomainRule>[];
  String _label = '';
  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final QuickBlockBundle base =
        await QuickBlockService.instance.resolvedCatalogBundle(widget.catalogId);
    final QuickBlockBundle? stock = QuickBlockCatalog.byId(widget.catalogId);
    _label = base.label;
    final List<QuickBlockDomainRule>? custom =
        await QuickBlockPrefsStore.instance.catalogDomains(widget.catalogId);
    if (custom != null && custom.isNotEmpty) {
      _domains = List<QuickBlockDomainRule>.from(custom);
    } else {
      _domains = (stock ?? base).hosts
          .map((String h) => QuickBlockDomainRule(host: h))
          .toList();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await QuickBlockPrefsStore.instance.saveCatalogDomains(
        widget.catalogId,
        _domains,
      );
      QuickBlockController.instance.bump();
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '프리셋 사이트 목록을 저장했습니다. '
            '시스템 반영은 왼쪽 아래 「적용」을 누르세요.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetToDefault() async {
    await QuickBlockPrefsStore.instance.resetCatalogDomains(widget.catalogId);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('기본 목록으로 되돌렸습니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('$_label 편집'),
        actions: <Widget>[
          TextButton(
            onPressed: _saving ? null : () => unawaited(_resetToDefault()),
            child: const Text('기본값'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            '도크의 「$_label」 버튼에 들어가는 사이트입니다. '
            '스케줄 편집과 같은 UI로 추가·삭제할 수 있습니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 16),
          ScheduleDomainsRulesCard(
            domains: _domains,
            onChanged: (List<QuickBlockDomainRule> next) {
              setState(() {
                _domains = next;
                _dirty = true;
              });
            },
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: !_dirty || _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('사이트 목록 저장'),
          ),
        ],
      ),
    );
  }
}

