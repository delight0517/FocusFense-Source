import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/apply_activation_report.dart';
import '../services/apply_diagnostic_bundle_service.dart';
import '../services/windows_uac_apply_session.dart';
import '../theme/app_colors.dart';

typedef ApplyRunCallback =
    Future<ApplyActivationReport> Function(
      void Function(String phaseLabel)? onPhase,
    );

/// Shows UAC/apply progress and per-step activation results.
///
/// **Never blocks the user without an exit:** 취소 · 닫기 · 바깥 탭 · Android back
/// all cancel a pending UAC wait (see [WindowsUacApplySession]).
Future<void> showApplyActivationDialog(
  BuildContext context, {
  required ApplyRunCallback runApply,
}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext ctx) => _ApplyActivationDialog(runApply: runApply),
  );
}

class _ApplyActivationDialog extends StatefulWidget {
  const _ApplyActivationDialog({required this.runApply});

  final ApplyRunCallback runApply;

  @override
  State<_ApplyActivationDialog> createState() => _ApplyActivationDialogState();
}

class _ApplyActivationDialogState extends State<_ApplyActivationDialog> {
  ApplyActivationReport? _report;
  Object? _error;
  bool _running = true;
  bool _userCancelled = false;
  Timer? _tick;
  int _elapsedSec = 0;
  String _phaseLabel = '준비 중…';

  @override
  void initState() {
    super.initState();
    WindowsUacApplySession.instance.resetSession();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_running || !mounted) return;
      setState(() => _elapsedSec++);
    });
    _go();
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_running) {
      unawaited(WindowsUacApplySession.instance.requestCancel());
    }
    super.dispose();
  }

  void _onPhase(String label) {
    if (!mounted || !_running || _userCancelled) return;
    setState(() => _phaseLabel = label);
  }

  Future<void> _go() async {
    try {
      final ApplyActivationReport r = await widget.runApply(_onPhase);
      if (!mounted) return;
      if (_userCancelled) {
        setState(() {
          _report = r;
          _running = false;
        });
        return;
      }
      setState(() {
        _report = r;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _running = false;
      });
    }
  }

  Future<void> _onCancel() async {
    if (!_running) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _userCancelled = true;
      _running = false;
      _phaseLabel = '취소 중…';
    });
    await WindowsUacApplySession.instance.requestCancel();
    if (!mounted) return;
    setState(() {
      _report = const ApplyActivationReport(
        success: false,
        steps: <ApplyActivationStep>[
          ApplyActivationStep(
            id: 'cancelled',
            label: '적용 취소',
            ok: false,
            detail: 'UAC 대기 또는 hosts 단계를 중단했습니다.',
          ),
        ],
        summary:
            '적용을 취소했습니다. 1단계(브라우저 HKCU 정책)는 이미 반영되었을 수 있습니다. '
            '「전체 복사」로 진단 번들을 붙여넣으면 문제 해결이 빠릅니다.',
      );
    });
  }

  Future<String> _fullPlainText() async {
    return ApplyDiagnosticBundleService.instance.buildForClipboard(
      report: _report,
      userCancelled: _userCancelled,
      error: _error,
      elapsedSec: _elapsedSec,
    );
  }

  Future<void> _copyAll() async {
    final String text = await _fullPlainText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _running
              ? '진단 번들(진행 중 상태 포함)을 클립보드에 복사했습니다.'
              : '진단 번들 전체를 클립보드에 복사했습니다.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showResult = !_running;
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _running) {
          unawaited(_onCancel());
        }
      },
      child: AlertDialog(
        title: Text(_running ? '승인 버튼을 눌러야 차단이 적용됩니다' : '시스템 차단 적용'),
        content: SizedBox(
          width: 520,
          child: _running
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _ApprovalInstructionCard(elapsedSec: _elapsedSec),
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      _phaseLabel,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '규칙 저장만으로는 모든 브라우저/hosts/DNS 차단이 끝나지 않을 수 있습니다. '
                      '이 창이 열린 동안 Windows가 별도 승인 창을 띄우면 「예」를 눌러 주세요. '
                      '그 승인이 끝나야 16.xbbg.tv 같은 숫자형 우회 사이트까지 막힙니다.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    const _ApprovalChecklist(),
                  ],
                )
              : _error != null
              ? _buildError(_error!)
              : _buildReport(_report!),
        ),
        actions: <Widget>[
          if (_running)
            TextButton(
              onPressed: () => unawaited(_onCancel()),
              child: const Text('취소'),
            ),
          TextButton.icon(
            onPressed: _copyAll,
            icon: const Icon(Icons.copy, size: 18),
            label: Text(_running ? '진단 복사' : '전체 복사'),
          ),
          if (showResult)
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기'),
            ),
        ],
      ),
    );
  }

  Widget _buildError(Object err) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.error_outline, color: AppColors.danger),
              SizedBox(width: 8),
              Text('오류 발생', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            err.toString(),
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReport(ApplyActivationReport r) {
    return SingleChildScrollView(
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  _userCancelled
                      ? Icons.cancel_outlined
                      : (r.success ? Icons.check_circle : Icons.warning_amber),
                  color: _userCancelled
                      ? AppColors.muted
                      : (r.success ? AppColors.success : AppColors.warning),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _userCancelled
                        ? '사용자 취소'
                        : (r.success
                              ? (r.steps.any(
                                          (ApplyActivationStep s) =>
                                              s.id == 'browser_protection' &&
                                              s.ok,
                                        ) &&
                                        !r.steps.any(
                                          (ApplyActivationStep s) =>
                                              s.id == 'hosts_marker' && s.ok,
                                        )
                                    ? '브라우저 보호 작동 중'
                                    : '활성화 완료')
                              : '추가 조치 필요'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              r.summary,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(height: 1.35),
            ),
            const SizedBox(height: 12),
            for (final ApplyActivationStep s in r.steps) ...<Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    s.ok ? Icons.check : Icons.close,
                    size: 18,
                    color: s.ok
                        ? AppColors.success
                        : (s.id == 'browser_protection'
                              ? AppColors.danger
                              : AppColors.muted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          s.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          s.detail,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.muted, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _ApprovalInstructionCard extends StatelessWidget {
  const _ApprovalInstructionCard({required this.elapsedSec});

  final int elapsedSec;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.55)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.admin_panel_settings, color: AppColors.warning),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '잠시 후 Windows 승인 창이 뜨면 반드시 「예」를 누르세요',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '화면이 어두워지거나 작업 표시줄 방패 아이콘이 깜빡일 수 있습니다. '
                    '「아니오」를 누르거나 창을 놓치면 URL 차단이 일부만 적용됩니다.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      height: 1.35,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '대기 $elapsedSec초 / 최대 ${WindowsUacApplySession.kDefaultTimeout.inMinutes}분',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.warning,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApprovalChecklist extends StatelessWidget {
  const _ApprovalChecklist();

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _ApprovalChecklistRow(
          icon: Icons.looks_one,
          text: '앱에서 규칙을 저장합니다.',
          style: style,
        ),
        _ApprovalChecklistRow(
          icon: Icons.looks_two,
          text: 'Windows 승인 창에서 「예」를 눌러 시스템 차단을 허용합니다.',
          style: style,
        ),
        _ApprovalChecklistRow(
          icon: Icons.looks_3,
          text: '앱이 hosts/DNS/브라우저 정책을 검증하고 실패하면 로그에 남깁니다.',
          style: style,
        ),
      ],
    );
  }
}

class _ApprovalChecklistRow extends StatelessWidget {
  const _ApprovalChecklistRow({
    required this.icon,
    required this.text,
    required this.style,
  });

  final IconData icon;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
