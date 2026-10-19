import 'dart:io';

import 'package:flutter/material.dart';

import '../models/post_rebuild_activation_report.dart';
import '../router/app_router.dart';
import '../services/post_rebuild_activation_notifier.dart';
import '../theme/app_colors.dart';

/// Shows a one-shot dialog when [PostRebuildActivationNotifier] publishes a report.
class PostRebuildActivationListener extends StatefulWidget {
  const PostRebuildActivationListener({super.key, required this.child});

  final Widget child;

  @override
  State<PostRebuildActivationListener> createState() =>
      _PostRebuildActivationListenerState();
}

class _PostRebuildActivationListenerState
    extends State<PostRebuildActivationListener> {
  @override
  void initState() {
    super.initState();
    PostRebuildActivationNotifier.instance.addListener(_onNotify);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  @override
  void dispose() {
    PostRebuildActivationNotifier.instance.removeListener(_onNotify);
    super.dispose();
  }

  void _onNotify() => _maybeShow();

  void _maybeShow() {
    if (!Platform.isWindows || !mounted) return;
    final PostRebuildActivationReport? r =
        PostRebuildActivationNotifier.instance.pendingReport;
    if (r == null) return;
    PostRebuildActivationNotifier.instance.clearPending();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showDialog(r);
    });
  }

  Future<void> _showDialog(PostRebuildActivationReport report) async {
    // Listener wraps MaterialApp.router — use root navigator, not this context.
    final BuildContext? navCtx = appRootNavigatorKey.currentContext;
    if (navCtx == null || !mounted) return;

    final List<String> lines = report.summaryLines();
    await showDialog<void>(
      context: navCtx,
      barrierDismissible: true,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: Row(
            children: <Widget>[
              Icon(
                report.universalOk ? Icons.verified_user : Icons.warning_amber,
                color: report.universalOk ? AppColors.success : AppColors.warning,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '리빌드 완료 · 차단 자동 적용',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    report.universalMessage,
                    style: TextStyle(
                      color: report.universalOk
                          ? AppColors.success
                          : AppColors.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final String line in lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        line,
                        style: Theme.of(ctx).textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    final BuildContext? snackCtx = appRootNavigatorKey.currentContext;
    if (snackCtx == null) return;
    ScaffoldMessenger.maybeOf(snackCtx)?.showSnackBar(
      SnackBar(
        content: Text(
          report.universalOk
              ? '✅ v${report.buildLabel}: PAC·3단계 차단 켜짐 — 보호 Chrome으로 YouTube 여세요'
              : '⚠️ v${report.buildLabel}: 일부 차단 실패 — 확인 창 내용 참고',
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
