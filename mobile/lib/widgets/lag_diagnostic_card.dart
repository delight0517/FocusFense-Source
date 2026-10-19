import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../services/app_lag_detector_service.dart';
import '../services/cpu_spike_detector_service.dart';
import '../services/lag_diagnostic_bundle_service.dart';
import '../services/severe_lag_session_service.dart';

/// 진단 탭 — CPU 스파이크·UI 렉·프리즈를 한곳에서 보고
/// Cursor/Claude에 붙여넣을 번들을 복사한다.
class LagDiagnosticCard extends StatefulWidget {
  const LagDiagnosticCard({super.key});

  @override
  State<LagDiagnosticCard> createState() => _LagDiagnosticCardState();
}

class _LagDiagnosticCardState extends State<LagDiagnosticCard> {
  Map<String, Object?>? _summary;
  String _folder = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    LagDiagnosticBundleService.instance.revision.addListener(_onRevision);
    AppLagDetectorService.instance.recentStalls.addListener(_onRevision);
    if (Platform.isWindows) {
      CpuSpikeDetectorService.instance.recentSpikes.addListener(_onRevision);
    }
    _reload();
  }

  @override
  void dispose() {
    LagDiagnosticBundleService.instance.revision.removeListener(_onRevision);
    AppLagDetectorService.instance.recentStalls.removeListener(_onRevision);
    if (Platform.isWindows) {
      CpuSpikeDetectorService.instance.recentSpikes.removeListener(_onRevision);
    }
    super.dispose();
  }

  void _onRevision() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    final LagDiagnosticBundleService bundle = LagDiagnosticBundleService.instance;
    Map<String, Object?>? summary;
    try {
      final File f = File(bundle.summaryPath);
      if (await f.exists()) {
        summary = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _folder = bundle.debugFolder;
      _loading = false;
    });
  }

  Future<void> _copyBundle() async {
    final String text =
        await SevereLagSessionService.instance.copyableAgentReport();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    final String hint = Platform.isIOS || Platform.isAndroid
        ? '렉 진단 번들 복사됨 — PC Cursor 채팅에 붙여넣으세요'
        : '렉 진단 번들이 클립보드에 복사됐어요 — Cursor/Claude에 붙여넣으세요';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(hint)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, int> counts = _parseCounts(_summary);
    final int total = counts['total'] ?? 0;
    final List<LagEvent> stalls = AppLagDetectorService.instance.recentStalls.value;
    final List<CpuSpikeEvent> spikes = Platform.isWindows
        ? CpuSpikeDetectorService.instance.recentSpikes.value
        : const <CpuSpikeEvent>[];

    return Card(
      elevation: 0,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.speed, color: AppColors.accent, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '렉 · CPU 스파이크 자동 기록',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
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
            const SizedBox(height: 8),
            Text(
              'CPU 급증·UI 멈춤이 감지되면 어떤 작업이 돌고 있었는지 '
              '파일로 남깁니다. 정상 작업 vs 예상치 못한 멈춤을 구분해요. '
              '심할 때는 전체 화면 안내가 뜹니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
            if (Platform.isIOS || Platform.isAndroid) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'iPhone/Android: 「AI용 번들 복사」 후 PC Cursor에 붙여넣기',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _chip('CPU 스파이크', counts['cpuSpike'] ?? 0, Colors.orange),
                _chip('UI 렉', counts['uiStall'] ?? 0, Colors.amber),
                _chip('UI 프리즈', counts['uiFreeze'] ?? 0, Colors.redAccent),
                _chip('30초+ 프리즈', counts['severeUiFreeze'] ?? 0, Colors.red),
                _chip('렉 세션', counts['severeLagSession'] ?? 0, Colors.deepPurple),
                _chip('합계', total, AppColors.accent),
              ],
            ),
            if (spikes.isNotEmpty || stalls.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              if (spikes.isNotEmpty)
                _eventLine(
                  '최근 CPU',
                  '${spikes.first.cpuPctOneCore.toStringAsFixed(0)}%/코어 · '
                  '${spikes.first.classification?.legitimacyLabelKo ?? ""} · '
                  '${spikes.first.activeServiceLabels.join(", ")}',
                ),
              if (stalls.isNotEmpty)
                _eventLine(
                  '최근 UI 렉',
                  '${stalls.first.stallMs}ms (${stalls.first.classification?.legitimacyLabelKo ?? ""}) · '
                  'reg=${stalls.first.childProcesses['reg'] ?? 0}',
                ),
            ],
            const SizedBox(height: 12),
            SelectableText(
              _folder,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'Consolas',
                    color: AppColors.muted,
                  ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _copyBundle,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('AI용 번들 복사'),
                ),
                OutlinedButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('새로고침'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, int n, Color color) {
    return Chip(
      label: Text('$label $n'),
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.35)),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _eventLine(String title, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$title: $detail',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Map<String, int> _parseCounts(Map<String, Object?>? summary) {
    if (summary == null) return const <String, int>{};
    final Object? raw = summary['counts'];
    if (raw is! Map) return const <String, int>{};
    return raw.map(
      (Object? k, Object? v) => MapEntry('$k', v is int ? v : int.tryParse('$v') ?? 0),
    );
  }
}
