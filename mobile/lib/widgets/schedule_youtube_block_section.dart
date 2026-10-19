import 'package:flutter/material.dart';

import '../services/youtube_schedule_block_service.dart';
import '../theme/app_colors.dart';
import '../screens/browser_extensions_screen.dart';

/// YouTube channel / video URL entry inside [ScheduleEditScreen].
class ScheduleYouTubeBlockSection extends StatefulWidget {
  const ScheduleYouTubeBlockSection({
    super.key,
    required this.scheduleId,
    required this.isNewSchedule,
    required this.onBeforeSave,
    required this.onAdded,
    this.lockedAddOnly = false,
  });

  final String scheduleId;
  final bool isNewSchedule;
  final Future<void> Function() onBeforeSave;
  final VoidCallback onAdded;
  final bool lockedAddOnly;

  @override
  State<ScheduleYouTubeBlockSection> createState() =>
      _ScheduleYouTubeBlockSectionState();
}

class _ScheduleYouTubeBlockSectionState extends State<ScheduleYouTubeBlockSection> {
  final TextEditingController _ctrl = TextEditingController();
  bool _busy = false;
  bool _expandedHelp = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final String raw = _ctrl.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('채널 URL 또는 @핸들을 입력하세요')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      if (widget.isNewSchedule) {
        await widget.onBeforeSave();
      }
      if (!mounted) return;
      final YouTubeScheduleAddResult r =
          await YouTubeScheduleBlockService.instance.addToSchedule(
        scheduleId: widget.scheduleId,
        urlOrHandle: raw,
      );
      if (!mounted) return;
      if (r.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r.error!)),
        );
        return;
      }
      if (r.added == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이미 이 스케줄에 같은 패턴이 있습니다')),
        );
        return;
      }
      _ctrl.clear();
      widget.onAdded();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'YouTube 키워드 ${r.added}개 추가됨'
            '${r.skipped > 0 ? " (중복 ${r.skipped})" : ""}\n'
            '채널 영상 watch?v= 자동 페치·동기화 중…',
          ),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: '확장',
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const BrowserExtensionsScreen(),
                ),
              );
            },
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      color: AppColors.accent.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.ondemand_video, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'YouTube 채널 · 영상 (이 스케줄)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _expandedHelp ? '안내 접기' : '안내 펼치기',
                  onPressed: () =>
                      setState(() => _expandedHelp = !_expandedHelp),
                  icon: Icon(
                    _expandedHelp ? Icons.expand_less : Icons.expand_more,
                  ),
                ),
              ],
            ),
            if (_expandedHelp) ...<Widget>[
              _infoBox(
                theme,
                icon: Icons.check_circle_outline,
                color: AppColors.success,
                title: '이렇게 하면 막힙니다',
                lines: const <String>[
                  'Chrome/Edge에서 해당 채널 홈·영상 카드 숨김',
                  '주소창에 youtube.com/@채널 직접 입력 시 차단 화면',
                  'Google 검색 결과에 뜨는 해당 채널 링크 숨김',
                ],
              ),
              const SizedBox(height: 8),
              _infoBox(
                theme,
                icon: Icons.cancel_outlined,
                color: AppColors.warning,
                title: '이 방법만으로는 안 됩니다',
                lines: const <String>[
                  '「사이트 추가」에 youtube.com만 넣기 → 유튜브 전체 DNS 차단 (채널만 X)',
                  '「지금 적용」UAC만 → hosts용, @채널 차단과 별개',
                  'YouTube 데스크톱 앱 · 확장 미설치',
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '① 아래에 채널/영상 URL 붙여넣기 → ② 스케줄 켜기 → '
                '③ 브라우저 확장 설치·규칙 동기화 → ④ youtube.com 새로고침',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _ctrl,
              autocorrect: false,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: '채널 또는 영상 URL',
                hintText: 'https://www.youtube.com/@SC2HL',
                helperText: '@SC2HL 만 입력해도 됩니다',
                suffixIcon: _busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
              onSubmitted: (_) => _add(),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('이 스케줄에 추가'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => const BrowserExtensionsScreen(),
                            ),
                          );
                        },
                  child: const Text('확장 동기화'),
                ),
              ],
            ),
            if (widget.lockedAddOnly)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '잠금 중 — 추가만 가능, 아래 키워드 목록에서 확인하세요.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _infoBox(
    ThemeData theme, {
    required IconData icon,
    required Color color,
    required String title,
    required List<String> lines,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(title, style: theme.textTheme.labelLarge?.copyWith(color: color)),
            ],
          ),
          const SizedBox(height: 6),
          for (final String line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '• $line',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
              ),
            ),
        ],
      ),
    );
  }
}
