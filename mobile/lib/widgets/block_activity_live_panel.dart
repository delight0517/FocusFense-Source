import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/block_activity_log_service.dart';
import '../services/crash_journal_service.dart';
import '../theme/app_colors.dart';
import 'copyable_snackbar.dart';

/// Real-time block rules, browser hits, auto-save — for user + Cursor debugging.
class BlockActivityLivePanel extends StatefulWidget {
  const BlockActivityLivePanel({super.key, this.maxHeight = 280});

  final double maxHeight;

  @override
  State<BlockActivityLivePanel> createState() => _BlockActivityLivePanelState();
}

class _BlockActivityLivePanelState extends State<BlockActivityLivePanel> {
  BlockActivityKind? _filter;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    BlockActivityLogService.instance.revision.addListener(_onRev);
    unawaited(BlockActivityLogService.instance.start());
  }

  @override
  void dispose() {
    BlockActivityLogService.instance.revision.removeListener(_onRev);
    super.dispose();
  }

  void _onRev() {
    if (mounted) setState(() {});
  }

  List<BlockActivityEvent> get _visible {
    final List<BlockActivityEvent> all =
        BlockActivityLogService.instance.events;
    if (_filter == null) return all;
    return all.where((BlockActivityEvent e) => e.kind == _filter).toList();
  }

  Future<void> _copyForCursor() async {
    setState(() => _busy = true);
    final String text =
        await BlockActivityLogService.instance.exportForCursor();
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      setState(() => _busy = false);
      showCopyableSnackBar(context, 'Cursor용 차단 로그를 복사했습니다.');
    }
  }

  Future<void> _refreshSnapshot() async {
    setState(() => _busy = true);
    await BlockActivityLogService.instance.refreshSnapshot(reason: 'user');
    if (mounted) setState(() => _busy = false);
  }

  Color _tone(BlockActivityEvent e) {
    if (e.kind == BlockActivityKind.blockHit) return AppColors.success;
    if (e.level == 'warn') return AppColors.warning;
    if (e.kind == BlockActivityKind.autoSave) return AppColors.accent;
    return AppColors.muted;
  }

  IconData _icon(BlockActivityKind k) {
    switch (k) {
      case BlockActivityKind.blockHit:
        return Icons.block;
      case BlockActivityKind.browserVisit:
        return Icons.language;
      case BlockActivityKind.rulesFetch:
        return Icons.sync;
      case BlockActivityKind.hostsApply:
        return Icons.dns;
      case BlockActivityKind.autoSave:
        return Icons.cloud_done;
      case BlockActivityKind.snapshot:
        return Icons.analytics_outlined;
      case BlockActivityKind.protection:
        return Icons.shield;
      case BlockActivityKind.boot:
        return Icons.play_circle_outline;
      case BlockActivityKind.selfHeal:
        return Icons.healing;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String folder = CrashJournalService.instance.debugFolderPath;
    final List<BlockActivityEvent> items = _visible;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.radar, size: 20, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '실시간 차단 · 활동',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '지금 적용 중인 규칙, 브라우저 차단, 자동 저장 상태입니다. '
              'Cursor는 `$folder\\block_activity_summary.json` 을 읽으면 됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.35,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  FilterChip(
                    label: const Text('전체'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('차단'),
                    selected: _filter == BlockActivityKind.blockHit,
                    onSelected: (_) => setState(
                      () => _filter = BlockActivityKind.blockHit,
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('규칙'),
                    selected: _filter == BlockActivityKind.snapshot,
                    onSelected: (_) => setState(
                      () => _filter = BlockActivityKind.snapshot,
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('저장'),
                    selected: _filter == BlockActivityKind.autoSave,
                    onSelected: (_) => setState(
                      () => _filter = BlockActivityKind.autoSave,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: widget.maxHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? const Color(0xFF141820)
                      : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.black12),
                ),
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          '아직 이벤트 없음 — Chrome(6 VPN)에서 사이트를 열거나\n'
                          '「스냅샷 갱신」을 누르세요.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppColors.muted,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: items.length,
                        itemBuilder: (BuildContext context, int i) {
                          final BlockActivityEvent e = items[i];
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: Icon(_icon(e.kind), size: 18, color: _tone(e)),
                            title: Text(
                              e.message,
                              style: const TextStyle(fontSize: 12),
                            ),
                            subtitle: Text(
                              e.displayLine.split('|').first,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: AppColors.muted,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _busy ? null : _copyForCursor,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Cursor용 복사'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refreshSnapshot,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('스냅샷 갱신'),
                ),
                if (Platform.isWindows || Platform.isMacOS)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: folder),
                      );
                      if (context.mounted) {
                        showCopyableSnackBar(context, '로그 폴더 경로 복사됨');
                      }
                    },
                    icon: const Icon(Icons.folder_copy_outlined, size: 16),
                    label: const Text('폴더 경로'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
