import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/crash_journal_service.dart';
import '../services/notification_history_log_service.dart';
import '../theme/app_colors.dart';
import 'copyable_snackbar.dart';

/// "알림창(토스트) 기록" — every notice-worthy decision this app made for the
/// last 7 days: **shown** (a toast actually popped up) or **suppressed**
/// (would have but a cooldown / silent-bootstrap window blocked it). Answers
/// "왜 안 떴지?" / "왜 자꾸 뜨지?" from data instead of guesswork.
class NotificationHistoryPanel extends StatefulWidget {
  const NotificationHistoryPanel({super.key, this.maxHeight = 260});

  final double maxHeight;

  @override
  State<NotificationHistoryPanel> createState() =>
      _NotificationHistoryPanelState();
}

class _NotificationHistoryPanelState extends State<NotificationHistoryPanel> {
  List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  bool _loading = true;
  bool _onlyShown = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final List<Map<String, Object?>> entries =
        await NotificationHistoryLogService.instance.recentEntries();
    if (!mounted) return;
    setState(() {
      _entries = entries.reversed.toList();
      _loading = false;
    });
  }

  Future<void> _copy() async {
    final String folder = CrashJournalService.instance.debugFolderPath;
    final Map<String, Object?> bundle = <String, Object?>{
      'kind': 'notification_history_backup',
      'retentionDays': NotificationHistoryLogService.kRetention.inDays,
      'entryCount': _entries.length,
      'jsonl': NotificationHistoryLogService.instance.jsonlPath,
      'entries': _entries.reversed.toList(),
    };
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(bundle)),
    );
    if (!mounted) return;
    showCopyableSnackBar(
      context,
      '알림 기록 복사됨 (최근 ${NotificationHistoryLogService.kRetention.inDays}일, '
      '$folder)',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Map<String, Object?>> visible = _onlyShown
        ? _entries.where((Map<String, Object?> e) => e['shown'] == true).toList()
        : _entries;
    final int shownCount =
        _entries.where((Map<String, Object?> e) => e['shown'] == true).length;
    final int suppressedCount = _entries.length - shownCount;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.notifications_active_outlined,
                    size: 20, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '알림창 기록 (최근 7일)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '떴음 $shownCount건 · 안 뜸(쿨다운/부트스트랩) $suppressedCount건 — '
              '실제로 앱을 강제 종료할 때만 「떴음」이 기록됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.35,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                FilterChip(
                  label: const Text('전체'),
                  selected: !_onlyShown,
                  onSelected: (_) => setState(() => _onlyShown = false),
                ),
                const SizedBox(width: 6),
                FilterChip(
                  label: const Text('떴음만'),
                  selected: _onlyShown,
                  onSelected: (_) => setState(() => _onlyShown = true),
                ),
              ],
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
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          '아직 기록 없음',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppColors.muted,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: visible.length,
                        itemBuilder: (BuildContext context, int i) {
                          final Map<String, Object?> e = visible[i];
                          final bool shown = e['shown'] == true;
                          final String ts = '${e['ts'] ?? ''}';
                          final String tsShort = ts.length >= 19
                              ? ts.substring(0, 19).replaceFirst('T', ' ')
                              : ts;
                          final String target = '${e['target'] ?? ''}';
                          final String kind = '${e['kind'] ?? ''}';
                          final String reason = '${e['reason'] ?? ''}';
                          final String? suppressReason =
                              e['suppressReason'] as String?;
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: Icon(
                              shown
                                  ? Icons.notifications
                                  : Icons.notifications_off_outlined,
                              size: 18,
                              color: shown ? AppColors.success : AppColors.muted,
                            ),
                            title: Text(
                              '$tsShort · $target ($kind)',
                              style: const TextStyle(fontSize: 12),
                            ),
                            subtitle: Text(
                              shown
                                  ? reason
                                  : '$reason — 안 뜸 (${suppressReason ?? "알수없음"})',
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
                  onPressed: _copy,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('복사'),
                ),
                OutlinedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('새로고침'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
