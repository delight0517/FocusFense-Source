import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/one_tap_block_everything_service.dart';
import '../theme/app_colors.dart';
import '../widgets/settings_disclosure.dart';
import '../widgets/protection_setup_overview.dart';
import 'browser_protection_center_screen.dart';

/// "버튼 하나로 다 되게" — runs the full block pipeline + shows live
/// per-step status + surfaces the path to the structured failure report
/// so the user can hand it to Cursor / Claude for repair.
class OneTapBlockScreen extends StatefulWidget {
  const OneTapBlockScreen({super.key});

  @override
  State<OneTapBlockScreen> createState() => _OneTapBlockScreenState();
}

class _OneTapBlockScreenState extends State<OneTapBlockScreen> {
  bool _running = false;
  OneTapResult? _result;
  final List<_LiveStep> _live = <_LiveStep>[];

  @override
  Widget build(BuildContext context) {
    final String reportPath = OneTapBlockEverythingService.reportPath();
    final String progressLogPath =
        OneTapBlockEverythingService.progressLogPath();
    return Scaffold(
      appBar: AppBar(title: const Text('쉬운 차단 설정')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.shield_outlined),
            label: Text(_running ? '설정을 준비하는 중…' : '보호 설정 시작'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          if (Platform.isWindows)
            Card(
              child: ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: const Text('브라우저 관리'),
                subtitle: const Text('관리자 설치·복구와 Firefox 서명 관리'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BrowserProtectionCenterScreen(),
                  ),
                ),
              ),
            ),
          Card(
            color: AppColors.accent.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ProtectionSetupOverview(running: _running),
                  const SizedBox(height: 10),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.42),
                      ),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(
                            Icons.admin_panel_settings,
                            color: AppColors.warning,
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Windows 권한 요청이 나타나면 내용을 확인하고 승인해 주세요. '
                              '승인하지 못한 항목은 적용되지 않을 수 있습니다.',
                              style: TextStyle(height: 1.35),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Force-reset button — for when the user previously clicked
                  // run, the pipeline got stuck on a silently-dismissed UAC,
                  // and the lock is still held. Visible always (not only on
                  // failure) because the user can hit this BEFORE clicking
                  // run if the previous app session left things wedged.
                  SettingsDisclosure(
                    title: '점검이 멈춘 경우',
                    subtitle: '이전 작업의 잠금 상태 복구',
                    builder: (context) => Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text(
                          '"이미 실행 중" 잠금 강제 해제',
                          style: TextStyle(fontSize: 12),
                        ),
                        onPressed: _running
                            ? null
                            : () {
                                OneTapBlockEverythingService.instance
                                    .forceResetRunningLock();
                                setState(() {
                                  _live.clear();
                                  _result = null;
                                  _running = false;
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('다시 점검·복구를 시작할 수 있습니다.'),
                                    duration: Duration(seconds: 3),
                                  ),
                                );
                              },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_live.isNotEmpty)
            SettingsDisclosure(
              title: '자세한 진행 상태',
              subtitle: '문제가 있을 때 확인하는 단계별 기록',
              builder: (_) => _buildLiveCard(),
            ),
          if (_result != null) ...<Widget>[
            const SizedBox(height: 12),
            _buildResultCard(_result!, reportPath),
          ],
          const SizedBox(height: 16),
          SettingsDisclosure(
            title: '개발자용 보고서',
            subtitle: '지원 담당자에게 필요한 기술 정보',
            builder: (_) => _buildReportCard(reportPath, progressLogPath),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Text(
                '진행 상황',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final _LiveStep s in _live)
              ListTile(
                dense: true,
                leading: _iconFor(s.status),
                title: Text(s.title),
                subtitle: s.detail.isEmpty ? null : Text(s.detail),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(OneTapResult r, String reportPath) {
    return Card(
      color: r.ok
          ? AppColors.accent.withValues(alpha: 0.08)
          : AppColors.danger.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  r.ok ? Icons.check_circle : Icons.error_outline,
                  color: r.ok ? AppColors.accent : AppColors.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.ok
                        ? '설정 준비 완료 · 실제 차단 확인 필요'
                        : '${r.failedCount}개 항목에 추가 확인이 필요합니다',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            if (!r.ok) ...<Widget>[
              const SizedBox(height: 12),
              // The user complained the previous UI told them "리포트 저장됨"
              // but did not let them copy the actual failure details. Now we
              // surface every failing step's detail + suggested fix INLINE,
              // and provide three distinct copy buttons:
              //   1. 「전체 리포트 복사」 — full JSON to paste into Claude
              //   2. 「실패 요약 복사」 — human-readable Korean summary
              //   3. 「Cursor 프롬프트 복사」 — agent-style action prompt
              // Path-only and folder-open are kept for completeness.
              const Text(
                '권한 요청과 브라우저 확장 연결을 확인해 주세요. '
                '해결되지 않으면 문제 요약을 복사해 문의할 수 있습니다.',
              ),
              SettingsDisclosure(
                title: '문제 자세히 보기',
                subtitle: '지원 담당자와 함께 확인할 상세 정보',
                builder: (_) => Column(
                  children: [
                    for (final step in r.steps.where(
                      (s) => s.status == OneTapStepStatus.failed,
                    ))
                      _buildFailedStepCard(step),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '문제가 계속되면 아래 요약을 복사해 문의해 주세요.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('문제 요약 복사'),
                onPressed: () => _copyFailureSummary(r, reportPath),
              ),
              SettingsDisclosure(
                title: '다른 형식으로 공유',
                subtitle: '상세 보고서, 로그와 파일 위치',
                builder: (_) => Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    FilledButton.icon(
                      icon: const Icon(Icons.copy_all),
                      label: const Text('전체 리포트 복사 (JSON)'),
                      onPressed: () => _copyFullReport(r),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.code),
                      label: const Text('Cursor 프롬프트 복사'),
                      onPressed: () => _copyAgentPrompt(reportPath),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.timeline),
                      label: const Text('진행 로그 복사'),
                      onPressed: _copyProgressLog,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy),
                      label: const Text('경로만 복사'),
                      onPressed: () => _copy(reportPath, '경로 복사됨'),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.folder_open),
                      label: const Text('폴더 열기'),
                      onPressed: () => _openReportFolder(reportPath),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReportCard(String reportPath, String progressLogPath) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('리포트 형식', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              '각 단계마다 status(ok/failed/skipped), detail, '
              'codeAnchors(고쳐야 할 파일 경로), machineState(원시 상태), '
              'suggestedFix(수정 힌트)가 JSON에 들어갑니다. '
              '상단 agentHints에는 「먼저 읽을 문서」와 「실패한 단계 요약」이 '
              '있어 AI 에이전트가 곧바로 작업할 수 있습니다.',
            ),
            const SizedBox(height: 8),
            SelectableText(
              'report: $reportPath\nprogress: $progressLogPath',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Icon _iconFor(OneTapStepStatus s) {
    switch (s) {
      case OneTapStepStatus.ok:
        return Icon(Icons.check_circle, color: AppColors.accent);
      case OneTapStepStatus.failed:
        return Icon(Icons.error_outline, color: AppColors.danger);
      case OneTapStepStatus.skipped:
        return const Icon(Icons.remove_circle_outline, color: Colors.grey);
    }
  }

  /// Shown once, right before the pipeline may pop a Windows UAC dialog —
  /// so the user knows to watch for it and click 「예」. Without this, the
  /// prompt (if it appears at all) is unexplained, and if a security
  /// program silently swallows it, the user has no idea anything was
  /// supposed to happen.
  bool _uacHintShown = false;

  void _showUacHint() {
    if (!mounted || _uacHintShown) return;
    _uacHintShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Windows 권한 요청이 나타나면 내용을 확인해 주세요.')),
    );
  }

  void _upsertLiveStep({
    required String id,
    required String title,
    required OneTapStepStatus status,
    required String detail,
  }) {
    final int byId = _live.indexWhere((_LiveStep s) => s.id == id);
    final int byTitle = _live.indexWhere((_LiveStep s) => s.title == title);
    final int index = byId >= 0 ? byId : byTitle;
    final _LiveStep next = _LiveStep(
      id: id,
      title: title,
      status: status,
      detail: detail,
    );
    if (index >= 0) {
      _live[index] = next;
    } else {
      _live.add(next);
    }
  }

  Future<void> _run() async {
    if (_running) return;
    _uacHintShown = false;
    setState(() {
      _running = true;
      _live.clear();
      _result = null;
    });
    final OneTapResult r = await OneTapBlockEverythingService.instance.run(
      onElevationHint: _showUacHint,
      onStepStarted: (String id, String title, String detail) {
        if (!mounted) return;
        setState(() {
          _upsertLiveStep(
            id: id,
            title: title,
            status: OneTapStepStatus.skipped,
            detail: detail,
          );
        });
      },
      onStatus: (String title, OneTapStepStatus status) {
        if (!mounted) return;
        setState(() {
          _upsertLiveStep(
            id: title,
            title: title,
            status: status,
            detail: status == OneTapStepStatus.ok
                ? ''
                : status == OneTapStepStatus.skipped
                ? '건너뜀'
                : '실패 — 상세는 아래 카드',
          );
        });
      },
    );
    // After the run lands, backfill the live list with the actual failure
    // details from the report so the user sees the reason inline without
    // having to scroll to a separate card and without having to open JSON.
    if (mounted) {
      for (final OneTapStepReport rep in r.steps) {
        final int i = _live.indexWhere(
          (_LiveStep ls) => ls.id == rep.id || ls.title == rep.title,
        );
        if (i < 0) continue;
        final String detail = rep.status == OneTapStepStatus.failed
            ? rep.detail
            : (rep.detail.isEmpty ? '' : rep.detail);
        if (detail.isEmpty) continue;
        _live[i] = _LiveStep(
          id: rep.id,
          title: rep.title,
          status: rep.status,
          detail: detail,
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = r;
    });
  }

  /// Per-failed-step inline card — shows the actual `detail`,
  /// `suggestedFix`, key `machineState` values, and the codeAnchors. This is
  /// what the user wanted: the failure reason visible right in the UI,
  /// copy-selectable, no need to dig into a JSON file.
  Widget _buildFailedStepCard(OneTapStepReport step) {
    final StringBuffer machine = StringBuffer();
    if (step.machineState.isNotEmpty) {
      step.machineState.forEach((String k, Object? v) {
        machine.writeln('  $k: $v');
      });
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.error_outline, size: 18, color: AppColors.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    step.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '이 단계만 복사',
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () => _copyOneStep(step),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(step.detail, style: const TextStyle(fontSize: 13)),
            if (step.suggestedFix != null) ...<Widget>[
              const SizedBox(height: 6),
              SelectableText(
                '→ 권장 조치: ${step.suggestedFix}',
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: AppColors.accent,
                ),
              ),
            ],
            if (machine.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              SelectableText(
                'machineState:\n${machine.toString().trimRight()}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ],
            if (step.codeAnchors.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              SelectableText(
                '코드 위치:\n${step.codeAnchors.map((String c) => '  $c').join('\n')}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _copy(String text, String confirm) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(confirm)));
  }

  /// Full structured JSON of the run — most agent-friendly format.
  Future<void> _copyFullReport(OneTapResult r) async {
    final String json = const JsonEncoder.withIndent('  ').convert(r.toJson());
    await _copy(json, '전체 리포트 JSON이 클립보드에 복사됨');
  }

  /// One-step copy — keep it tight; lets the user grab a single failure to
  /// paste into chat without unrelated noise.
  Future<void> _copyProgressLog() async {
    final String path = OneTapBlockEverythingService.progressLogPath();
    final File file = File(path);
    final String text = await file.exists()
        ? await file.readAsString()
        : 'progress log not found: $path';
    await _copy(text, '진행 로그 복사됨');
  }

  Future<void> _copyOneStep(OneTapStepReport step) async {
    final StringBuffer sb = StringBuffer();
    sb.writeln('# ${step.title} (id: ${step.id}) — FAILED');
    sb.writeln();
    sb.writeln('상세: ${step.detail}');
    if (step.suggestedFix != null) {
      sb.writeln('권장 조치: ${step.suggestedFix}');
    }
    if (step.machineState.isNotEmpty) {
      sb.writeln();
      sb.writeln('machineState:');
      step.machineState.forEach((String k, Object? v) {
        sb.writeln('  $k: $v');
      });
    }
    if (step.codeAnchors.isNotEmpty) {
      sb.writeln();
      sb.writeln('코드 위치:');
      for (final String c in step.codeAnchors) {
        sb.writeln('  $c');
      }
    }
    await _copy(sb.toString(), '단계 정보 복사됨');
  }

  /// Korean natural-language summary — for forwarding to a non-technical
  /// helper or just having something pasteable in chat.
  Future<void> _copyFailureSummary(OneTapResult r, String reportPath) async {
    final List<OneTapStepReport> failed = r.steps
        .where((OneTapStepReport s) => s.status == OneTapStepStatus.failed)
        .toList();
    final StringBuffer sb = StringBuffer();
    sb.writeln('# Focus Fense — 차단 적용 실패 요약');
    sb.writeln();
    sb.writeln('실행 시각: ${r.finishedAt?.toLocal() ?? "방금"}');
    sb.writeln(
      '전체 ${r.steps.length}개 단계 중 성공 ${r.okCount}개 / 실패 ${r.failedCount}개',
    );
    sb.writeln();
    sb.writeln('## 실패한 단계');
    for (final OneTapStepReport s in failed) {
      sb.writeln();
      sb.writeln('### ${s.title} (id=${s.id})');
      sb.writeln('실패 사유: ${s.detail}');
      if (s.suggestedFix != null) {
        sb.writeln('권장 조치: ${s.suggestedFix}');
      }
      if (s.machineState.isNotEmpty) {
        sb.writeln('원시 상태:');
        s.machineState.forEach((String k, Object? v) {
          sb.writeln('  - $k = $v');
        });
      }
    }
    sb.writeln();
    sb.writeln('## 전체 리포트 JSON');
    sb.writeln(reportPath);
    sb.writeln();
    sb.writeln('## 참고 문서');
    sb.writeln('docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md');
    await _copy(sb.toString(), '실패 요약 복사됨 (Claude/Cursor에 붙여넣기 가능)');
  }

  Future<void> _copyAgentPrompt(String reportPath) async {
    final String prompt =
        'Focus Fense 차단 파이프라인 자가복구 요청.\n\n'
        '1) 다음 리포트 파일을 먼저 읽어주세요:\n   $reportPath\n'
        '2) docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md 도 읽어주세요.\n'
        '3) 리포트의 `agentHints.failedSteps` 배열에 있는 각 단계의 '
        '`codeAnchors` 파일을 열어 해당 단계가 실패한 원인을 찾고 수정해주세요.\n'
        '4) `machineState`에 원시 상태(boolean, 카운트)가 있으니 추가 진단을 '
        '돌리지 말고 그 값을 신뢰하세요.\n'
        '5) 고친 후 mobile/pubspec.yaml의 build number를 1 올리고 '
        'flutter test test/youtube_block_pipeline_test.dart를 돌려 검증하세요.';
    await _copy(prompt, 'Cursor/Claude용 프롬프트 복사됨');
  }

  Future<void> _openReportFolder(String reportPath) async {
    final String folder = File(reportPath).parent.path;
    if (Platform.isWindows) {
      try {
        await Process.start('explorer.exe', <String>[folder]);
      } catch (_) {}
    }
  }
}

class _LiveStep {
  _LiveStep({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
  });
  final String id;
  final String title;
  final OneTapStepStatus status;
  final String detail;
}
