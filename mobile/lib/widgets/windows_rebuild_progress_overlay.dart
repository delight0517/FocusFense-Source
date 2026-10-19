import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../router/app_router.dart';
import '../models/windows_rebuild_status.dart';
import '../services/build_identity_service.dart';
import '../services/windows_desktop_rebuild_service.dart';
import '../services/rebuild_phase_guide.dart';
import '../services/windows_rebuild_monitor.dart';
import '../theme/app_colors.dart';

/// Full-screen progress while an in-app Windows rebuild runs.
class WindowsRebuildProgressOverlay extends StatefulWidget {
  const WindowsRebuildProgressOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<WindowsRebuildProgressOverlay> createState() =>
      _WindowsRebuildProgressOverlayState();
}

class _WindowsRebuildProgressOverlayState
    extends State<WindowsRebuildProgressOverlay> {
  BuildIdentity? _running;
  SourceVersion? _source;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      unawaited(_loadVersions());
    }
  }

  void _showLogCopiedSnackBar() {
    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      const SnackBar(
        content: Text('로그를 클립보드에 복사했습니다.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _loadVersions() async {
    final BuildIdentity r = await BuildIdentityService.instance.current();
    final SourceVersion? s =
        await WindowsDesktopRebuildService.readSourceVersion();
    if (!mounted) return;
    setState(() {
      _running = r;
      _source = s;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return widget.child;
    return ListenableBuilder(
      listenable: WindowsRebuildMonitor.instance,
      builder: (BuildContext context, Widget? _) {
        final bool active = WindowsRebuildMonitor.instance.isActive;
        if (!active) return widget.child;
        final WindowsRebuildStatus? st = WindowsRebuildMonitor.instance.status;
        final bool failed = st?.isFailed == true;
        final GuideCopy guide = WindowsRebuildMonitor.instance.phaseGuide;
        // `textDirection: ltr` on the Stack itself is the minimal fix —
        // ensures _resolvedAlignment doesn't ask Directionality.of(this
        // pre-MaterialApp context), which would return null.
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            textDirection: TextDirection.ltr,
            children: <Widget>[
              widget.child,
              Positioned.fill(
                child: Material(
                  color: Colors.black.withValues(alpha: 0.72),
                  child: SafeArea(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Card(
                          elevation: 8,
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  failed
                                      ? Icons.error_outline
                                      : Icons.system_update_alt,
                                  size: 48,
                                  color: failed
                                      ? Theme.of(context).colorScheme.error
                                      : AppColors.accent,
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent.withValues(
                                      alpha: failed ? 0.08 : 0.14,
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    failed
                                        ? '오류'
                                        : '단계 ${guide.step}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.accent,
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  failed ? guide.title : guide.title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 10),
                                if (_running != null)
                                  Text(
                                    '현재 v${_running!.version}+${_running!.buildNumber}'
                                    '${_source != null ? '  →  대상 v${_source!.display}' : ''}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          fontFamily: 'Menlo',
                                          fontWeight: FontWeight.w700,
                                        ),
                                    textAlign: TextAlign.center,
                                  ),
                                const SizedBox(height: 8),
                                Text(
                                  WindowsRebuildMonitor.instance.displayMessage,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        height: 1.4,
                                        fontWeight: FontWeight.w600,
                                      ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 10),
                                if (!failed)
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: <Widget>[
                                      const Icon(
                                        Icons.schedule,
                                        size: 14,
                                        color: AppColors.muted,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '예상: ${guide.eta}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: AppColors.muted,
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    ],
                                  ),
                                const SizedBox(height: 10),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withValues(alpha: 0.45),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        '지금 하는 일',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                              color: AppColors.muted,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        guide.how,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(height: 1.4),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 20),
                                if (!failed) ...<Widget>[
                                  LinearProgressIndicator(
                                    value: WindowsRebuildMonitor
                                        .instance.displayProgress,
                                    minHeight: 8,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  const SizedBox(height: 12),
                                  _LiveConsoleBox(
                                    lines: WindowsRebuildMonitor
                                        .instance.consoleTail,
                                    onCopied: _showLogCopiedSnackBar,
                                  ),
                                ],
                                if (failed) ...<Widget>[
                                  const SizedBox(height: 12),
                                  _LiveConsoleBox(
                                    lines: WindowsRebuildMonitor
                                        .instance.consoleTail,
                                    onCopied: _showLogCopiedSnackBar,
                                  ),
                                ],
                                const SizedBox(height: 16),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: failed
                                      ? FilledButton(
                                          onPressed:
                                              WindowsRebuildMonitor.instance
                                                  .cancel,
                                          child: const Text('닫기'),
                                        )
                                      : OutlinedButton.icon(
                                          onPressed:
                                              WindowsRebuildMonitor.instance
                                                  .cancel,
                                          icon: const Icon(Icons.close,
                                              size: 16),
                                          label: const Text('취소'),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: AppColors.muted,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Terminal-style box that shows the last N lines from
/// `WindowsRebuildMonitor.consoleTail`.
///
/// Behaviour:
/// • Auto-scrolls to bottom when new lines arrive.
/// • Freezes scroll position when the user manually scrolls up so they can read.
/// • Shows a "↓ 맨 아래로" jump button while the user is scrolled up.
/// • Wraps all lines in [SelectionArea] so text is selectable + copyable.
/// • Shows "전체 복사" header button to copy all lines in one click.
class _LiveConsoleBox extends StatefulWidget {
  const _LiveConsoleBox({required this.lines, this.onCopied});
  final List<String> lines;
  final VoidCallback? onCopied;

  @override
  State<_LiveConsoleBox> createState() => _LiveConsoleBoxState();
}

class _LiveConsoleBoxState extends State<_LiveConsoleBox> {
  final ScrollController _ctrl = ScrollController();

  /// True while the user has scrolled away from the bottom.
  bool _pinnedByUser = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_ctrl.hasClients) return;
    final double max = _ctrl.position.maxScrollExtent;
    final double pos = _ctrl.position.pixels;
    final bool atBottom = (max - pos) < 28;

    if (atBottom && _pinnedByUser) {
      // User has scrolled back to the bottom — resume auto-scroll.
      setState(() => _pinnedByUser = false);
    } else if (!atBottom && !_pinnedByUser) {
      // Only pin when the user deliberately scrolls upward.
      final ScrollDirection dir = _ctrl.position.userScrollDirection;
      if (dir == ScrollDirection.forward) {
        setState(() => _pinnedByUser = true);
      }
    }
  }

  void _scrollToBottom() {
    setState(() => _pinnedByUser = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_ctrl.hasClients) return;
      _ctrl.animateTo(
        _ctrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void didUpdateWidget(covariant _LiveConsoleBox old) {
    super.didUpdateWidget(old);
    // Only auto-scroll when the user has not pinned the view.
    if (_pinnedByUser) return;
    if (!_ctrl.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_ctrl.hasClients || _pinnedByUser) return;
      _ctrl.animateTo(
        _ctrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onScroll);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _copyAll() async {
    if (widget.lines.isEmpty) return;
    final String mon = WindowsRebuildMonitor.instance.displayMessage;
    final String header =
        '=== Focus Fense rebuild log ===\n$mon\n\n';
    await Clipboard.setData(
      ClipboardData(text: header + widget.lines.join('\n')),
    );
    widget.onCopied?.call();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> lines = widget.lines;
    const TextStyle logStyle = TextStyle(
      color: Color(0xFFD4DAE2),
      fontSize: 11,
      fontFamily: 'Menlo',
      height: 1.35,
    );
    const TextStyle mutedStyle = TextStyle(
      color: Color(0xFF8B95A1),
      fontSize: 10,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // ── Header row: label + "전체 복사" ──────────────────────────────
        Row(
          children: <Widget>[
            const Text(
              '빌드 출력',
              style: TextStyle(
                color: Color(0xFF8B95A1),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: lines.isEmpty ? null : _copyAll,
              icon: const Icon(Icons.copy_all, size: 14),
              label: const Text('전체 복사'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                foregroundColor: const Color(0xFFE8EAED),
                backgroundColor: const Color(0xFF2A3140),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),

        // ── Terminal box ─────────────────────────────────────────────────
        Container(
          width: double.infinity,
          height: 260,
          decoration: BoxDecoration(
            color: const Color(0xFF0F1115),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF2A2F36)),
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: lines.isEmpty
              ? const Center(
                  child: Text(
                    '빌드 출력을 기다리는 중…',
                    style: TextStyle(
                      color: Color(0xFF8B95A1),
                      fontSize: 11,
                      fontFamily: 'Menlo',
                    ),
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _ctrl,
                    itemCount: lines.length,
                    itemBuilder: (BuildContext ctx, int i) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(lines[i], style: logStyle),
                    ),
                  ),
                ),
        ),

        // ── "↓ 맨 아래로" jump button (visible only when user scrolled up) ─
        if (_pinnedByUser)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _scrollToBottom,
              icon: const Icon(Icons.keyboard_double_arrow_down, size: 13),
              label: const Text('맨 아래로', style: mutedStyle),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF8B95A1),
                minimumSize: Size.zero,
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
      ],
    );
  }
}
