import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_logger.dart';
import '../services/automated_browser_handoff_service.dart';
import '../services/block_activity_log_service.dart';
import '../services/browser_block_enforcement_health_service.dart';
import '../services/tri_browser_self_heal_service.dart';
import '../services/chrome_core_principles_service.dart';
import '../services/windows_five_layer_block_service.dart';
import '../services/windows_five_layer_experiment_service.dart';
import '../theme/app_colors.dart';

/// Visual status board: shows where blocking is not yet applied.
class BlockingPipelineStatusPanel extends StatefulWidget {
  const BlockingPipelineStatusPanel({super.key});

  @override
  State<BlockingPipelineStatusPanel> createState() =>
      _BlockingPipelineStatusPanelState();
}

class _BlockingPipelineStatusPanelState extends State<BlockingPipelineStatusPanel> {
  BrowserEnforcementHealth? _health;
  TriBrowserHealReport? _tri;
  FiveLayerStatus? _fiveLayer;
  FiveLayerExperimentReport? _fiveLayerExp;
  CorePrinciplesStatus? _corePrinciples;
  bool _loading = true;
  bool _running = false;
  bool _experimenting = false;

  VoidCallback? _revListener;
  VoidCallback? _triListener;
  Timer? _debounce;

  static const Duration _kDebounce = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _revListener = () => _scheduleRefresh();
    _triListener = () {
      if (mounted) setState(() => _tri = TriBrowserSelfHealService.instance.latest.value);
    };
    BlockActivityLogService.instance.revision.addListener(_revListener!);
    TriBrowserSelfHealService.instance.latest.addListener(_triListener!);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_revListener != null) {
      BlockActivityLogService.instance.revision.removeListener(_revListener!);
    }
    if (_triListener != null) {
      TriBrowserSelfHealService.instance.latest.removeListener(_triListener!);
    }
    super.dispose();
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(_kDebounce, () => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Use cached result (max 30 s stale) — avoids registry/PowerShell on every event.
    final BrowserEnforcementHealth h =
        await BrowserBlockEnforcementHealthService.instance.analyze(force: false);
    FiveLayerStatus? five;
    CorePrinciplesStatus? core;
    if (Platform.isWindows) {
      five = WindowsFiveLayerBlockService.instance.lastStatus ??
          await WindowsFiveLayerBlockService.instance.syncLayers(
            reason: 'pipeline_ui',
          );
      core = await ChromeCorePrinciplesService.instance.probe();
    }
    if (!mounted) return;
    setState(() {
      _health = h;
      _tri = TriBrowserSelfHealService.instance.latest.value;
      _fiveLayer = five;
      _corePrinciples = core;
      _loading = false;
    });
  }

  bool _hasRulesFetch() {
    return BlockActivityLogService.instance.events.any(
      (BlockActivityEvent e) => e.kind == BlockActivityKind.rulesFetch,
    );
  }

  bool _hasBlockHit() {
    return BlockActivityLogService.instance.events.any(
      (BlockActivityEvent e) => e.kind == BlockActivityKind.blockHit,
    );
  }

  Future<void> _runFiveLayerExperiment() async {
    if (!Platform.isWindows) return;
    setState(() => _experimenting = true);
    try {
      final FiveLayerExperimentReport rep =
          await WindowsFiveLayerExperimentService.instance.run(
        applyFirst: true,
        reason: 'pipeline_ui',
      );
      _fiveLayerExp = rep;
      _fiveLayer = rep.status;
    } catch (e, st) {
      AppLogger.instance.warn('pipeline five-layer experiment failed', error: e);
      AppLogger.instance.info('$st');
    } finally {
      if (mounted) setState(() => _experimenting = false);
    }
  }

  Future<void> _autoApplyNow() async {
    setState(() => _running = true);
    try {
      await TriBrowserSelfHealService.instance.runCycle(
        reason: 'ui_pipeline',
        userInitiated: true,
        repair: true,
      );
      await AutomatedBrowserHandoffService.instance.runZeroTouch(
        reason: 'ui_pipeline',
        force: true,
      );
      await _refresh();
    } catch (e, st) {
      AppLogger.instance.warn('pipeline auto-apply failed', error: e);
      AppLogger.instance.info('$st');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return const SizedBox.shrink();
    }
    if (_loading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('차단 적용 상태 확인 중…'),
            ],
          ),
        ),
      );
    }

    final BrowserEnforcementHealth? h = _health;
    final TriBrowserHealReport? tri = _tri;

    final bool level0Rules = (h?.youtubeRuleCount ?? 0) > 0;
    final bool level1BrowsersReady = tri?.ok ?? false;
    final bool level2Fetch = _hasRulesFetch();
    final bool level3Hit = _hasBlockHit();

    final int level = level3Hit
        ? 3
        : level2Fetch
            ? 2
            : level1BrowsersReady
                ? 1
                : level0Rules
                    ? 0
                    : -1;

    final String guide = switch (level) {
      3 => '완료: 차단 이벤트가 기록되었습니다. 이제 영상/사이트가 열리지 않아야 합니다.',
      2 =>
        '거의 완료: 확장은 규칙을 받고 있어요. 아직 차단이 없으면, 막아야 할 URL(예: 유튜브 watch)로 테스트하면 됩니다.',
      1 =>
        '브라우저 준비됨: 보호 모드 연결은 OK입니다. 잠시 후 자동으로 규칙 동기화(rulesFetch)가 찍혀야 합니다.',
      0 =>
        '규칙은 있는데 브라우저 적용이 아직이에요. 아래 버튼을 누르면 앱이 보호 브라우저 전환 + 확장/룰/PAC를 자동 복구합니다.',
      _ =>
        '현재 활성 규칙이 없어요. 스케줄에서 유튜브/키워드를 켜면 이 파이프라인이 자동으로 시작됩니다.',
    };

    final List<String> missing = <String>[
      if (!level0Rules) '규칙 없음: 현재 시간대 스케줄에 유튜브/키워드 규칙을 켜세요.',
      if (!level1BrowsersReady) '브라우저 보호 미완료: Chrome/Edge/Firefox 보호 상태를 복구해야 합니다.',
      if (!level2Fetch) '동기화 미확인: 확장이 아직 rulesFetch를 받지 못했습니다.',
      if (!level3Hit) '차단 이벤트 미확인: 테스트 URL에서 blockHit가 아직 기록되지 않았습니다.',
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.fact_check_outlined, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '차단 적용 현황판',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (Platform.isWindows)
                  TextButton(
                    onPressed: (_running || _experimenting)
                        ? null
                        : _runFiveLayerExperiment,
                    child: Text(_experimenting ? '실험 중…' : '5계층 실험'),
                  ),
                FilledButton.tonal(
                  onPressed: _running ? null : _autoApplyNow,
                  child: Text(_running ? '적용 중…' : '자동 적용'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _stepsRow(
              context,
              steps: <_Step>[
                _Step('규칙', level0Rules, '스케줄에 유튜브/키워드가 켜짐'),
                _Step('브라우저', level1BrowsersReady, 'Chrome/Edge/Firefox 보호 준비'),
                _Step('동기화', level2Fetch, '확장 rulesFetch 확인'),
                _Step('차단', level3Hit, 'blockHit 확인'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              guide,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.muted, height: 1.35),
            ),
            if (missing.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '아직 미적용된 항목',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.warning,
                          ),
                    ),
                    const SizedBox(height: 6),
                    for (final String m in missing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '- $m',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppColors.muted,
                                height: 1.35,
                              ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (Platform.isWindows && _fiveLayerExp != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '실험: ${_fiveLayerExp!.passCount}/${_fiveLayerExp!.probes.length} 통과'
                '${_fiveLayerExp!.youtubeApiSample?['blocked'] == true ? ' · YouTube API 차단 OK' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
              ),
            ],
            if (Platform.isWindows && _fiveLayer != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                '5계층 차단 (Windows)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  _chip(
                    label: '① hosts ${_fiveLayer!.layer1Hosts ? "ON" : "OFF"}',
                    tone: _fiveLayer!.layer1Hosts
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                  _chip(
                    label: '② 확장 ${_fiveLayer!.layer2Extension ? "ON" : "OFF"}',
                    tone: _fiveLayer!.layer2Extension
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                  _chip(
                    label: '③ PAC ${_fiveLayer!.layer3PacProxy ? "ON" : "OFF"}',
                    tone: _fiveLayer!.layer3PacProxy
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                  _chip(
                    label:
                        '④ 창제목 ${_fiveLayer!.layer4WindowTitle ? "ON" : "OFF"}',
                    tone: _fiveLayer!.layer4WindowTitle
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                  _chip(
                    label:
                        '⑤ 방화벽 ${_fiveLayer!.layer5Firewall ? "ON" : "OFF"}',
                    tone: _fiveLayer!.layer5Firewall
                        ? AppColors.success
                        : AppColors.muted,
                  ),
                ],
              ),
            ],
            if (Platform.isWindows && _corePrinciples != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                '핵심 3원칙 (Chrome·유튜브·사이트)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  _chip(
                    label:
                        'A 정책 ${_corePrinciples!.principleA ? "ON" : "OFF"}',
                    tone: _corePrinciples!.principleA
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                  _chip(
                    label:
                        'B hosts ${_corePrinciples!.principleB ? "잠금" : "열림"}',
                    tone: _corePrinciples!.principleB
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                  _chip(
                    label: _corePrinciples!.adminAccount
                        ? 'C 관리자계정'
                        : 'C 표준계정',
                    tone: _corePrinciples!.principleC
                        ? AppColors.success
                        : AppColors.muted,
                  ),
                  _chip(
                    label:
                        'YT ${_corePrinciples!.youtubeHandleCount}채널 ${_corePrinciples!.youtubeVideoCount}영상',
                    tone: AppColors.accent,
                  ),
                ],
              ),
            ],
            if (tri != null && tri.browsers.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: tri.browsers.map((BrowserHealthRow r) {
                  final bool ok = r.ok || r.skipped;
                  return _chip(
                    label: '${r.label}: ${ok ? "OK" : "미완료"}',
                    tone: ok ? AppColors.success : AppColors.warning,
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip({required String label, required Color tone}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: tone, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _stepsRow(
    BuildContext context, {
    required List<_Step> steps,
  }) {
    return Row(
      children: <Widget>[
        for (int i = 0; i < steps.length; i++) ...<Widget>[
          Expanded(child: _stepTile(steps[i])),
          if (i != steps.length - 1)
            Container(
              width: 18,
              height: 2,
              color: AppColors.muted.withValues(alpha: 0.25),
            ),
        ],
      ],
    );
  }

  Widget _stepTile(_Step s) {
    final Color tone = s.ok ? AppColors.success : AppColors.warning;
    return Column(
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(color: tone.withValues(alpha: 0.35)),
          ),
          child: Icon(
            s.ok ? Icons.check : Icons.priority_high,
            size: 18,
            color: tone,
          ),
        ),
        const SizedBox(height: 6),
        Text(s.title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(
          s.subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 10, color: AppColors.muted, height: 1.2),
        ),
      ],
    );
  }
}

class _Step {
  const _Step(this.title, this.ok, this.subtitle);

  final String title;
  final bool ok;
  final String subtitle;
}

