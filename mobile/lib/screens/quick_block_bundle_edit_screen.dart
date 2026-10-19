import 'package:flutter/material.dart';

import '../models/quick_block_rule_entries.dart';
import '../models/quick_block_user_bundle.dart';
import '../services/quick_block_service.dart';
import '../theme/app_colors.dart';
import '../widgets/schedule_apps_rules_card.dart';
import '../widgets/quick_block_bundle_rules_card.dart';

/// Edit one user quick-block bundle — schedule-style site + app editors.
class QuickBlockBundleEditScreen extends StatefulWidget {
  const QuickBlockBundleEditScreen({super.key, this.bundle});

  /// `null` = new bundle.
  final QuickBlockUserBundle? bundle;

  @override
  State<QuickBlockBundleEditScreen> createState() =>
      _QuickBlockBundleEditScreenState();
}

class _QuickBlockBundleEditScreenState extends State<QuickBlockBundleEditScreen> {
  late final TextEditingController _labelCtrl;
  late List<QuickBlockDomainRule> _domains;
  late List<QuickBlockKeywordRule> _keywords;
  late List<QuickBlockAppRule> _apps;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.bundle?.label ?? '내 퀵 블록');
    _domains = List<QuickBlockDomainRule>.from(widget.bundle?.domains ?? <QuickBlockDomainRule>[]);
    _keywords = List<QuickBlockKeywordRule>.from(widget.bundle?.keywords ?? <QuickBlockKeywordRule>[]);
    _apps = List<QuickBlockAppRule>.from(widget.bundle?.apps ?? <QuickBlockAppRule>[]);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final String label = _labelCtrl.text.trim();
    if (label.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이름을 입력하세요.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final QuickBlockUserBundle bundle = QuickBlockUserBundle(
        id: widget.bundle?.id ?? QuickBlockService.newUserBundleId(),
        label: label,
        domains: _domains,
        keywords: _keywords,
        apps: _apps,
        enabled: widget.bundle?.enabled ?? true,
      );
      await QuickBlockService.instance.saveUserBundle(bundle);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('저장됨. 시스템 반영은 왼쪽 아래 「적용」 버튼을 누르세요.'),
          duration: Duration(seconds: 3),
        ),
      );
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isNew = widget.bundle == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? '퀵 블록 추가' : '퀵 블록 편집'),
        actions: <Widget>[
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('저장'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(
            controller: _labelCtrl,
            decoration: const InputDecoration(
              labelText: '퀵 블록 이름',
              hintText: '예: 집중 모드',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '스케줄 편집 화면과 같은 방식으로 사이트·앱을 추가합니다. '
            '도크에서 켜면 설정한 시간 동안 전역 차단됩니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 16),
          QuickBlockBundleRulesCard(
            domains: _domains,
            keywords: _keywords,
            onDomainsChanged: (List<QuickBlockDomainRule> next) {
              setState(() => _domains = next);
            },
            onKeywordsChanged: (List<QuickBlockKeywordRule> next) {
              setState(() => _keywords = next);
            },
          ),
          const SizedBox(height: 12),
          ScheduleAppsRulesCard(
            apps: _apps,
            onChanged: (List<QuickBlockAppRule> next) {
              setState(() => _apps = next);
            },
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('저장'),
          ),
        ],
      ),
    );
  }
}
