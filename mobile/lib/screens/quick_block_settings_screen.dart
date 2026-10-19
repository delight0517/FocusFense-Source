import 'dart:async';

import 'package:flutter/material.dart';

import '../models/quick_block_user_bundle.dart';
import '../services/quick_block_prefs_store.dart';
import '../services/quick_block_service.dart';
import '../theme/app_colors.dart';
import 'quick_block_bundle_edit_screen.dart';
import 'quick_block_catalog_edit_screen.dart';
import 'usage_limits_screen.dart';

/// Default duration / cancel delay + built-in & user quick-block bundles.
class QuickBlockSettingsScreen extends StatefulWidget {
  const QuickBlockSettingsScreen({super.key});

  @override
  State<QuickBlockSettingsScreen> createState() => _QuickBlockSettingsScreenState();
}

class _QuickBlockSettingsScreenState extends State<QuickBlockSettingsScreen> {
  bool _loading = true;
  List<QuickBlockUserBundle> _bundles = <QuickBlockUserBundle>[];
  List<QuickBlockBundle> _visibleCatalog = <QuickBlockBundle>[];
  List<QuickBlockBundle> _hiddenCatalog = <QuickBlockBundle>[];
  int _durationHours = QuickBlockPrefsStore.kDefaultDurationHours;
  int _cancelDelayMin = QuickBlockPrefsStore.kDefaultCancelDelayMinutes;
  int _savedDurationHours = QuickBlockPrefsStore.kDefaultDurationHours;
  int _savedCancelDelayMin = QuickBlockPrefsStore.kDefaultCancelDelayMinutes;
  Map<String, int> _catalogDomainCounts = <String, int>{};

  bool get _timingDirty =>
      _durationHours != _savedDurationHours || _cancelDelayMin != _savedCancelDelayMin;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final List<QuickBlockUserBundle> b =
        await QuickBlockService.instance.userBundles();
    final Set<String> hidden =
        await QuickBlockPrefsStore.instance.hiddenCatalogIds();
    final List<QuickBlockBundle> visible = <QuickBlockBundle>[];
    final List<QuickBlockBundle> hid = <QuickBlockBundle>[];
    final Map<String, int> counts = <String, int>{};
    for (final QuickBlockBundle cat in QuickBlockCatalog.all) {
      final QuickBlockBundle resolved =
          await QuickBlockService.instance.resolvedCatalogBundle(cat.id);
      counts[cat.id] = resolved.hosts.length;
      if (hidden.contains(cat.id)) {
        hid.add(cat);
      } else {
        visible.add(cat);
      }
    }
    final int h = await QuickBlockPrefsStore.instance.defaultDurationHours();
    final int c = await QuickBlockPrefsStore.instance.defaultCancelDelayMinutes();
    if (mounted) {
      setState(() {
        _bundles = b;
        _visibleCatalog = visible;
        _hiddenCatalog = hid;
        _durationHours = h;
        _cancelDelayMin = c;
        _savedDurationHours = h;
        _savedCancelDelayMin = c;
        _catalogDomainCounts = counts;
        _loading = false;
      });
    }
  }

  Future<void> _saveTiming() async {
    await QuickBlockPrefsStore.instance.setDefaultDurationHours(_durationHours);
    await QuickBlockPrefsStore.instance.setDefaultCancelDelayMinutes(_cancelDelayMin);
    if (!mounted) return;
    setState(() {
      _savedDurationHours = _durationHours;
      _savedCancelDelayMin = _cancelDelayMin;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '차단 $_durationHours시간 · 해제 지연 $_cancelDelayMin분 저장됨. '
          '도크 버튼에 바로 반영됩니다.',
        ),
      ),
    );
  }

  Future<void> _openEditor([QuickBlockUserBundle? bundle]) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => QuickBlockBundleEditScreen(bundle: bundle),
      ),
    );
    if (saved == true) await _reload();
  }

  Future<void> _openCatalogEditor(String catalogId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => QuickBlockCatalogEditScreen(catalogId: catalogId),
      ),
    );
    await _reload();
  }

  Future<void> _deleteUserBundle(QuickBlockUserBundle b) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('「${b.label}」 삭제'),
        content: const Text('이 묶음과 목록이 앱에서 제거됩니다. 이미 켜진 퀵 블록 세션은 별도로 해제하세요.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await QuickBlockService.instance.deleteUserBundle(b.id);
    await _reload();
  }

  Future<void> _deleteCatalogPreset(QuickBlockBundle cat) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('「${cat.label}」 프리셋 삭제'),
        content: Text(
          '도크·목록에서 「${cat.label}」을 제거합니다.\n'
          '사이트 목록은 보관되므로 아래 「삭제된 프리셋 복구」로 다시 켤 수 있습니다.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await QuickBlockService.instance.hideCatalogPreset(cat.id);
    await _reload();
  }

  Future<void> _restoreCatalog(QuickBlockBundle cat) async {
    await QuickBlockService.instance.restoreCatalogPreset(cat.id);
    await _reload();
  }

  Widget _bundleTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
    String? badge,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: AppColors.accent),
        title: Row(
          children: <Widget>[
            Expanded(child: Text(title)),
            if (badge != null)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ),
          ],
        ),
        subtitle: Text(subtitle),
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '편집',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '삭제',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('퀵 블록 설정')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '내 퀵 블록',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => unawaited(_openEditor()),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('추가'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '게임·채팅 / 영상·SNS 프리셋도 여기서 편집·삭제할 수 있습니다. '
                  '삭제하면 도크 버튼에서 사라집니다.',
                  style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
                ),
                const SizedBox(height: 10),
                for (final QuickBlockBundle cat in _visibleCatalog)
                  _bundleTile(
                    title: cat.label,
                    subtitle: '사이트 ${_catalogDomainCounts[cat.id] ?? cat.hosts.length}개',
                    icon: cat.id == QuickBlockCatalog.games.id
                        ? Icons.sports_esports_outlined
                        : Icons.ondemand_video_outlined,
                    badge: '프리셋',
                    onTap: () => unawaited(_openCatalogEditor(cat.id)),
                    onEdit: () => unawaited(_openCatalogEditor(cat.id)),
                    onDelete: () => unawaited(_deleteCatalogPreset(cat)),
                  ),
                ..._bundles.map((QuickBlockUserBundle b) {
                  return _bundleTile(
                    title: b.label,
                    subtitle: '사이트 ${b.domains.length} · 앱 ${b.apps.length}',
                    icon: Icons.bolt_outlined,
                    onTap: () => unawaited(_openEditor(b)),
                    onEdit: () => unawaited(_openEditor(b)),
                    onDelete: () => unawaited(_deleteUserBundle(b)),
                  );
                }),
                if (_visibleCatalog.isEmpty && _bundles.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '프리셋을 복구하거나 「추가」로 묶음을 만드세요.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.muted),
                      ),
                    ),
                  ),
                if (_hiddenCatalog.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    '삭제된 프리셋 복구',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  for (final QuickBlockBundle cat in _hiddenCatalog)
                    ListTile(
                      leading: const Icon(Icons.restore_outlined),
                      title: Text(cat.label),
                      trailing: FilledButton.tonal(
                        onPressed: () => unawaited(_restoreCatalog(cat)),
                        child: const Text('복구'),
                      ),
                    ),
                ],
                const Divider(height: 32),
                ListTile(
                  leading: const Icon(Icons.timer_outlined, color: AppColors.accent),
                  title: const Text('앱·사이트 이용 시간 제한'),
                  subtitle: const Text('하루 총량 · 1시간마다 N분 · 세션 주기'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const UsageLimitsScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 32),
                Text(
                  '차단 시간 · 해제 지연',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  '슬라이더를 움직인 뒤 「차단 시간 바꾸고 저장!」을 누르세요.',
                  style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('차단 시간: $_durationHours시간'),
                  subtitle: Slider(
                    value: _durationHours.toDouble(),
                    min: 1,
                    max: QuickBlockPrefsStore.maxDurationHours.toDouble(),
                    divisions: QuickBlockPrefsStore.maxDurationHours - 1,
                    label: '$_durationHours시간',
                    onChanged: (double v) {
                      setState(() => _durationHours = v.round());
                    },
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('해제 지연: $_cancelDelayMin분'),
                  subtitle: Slider(
                    value: _cancelDelayMin.toDouble(),
                    min: 0,
                    max: QuickBlockPrefsStore.maxCancelDelayMinutes.toDouble(),
                    divisions: 24,
                    label: '$_cancelDelayMin분',
                    onChanged: (double v) {
                      setState(() => _cancelDelayMin = v.round());
                    },
                  ),
                ),
                FilledButton.icon(
                  onPressed: !_timingDirty ? null : _saveTiming,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('차단 시간 바꾸고 저장!'),
                ),
                if (_timingDirty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '저장하지 않으면 도크에는 이전 값($_savedDurationHours시간)이 표시됩니다.',
                      style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning),
                    ),
                  ),
              ],
            ),
    );
  }
}
