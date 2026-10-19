import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_operation_progress_service.dart';
import '../services/lag_work_classifier.dart';
import '../services/severe_lag_session_service.dart';
import '../theme/app_colors.dart';

/// Full-screen overlay during severe lag or important long-running work.
/// Shows %, ETA, elapsed time, and whether the wait is expected vs a bug.
class SevereLagOverlay extends StatefulWidget {
  const SevereLagOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<SevereLagOverlay> createState() => _SevereLagOverlayState();
}

class _SevereLagOverlayState extends State<SevereLagOverlay> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    SevereLagSessionService.instance.session.addListener(_onSession);
    AppOperationProgressService.instance.revision.addListener(_onSession);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (SevereLagSessionService.instance.session.value != null && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    SevereLagSessionService.instance.session.removeListener(_onSession);
    AppOperationProgressService.instance.revision.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final SevereLagSession? session =
        SevereLagSessionService.instance.session.value;
    if (session == null) return widget.child;

    final AppOperationProgress? op =
        AppOperationProgressService.instance.primary;
    final LagWorkClassification c = session.classification;
    final bool isBug = c.legitimacy == LagLegitimacy.unexpectedBug;
    final Color accent =
        isBug ? const Color(0xFFE53935) : AppColors.accent;
    final Duration elapsed =
        Duration(milliseconds: session.elapsedMs);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: <Widget>[
          widget.child,
          Positioned.fill(
            child: Material(
              color: Colors.black.withValues(alpha: 0.82),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _badge(c.legitimacyLabelKo, accent),
                      const SizedBox(height: 20),
                      Text(
                        c.headlineKo,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        c.explainKo,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.88),
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                      const Spacer(),
                      if (op != null) ...<Widget>[
                        _progressBlock(op, accent),
                        const SizedBox(height: 20),
                      ] else ...<Widget>[
                        LinearProgressIndicator(
                          minHeight: 6,
                          color: accent,
                          backgroundColor: Colors.white24,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '진행률 계산 중…',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      _elapsedRow(elapsed),
                      const SizedBox(height: 16),
                      if (!Platform.isWindows && !Platform.isMacOS)
                        Text(
                          'iPhone/Android: 복구 후 설정→진단→「AI용 번들 복사」→ '
                          'PC Cursor 채팅에 붙여넣기',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 11,
                          ),
                        )
                      else
                        Text(
                          '【Focus Fense】이 작업이 최우선입니다. '
                          '완료될 때까지 잠시만 기다려 주세요.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 11,
                          ),
                        ),
                      if (isBug) ...<Widget>[
                        const SizedBox(height: 16),
                        TextButton.icon(
                          onPressed: _copyReport,
                          icon: const Icon(Icons.copy, color: Colors.white70),
                          label: const Text(
                            '렉 로그 복사 (Cursor용)',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.95),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _progressBlock(AppOperationProgress op, Color accent) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                op.step,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!op.indeterminate)
              Text(
                '${op.percent}%',
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: op.indeterminate
              ? LinearProgressIndicator(
                  minHeight: 8,
                  color: accent,
                  backgroundColor: Colors.white24,
                )
              : LinearProgressIndicator(
                  value: op.fraction.clamp(0.02, 1.0),
                  minHeight: 8,
                  color: accent,
                  backgroundColor: Colors.white24,
                ),
        ),
        const SizedBox(height: 8),
        Text(
          '${op.etaLabel} · ${op.totalLabel}',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _elapsedRow(Duration elapsed) {
    String label;
    if (elapsed.inMinutes >= 1) {
      label = '경과 ${elapsed.inMinutes}분 ${elapsed.inSeconds % 60}초';
    } else {
      label = '경과 ${elapsed.inSeconds}초';
    }
    return Text(
      label,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Future<void> _copyReport() async {
    final String text =
        await SevereLagSessionService.instance.copyableAgentReport();
    await Clipboard.setData(ClipboardData(text: text));
  }
}
