import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/apply_activation_report.dart';
import '../services/block_sync_service.dart';
import '../services/mac_system_block_service.dart';
import '../services/windows_apply_status_service.dart';
import '../theme/app_colors.dart';
import 'apply_activation_dialog.dart';

/// Apply control — opens UAC dialog with visible progress.
///
/// Two render modes:
/// * `inline: false` (default, mobile) — floats bottom-left over page content
///   via [Positioned], sized as a normal FAB-ish button.
/// * `inline: true` (Windows/Mac desktop sidebar) — renders as a compact
///   chip meant to sit directly in the sidebar footer next to the auto-save
///   status chip, not floating over content. Added because the floating
///   version covered part of the full-screen chat page's input field.
class HostsApplyFab extends StatefulWidget {
  const HostsApplyFab({super.key, this.bottomInset = 72, this.inline = false});

  final double bottomInset;
  final bool inline;

  @override
  State<HostsApplyFab> createState() => _HostsApplyFabState();
}

class _HostsApplyFabState extends State<HostsApplyFab> {
  bool _busy = false;
  bool? _browserOk;
  Timer? _pendingPromptTimer;
  DateTime? _lastPendingPromptAt;
  bool _pendingPromptOpen = false;

  static const Duration _kPendingPromptDelay = Duration(milliseconds: 900);
  static const Duration _kPendingPromptMinGap = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    BlockSyncService.instance.hostsApplyPending.addListener(_onPendingChanged);
    _refreshBrowserState();
  }

  @override
  void dispose() {
    BlockSyncService.instance.hostsApplyPending.removeListener(
      _onPendingChanged,
    );
    _pendingPromptTimer?.cancel();
    super.dispose();
  }

  void _onPendingChanged() {
    if (!mounted || _busy || _pendingPromptOpen) return;
    if (!BlockSyncService.instance.hostsApplyPending.value) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastPendingPromptAt;
    if (last != null && now.difference(last) < _kPendingPromptMinGap) {
      return;
    }
    _pendingPromptTimer?.cancel();
    _pendingPromptTimer = Timer(_kPendingPromptDelay, () {
      if (!mounted ||
          _busy ||
          _pendingPromptOpen ||
          !BlockSyncService.instance.hostsApplyPending.value) {
        return;
      }
      unawaited(_showPendingApplyPrompt());
    });
  }

  Future<void> _showPendingApplyPrompt() async {
    _pendingPromptOpen = true;
    _lastPendingPromptAt = DateTime.now();
    try {
      final bool? apply = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (BuildContext ctx) => AlertDialog(
          icon: const Icon(
            Icons.admin_panel_settings,
            color: AppColors.warning,
            size: 34,
          ),
          title: const Text('새 차단 규칙을 적용하려면 승인이 필요합니다'),
          content: const Text(
            '방금 추가한 URL/스케줄 규칙은 저장되었습니다.\n\n'
            '이제 실제 브라우저와 hosts/DNS까지 막으려면 Windows 승인 창에서 '
            '「예」를 눌러야 합니다. 지금 적용을 누르면 승인 안내와 진행 상황을 보여드립니다.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('나중에'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.admin_panel_settings),
              onPressed: () => Navigator.of(ctx).pop(true),
              label: const Text('지금 적용하고 예 누르기'),
            ),
          ],
        ),
      );
      if (apply == true && mounted) {
        await _apply();
      }
    } finally {
      _pendingPromptOpen = false;
    }
  }

  Future<void> _refreshBrowserState() async {
    // Widget tests run on Windows too, but must not spawn real registry/process
    // probes. Those child-process stream timers are owned by the OS and cannot
    // be drained by Flutter's fake-async test binding.
    if (!Platform.isWindows || Platform.environment['FLUTTER_TEST'] == 'true') {
      return;
    }
    final bool ok =
        await WindowsApplyStatusService.isBrowserProtectionSufficient();
    if (mounted) setState(() => _browserOk = ok);
  }

  Future<void> _apply() async {
    if (_busy) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    ApplyActivationReport? report;
    try {
      if (Platform.isWindows) {
        await showApplyActivationDialog(
          context,
          runApply: (onPhase) async {
            report = await WindowsApplyStatusService.instance.applyAndVerify(
              onPhase: onPhase,
            );
            return report!;
          },
        );
      } else {
        await showApplyActivationDialog(
          context,
          runApply: (onPhase) async {
            onPhase?.call('macOS hosts 적용 중…');
            final MacBlockResult r = await MacSystemBlockService.instance
                .activate();
            report = ApplyActivationReport(
              success: r.status == MacBlockStatus.success,
              steps: <ApplyActivationStep>[
                ApplyActivationStep(
                  id: 'hosts',
                  label: '/etc/hosts',
                  ok: r.status == MacBlockStatus.success,
                  detail: r.message ?? r.status.name,
                ),
              ],
              summary: r.status == MacBlockStatus.success
                  ? '시스템 차단이 활성화되었습니다.'
                  : '적용 실패 또는 취소',
            );
            return report!;
          },
        );
      }
      if (!mounted || report == null) return;
      await _refreshBrowserState();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            report!.success
                ? report!.summary.split('\n').first
                : '적용 결과를 확인하세요 — ${report!.summary.split('\n').first}',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS && !Platform.isWindows) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<bool>(
      valueListenable: BlockSyncService.instance.hostsApplyPending,
      builder: (BuildContext context, bool pending, Widget? _) {
        final Widget button = widget.inline
            ? _HostsApplyChip(
                pending: pending,
                busy: _busy,
                browserOk: _browserOk,
                onApply: _apply,
              )
            : _HostsApplyButton(
                pending: pending,
                busy: _busy,
                browserOk: _browserOk,
                onApply: _apply,
              );
        if (widget.inline) return button;
        return Positioned(left: 12, bottom: widget.bottomInset, child: button);
      },
    );
  }
}

class _HostsApplyButton extends StatelessWidget {
  const _HostsApplyButton({
    required this.pending,
    required this.busy,
    required this.browserOk,
    required this.onApply,
  });

  final bool pending;
  final bool busy;
  final bool? browserOk;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final bool protected = browserOk == true && !pending;
    final Color tone = pending
        ? AppColors.warning
        : (protected ? AppColors.success : AppColors.accent);
    final String label = busy
        ? '적용 중…'
        : (pending ? '승인 필요' : (protected ? 'URL 차단 적용됨' : '적용 열기'));
    final IconData icon = busy
        ? Icons.hourglass_top
        : (pending
              ? Icons.admin_panel_settings
              : (protected ? Icons.verified_user : Icons.play_arrow_rounded));

    return Material(
      elevation: pending || !protected ? 4 : 1,
      borderRadius: BorderRadius.circular(12),
      color: pending
          ? AppColors.warning.withValues(alpha: 0.15)
          : (protected
                ? AppColors.success.withValues(alpha: 0.12)
                : Theme.of(context).colorScheme.surfaceContainerHighest),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: busy ? null : onApply,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (busy)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: tone),
                )
              else
                Icon(icon, size: 20, color: tone),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: pending ? AppColors.warning : null,
                ),
              ),
              if (pending) ...<Widget>[
                const SizedBox(width: 6),
                Text(
                  '눌러서 예',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    color: AppColors.warning.withValues(alpha: 0.95),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact sidebar-footer version — same tap behaviour as [_HostsApplyButton]
/// but sized like the auto-save status chip next to it, not a floating FAB.
/// Only rendered at all when there's something to say (pending approval, or
/// not yet protected) — once fully applied it collapses to nothing so it
/// doesn't add permanent clutter next to the auto-save chip.
class _HostsApplyChip extends StatelessWidget {
  const _HostsApplyChip({
    required this.pending,
    required this.busy,
    required this.browserOk,
    required this.onApply,
  });

  final bool pending;
  final bool busy;
  final bool? browserOk;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final bool protected = browserOk == true && !pending;
    if (protected && !busy) return const SizedBox.shrink();

    final Color tone = pending ? AppColors.warning : AppColors.accent;
    final String label = busy ? '적용 중…' : (pending ? '승인 필요 — 눌러서 예' : '적용 열기');
    final IconData icon = busy
        ? Icons.hourglass_top
        : (pending ? Icons.admin_panel_settings : Icons.play_arrow_rounded);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: busy ? null : onApply,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tone.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (busy)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.7,
                    valueColor: AlwaysStoppedAnimation<Color>(tone),
                  ),
                )
              else
                Icon(icon, size: 12, color: tone),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tone,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
