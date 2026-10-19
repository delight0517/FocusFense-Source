import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/daily_awareness_service.dart';
import '../theme/app_colors.dart';

/// The "지금 무엇이 차단 중" popup shown when the user clicks a branded block
/// notice (Windows toast). It renders — right in front of the user — exactly
/// which block/schedule fired the notice they just clicked.
///
/// [payload] is the JSON the toast wrote to `toast_click.signal.json`:
///   { title, body, detail?: { kind, target, source, schedules[], endsAt,
///     tags[], reason }, clickedAt }
class ActiveBlockDetailDialog extends StatelessWidget {
  const ActiveBlockDetailDialog({super.key, required this.payload});

  final Map<String, Object?> payload;

  static Future<void> show(
    BuildContext context,
    Map<String, Object?> payload,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext _) => ActiveBlockDetailDialog(payload: payload),
    );
  }

  Map<String, Object?> get _detail {
    final Object? d = payload['detail'];
    return d is Map ? d.cast<String, Object?>() : const <String, Object?>{};
  }

  String get _title => (payload['title'] as String?)?.trim().isNotEmpty == true
      ? payload['title'] as String
      : '지금 차단 중';

  String get _body => (payload['body'] as String?) ?? '';

  List<String> _stringList(Object? v) => v is List
      ? v.map((Object? e) => '$e').where((String s) => s.isNotEmpty).toList()
      : const <String>[];

  String? _formatEndsAt(Object? iso) {
    if (iso is! String || iso.isEmpty) return null;
    final DateTime? t = DateTime.tryParse(iso);
    if (t == null) return null;
    final DateTime local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, Object?> detail = _detail;
    final List<String> schedules = _stringList(detail['schedules']);
    final List<String> tags = _stringList(detail['tags']);
    final String? endsAt = _formatEndsAt(detail['endsAt']);
    final String? target = detail['target'] as String?;
    final String? reason = detail['reason'] as String?;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.shield_moon_outlined,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '● FOCUS FENSE · 지금 차단 중',
                      style: TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '닫기',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: AppColors.ink,
                ),
              ),
              if (_body.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  _body,
                  style: const TextStyle(fontSize: 14, color: AppColors.muted),
                ),
              ],
              const SizedBox(height: 14),
              _InfoBlock(
                rows: <_InfoRow>[
                  if (target != null && target.isNotEmpty)
                    _InfoRow(icon: Icons.apps, label: '대상', value: target),
                  if (schedules.isNotEmpty)
                    _InfoRow(
                      icon: Icons.event_available,
                      label: '스케줄',
                      value: schedules.join('\n'),
                    ),
                  if (endsAt != null)
                    _InfoRow(
                      icon: Icons.timer_outlined,
                      label: '해제 예정',
                      value: '$endsAt 까지',
                    ),
                  if (tags.isNotEmpty)
                    _InfoRow(
                      icon: Icons.sell_outlined,
                      label: '차단 경로',
                      value: tags.join(' · '),
                    ),
                  if (reason != null &&
                      reason.isNotEmpty &&
                      reason != _body)
                    _InfoRow(
                      icon: Icons.info_outline,
                      label: '원인',
                      value: reason,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _AwarenessCard(),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('확인'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('스케줄 설정 열기'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      // Scroll straight to the exact schedule card when we
                      // know which one fired this notice — otherwise just
                      // open the list.
                      context.goNamed(
                        'schedules',
                        queryParameters: schedules.isNotEmpty
                            ? <String, String>{'highlight': schedules.first}
                            : const <String, String>{},
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AwarenessCard extends StatelessWidget {
  _AwarenessCard();

  final DailyAwarenessService _service = DailyAwarenessService.instance;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _service.drugHeadline,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: AppColors.danger,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '오늘의 이야기 · ${_service.todayMessage()}',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.muted,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;
}

class _InfoBlock extends StatelessWidget {
  const _InfoBlock({required this.rows});
  final List<_InfoRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < rows.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(rows[i].icon, size: 16, color: AppColors.accent),
                const SizedBox(width: 10),
                SizedBox(
                  width: 62,
                  child: Text(
                    rows[i].label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.muted,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    rows[i].value,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
