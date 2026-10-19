import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_operation_progress_service.dart';
import '../theme/app_colors.dart';

/// Shell footer strip — shows what is loading, %, and ETA for all active ops.
class AppOperationProgressStrip extends StatefulWidget {
  const AppOperationProgressStrip({super.key, this.desktopStyle = true});

  final bool desktopStyle;

  @override
  State<AppOperationProgressStrip> createState() =>
      _AppOperationProgressStripState();
}

class _AppOperationProgressStripState extends State<AppOperationProgressStrip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    AppOperationProgressService.instance.revision.addListener(_onRev);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (AppOperationProgressService.instance.hasActive && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    AppOperationProgressService.instance.revision.removeListener(_onRev);
    super.dispose();
  }

  void _onRev() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppOperationProgressService svc = AppOperationProgressService.instance;
    // Background pipelines (boot_browser_autofix, WorkContext) stay off-screen.
    final List<AppOperationProgress> visible = svc.operations
        .where((AppOperationProgress o) => o.explicit)
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    AppOperationProgress? primary;
    for (final AppOperationProgress o in visible) {
      if (primary == null || o.updatedAt.isAfter(primary.updatedAt)) {
        primary = o;
      }
    }
    final int extra = visible.length - 1;
    final Color accent =
        widget.desktopStyle ? AppColors.accent : AppColors.accent;
    final Color bg = accent.withValues(alpha: 0.08);
    final Color border = accent.withValues(alpha: 0.28);

    return Material(
      color: bg,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (primary != null) _primaryRow(context, primary, accent, extra),
            if (visible.length > 1) ...<Widget>[
              const SizedBox(height: 6),
              ...visible
                  .where((AppOperationProgress o) => o.id != primary?.id)
                  .take(2)
                  .map((AppOperationProgress o) => _secondaryLine(o)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _primaryRow(
    BuildContext context,
    AppOperationProgress op,
    Color accent,
    int extra,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: accent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                op.title,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!op.indeterminate)
              Text(
                '${op.percent}%',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
              ),
            if (extra > 0) ...<Widget>[
              const SizedBox(width: 6),
              Text(
                '+$extra',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.muted,
                    ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          op.step,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
              ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: op.indeterminate
              ? LinearProgressIndicator(
                  minHeight: 5,
                  color: accent,
                  backgroundColor: accent.withValues(alpha: 0.15),
                )
              : LinearProgressIndicator(
                  value: op.fraction.clamp(0.02, 1.0),
                  minHeight: 5,
                  color: accent,
                  backgroundColor: accent.withValues(alpha: 0.15),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          '${op.etaLabel} · ${op.totalLabel}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.muted,
                fontSize: 10,
              ),
        ),
      ],
    );
  }

  Widget _secondaryLine(AppOperationProgress op) {
    return Padding(
      padding: const EdgeInsets.only(left: 24, bottom: 2),
      child: Text(
        op.indeterminate
            ? '· ${op.title} — ${op.step}'
            : '· ${op.title} — ${op.step} (${op.percent}%)',
        style: const TextStyle(fontSize: 10, color: AppColors.muted),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
