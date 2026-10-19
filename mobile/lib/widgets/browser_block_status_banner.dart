import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/block_activity_log_service.dart';
import '../services/browser_block_enforcement_health_service.dart';
import '../services/browser_one_tap_service.dart';
import '../theme/app_colors.dart';

/// Slim one-line alert — only when plain Chrome is running (no duplicate gap banners).
class BrowserBlockStatusBanner extends StatefulWidget {
  const BrowserBlockStatusBanner({super.key});

  @override
  State<BrowserBlockStatusBanner> createState() =>
      _BrowserBlockStatusBannerState();
}

class _BrowserBlockStatusBannerState extends State<BrowserBlockStatusBanner> {
  BrowserEnforcementHealth? _health;
  bool _loading = true;
  bool _opening = false;
  VoidCallback? _revisionListener;

  @override
  void initState() {
    super.initState();
    _revisionListener = () => unawaited(_refresh(force: true));
    BlockActivityLogService.instance.revision.addListener(_revisionListener!);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    if (_revisionListener != null) {
      BlockActivityLogService.instance.revision
          .removeListener(_revisionListener!);
    }
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    if (!Platform.isWindows) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final BrowserEnforcementHealth h =
        await BrowserBlockEnforcementHealthService.instance.analyze(
      force: force,
    );
    if (!mounted) return;
    setState(() {
      _health = h;
      _loading = false;
    });
  }

  Future<void> _switchChrome() async {
    setState(() => _opening = true);
    try {
      final BrowserOneTapResult r =
          await BrowserOneTapService.openProtectedChrome(repair: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(r.userMessage),
            duration: const Duration(seconds: 7),
          ),
        );
      }
      await _refresh(force: true);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows || _loading) return const SizedBox.shrink();
    final BrowserEnforcementHealth? h = _health;
    if (h == null || !h.chromeUnprotectedRunning) {
      return const SizedBox.shrink();
    }

    return Material(
      color: AppColors.danger.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          children: <Widget>[
            Icon(Icons.warning_amber_rounded,
                color: AppColors.danger, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '일반 Chrome — 유튜브 차단 안 됨',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.danger,
                    ),
              ),
            ),
            FilledButton.tonal(
              onPressed: _opening ? null : _switchChrome,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                backgroundColor: AppColors.danger.withValues(alpha: 0.14),
                foregroundColor: AppColors.danger,
              ),
              child: _opening
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('보호 Chrome으로 전환'),
            ),
          ],
        ),
      ),
    );
  }
}
