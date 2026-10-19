import 'package:flutter/material.dart';

import '../services/youtube_block_attribution_service.dart';
import '../theme/app_colors.dart';

/// Shows which rules/layers block YouTube apex (built-in vs user-added).
class YoutubeBlockSourcesCard extends StatefulWidget {
  const YoutubeBlockSourcesCard({super.key});

  @override
  State<YoutubeBlockSourcesCard> createState() =>
      _YoutubeBlockSourcesCardState();
}

class _YoutubeBlockSourcesCardState extends State<YoutubeBlockSourcesCard> {
  List<YoutubeBlockSource>? _sources;
  String? _summary;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final List<YoutubeBlockSource> all =
        await YoutubeBlockAttributionService.explain();
    final String summary = await YoutubeBlockAttributionService.summaryLine();
    if (!mounted) return;
    setState(() {
      _sources = all;
      _summary = summary;
      _loading = false;
    });
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
                const Icon(Icons.ondemand_video, color: AppColors.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'youtube.com 을 막는 규칙',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: '새로고침',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            if (_summary != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.danger.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  _summary!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            Text(
              'https://www.youtube.com/ 은 스케줄과 무관하게 '
              'builtin_block_domains + URLBlocklist + PAC + 확장에 항상 포함됩니다. '
              '확장 「삭제」는 force_installed 정책으로 막히며, 90초마다 자동 복구됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const LinearProgressIndicator(minHeight: 2)
            else if (_sources == null || _sources!.isEmpty)
              Text(
                '활성 YouTube apex 차단 없음',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.muted,
                ),
              )
            else
              ..._sources!.map(
                (YoutubeBlockSource s) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        s.removable ? Icons.person_outline : Icons.lock_outline,
                        size: 18,
                        color: s.removable ? AppColors.warning : AppColors.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              s.title,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              s.detail,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.muted,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
