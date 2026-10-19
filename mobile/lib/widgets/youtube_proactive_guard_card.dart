import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/browser_block_experiment_service.dart';
import '../services/youtube_proactive_guard_service.dart';
import '../theme/app_colors.dart';

/// YouTube 선제 감지 + Chrome/Firefox 실험 결과 (진단 화면).
class YoutubeProactiveGuardCard extends StatefulWidget {
  const YoutubeProactiveGuardCard({super.key});

  @override
  State<YoutubeProactiveGuardCard> createState() =>
      _YoutubeProactiveGuardCardState();
}

class _YoutubeProactiveGuardCardState extends State<YoutubeProactiveGuardCard> {
  bool _running = false;

  @override
  void initState() {
    super.initState();
    YoutubeProactiveGuardService.instance.latest.addListener(_onUpdate);
  }

  @override
  void dispose() {
    YoutubeProactiveGuardService.instance.latest.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _runNow() async {
    setState(() => _running = true);
    await YoutubeProactiveGuardService.instance.runCycle(
      reason: 'user',
      runExperiments: true,
      userInitiated: true,
    );
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return const SizedBox.shrink();
    }
    final YoutubeProactiveGuardReport? rep =
        YoutubeProactiveGuardService.instance.latest.value;
    final bool ok = rep?.ok ?? false;
    final Color tone = ok ? AppColors.success : AppColors.warning;
    final String verdict = rep?.verdict ?? '앱 시작 후 25초 뒤 자동 점검';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.play_circle_outline, color: tone, size: 22),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'YouTube 선제 점검 (규칙 읽기 + Chrome/Firefox 실험)',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                ),
                if (_running)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(
                    onPressed: _runNow,
                    child: const Text('지금 실험'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(verdict, style: TextStyle(color: tone, fontSize: 13)),
            if (rep != null) ...<Widget>[
              const SizedBox(height: 8),
              ...rep.ruleChecks
                  .where((YoutubeRuleCheck c) => c.shouldBlock)
                  .take(4)
                  .map(
                    (YoutubeRuleCheck c) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• ${c.videoId} → 규칙: ${c.rule ?? c.channelHandle ?? "?"}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
              if (rep.experiments.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                ...rep.experiments.take(4).map(
                      (BrowserBlockExperimentResult e) => Text(
                        '${e.ok ? "✓" : "✗"} ${e.browser}: ${e.detail}',
                        style: TextStyle(
                          fontSize: 11,
                          color: e.ok ? AppColors.muted : AppColors.warning,
                        ),
                      ),
                    ),
              ],
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(
                    text: YoutubeProactiveGuardService.instance.reportPath,
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('로그 경로 복사됨 (Cursor용)')),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Cursor용 로그 경로 복사', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
