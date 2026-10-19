import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/quick_block_user_bundle.dart';
import '../services/quick_block_controller.dart';
import '../services/quick_block_prefs_store.dart';
import '../services/quick_block_service.dart';
import '../services/quick_block_session_service.dart';
import '../theme/app_colors.dart';

/// One-tap global domain bundles (스케줄과 별개). Shown above the bottom nav
/// on phone, or in the Mac/Windows sidebar directly above the Home row.
class QuickBlockDock extends StatefulWidget {
  const QuickBlockDock({super.key, required this.macLayout});

  final bool macLayout;

  @override
  State<QuickBlockDock> createState() => _QuickBlockDockState();
}

class _QuickBlockDockState extends State<QuickBlockDock> {
  bool _busy = false;
  int _active = 0;
  bool _showGames = true;
  bool _showMedia = true;
  List<QuickBlockUserBundle> _userBundles = <QuickBlockUserBundle>[];
  QuickBlockSession? _session;
  int _blockHours = QuickBlockPrefsStore.kDefaultDurationHours;

  @override
  void initState() {
    super.initState();
    QuickBlockController.instance.addListener(_onBump);
    QuickBlockSessionService.instance.sessionTick.addListener(_onBump);
    unawaited(_reload());
  }

  @override
  void dispose() {
    QuickBlockController.instance.removeListener(_onBump);
    QuickBlockSessionService.instance.sessionTick.removeListener(_onBump);
    super.dispose();
  }

  void _onBump() {
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final int n = await QuickBlockService.instance
        .activeQuickBlockDomainCount();
    final Set<String> hidden = await QuickBlockPrefsStore.instance
        .hiddenCatalogIds();
    final bool g =
        !hidden.contains(QuickBlockCatalog.games.id) &&
        await QuickBlockDockPrefs.showGames();
    final bool m =
        !hidden.contains(QuickBlockCatalog.media.id) &&
        await QuickBlockDockPrefs.showMedia();
    final List<QuickBlockUserBundle> user = await QuickBlockService.instance
        .userBundles();
    final QuickBlockSession? session = await QuickBlockSessionService.instance
        .activeSession();
    final int hours = await QuickBlockPrefsStore.instance
        .defaultDurationHours();
    if (mounted) {
      setState(() {
        _active = n;
        _showGames = g;
        _showMedia = m;
        _userBundles = user
            .where((QuickBlockUserBundle b) => b.enabled)
            .toList();
        _session = session;
        _blockHours = hours;
      });
    }
  }

  String _buttonLabel(String name) {
    final String dur = QuickBlockPrefsStore.formatBlockHoursLabel(_blockHours);
    return dur.isEmpty ? name : '$name · $dur';
  }

  Future<void> _startSession(String bundleId) async {
    if (_busy) return;
    if (_session != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이미 퀵 블록 세션이 켜져 있어요. 먼저 해제하세요.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final QuickBlockSession? s = await QuickBlockSessionService.instance
          .startWithBundles(<String>[bundleId]);
      if (!mounted) return;
      final String label = _labelFor(bundleId);
      if (s != null) {
        final int h = await QuickBlockPrefsStore.instance
            .defaultDurationHours();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('퀵 블록「$label」· ${h}시간 — 왼쪽 아래 「적용」으로 DNS 잠금'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _labelFor(String bundleId) {
    final QuickBlockBundle? c = QuickBlockCatalog.byId(bundleId);
    if (c != null) return c.label;
    for (final QuickBlockUserBundle b in _userBundles) {
      if (b.id == bundleId) return b.label;
    }
    return bundleId;
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final QuickBlockClearOutcome outcome = await QuickBlockSessionService
          .instance
          .tryClearSession();
      if (!mounted) return;
      switch (outcome) {
        case QuickBlockClearOutcome.policyLocked:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('잠금 모드에서는 퀵 블록 해제가 막혀 있어요.')),
          );
        case QuickBlockClearOutcome.cancelDelayPending:
          final Duration? wait = _session?.cancelCountdownRemaining;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                wait == null
                    ? '해제 지연 중입니다. 잠시 후 다시 눌러 주세요.'
                    : '해제까지 ${QuickBlockSessionService.formatDuration(wait)} 남음',
              ),
            ),
          );
        case QuickBlockClearOutcome.notActive:
          final int n = await QuickBlockService.instance.clearAllQuickBlocks();
          if (n < 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('잠금 모드에서는 해제할 수 없어요.')),
            );
          } else if (n > 0) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('퀵 블록 규칙 $n개 해제')));
          }
        case QuickBlockClearOutcome.cleared:
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('퀵 블록 세션을 해제했습니다.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _sessionSubtitle() {
    final QuickBlockSession? s = _session;
    if (s == null) return null;
    final Duration left = s.remaining;
    if (s.releaseRequired) {
      return left == Duration.zero
          ? 'Chrome · Aside 차단 중 · 확장 출시 확인 대기'
          : '최소 ${QuickBlockSessionService.formatDuration(left)} · 이후 출시 확인까지 차단';
    }
    final Duration? cancelWait = s.cancelCountdownRemaining;
    final String until = QuickBlockSessionService.formatDuration(left);
    if (cancelWait != null && cancelWait > Duration.zero) {
      return '남은 시간 $until · 해제 가능까지 ${QuickBlockSessionService.formatDuration(cancelWait)}';
    }
    return '남은 시간 $until · 해제 가능';
  }

  String _clearButtonLabel() {
    final QuickBlockSession? s = _session;
    if (s == null) {
      return _active > 0 ? '퀵 블록 해제 ($_active)' : '퀵 블록 해제';
    }
    final Duration? wait = s.cancelCountdownRemaining;
    if (wait != null && wait > Duration.zero) {
      final int m = wait.inMinutes;
      final int sec = wait.inSeconds.remainder(60);
      return '해제 ${m}분 ${sec}초';
    }
    return '퀵 블록 해제';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color bg = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: widget.macLayout ? 0.55 : 0.92,
    );
    final bool hasButtons = _showGames || _showMedia || _userBundles.isNotEmpty;

    final List<Widget> chipChildren = <Widget>[
      if (_showGames)
        FilledButton.tonal(
          onPressed: _busy || _session != null
              ? null
              : () => unawaited(_startSession(QuickBlockCatalog.games.id)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(_buttonLabel(QuickBlockCatalog.games.label)),
        ),
      if (_showMedia)
        FilledButton.tonal(
          onPressed: _busy || _session != null
              ? null
              : () => unawaited(_startSession(QuickBlockCatalog.media.id)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(_buttonLabel(QuickBlockCatalog.media.label)),
        ),
      for (final QuickBlockUserBundle b in _userBundles)
        FilledButton.tonal(
          onPressed: _busy || _session != null
              ? null
              : () => unawaited(_startSession(b.id)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(_buttonLabel(b.label)),
        ),
      TextButton(
        onPressed: _busy || (_active == 0 && _session == null)
            ? null
            : () => unawaited(_clear()),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.danger,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        child: Text(_clearButtonLabel()),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.tune, size: 18),
        tooltip: '퀵 블록 설정',
        onPressed: () => context.push('/settings/quick-block'),
      ),
    ];

    final Widget chips = !hasButtons
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '설정 → 퀵 블록에서 프리셋·내 블록을 추가하세요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
              ),
            ),
          )
        : Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: chipChildren,
          );

    final String? sub = _sessionSubtitle();

    final Widget body = widget.macLayout
        ? Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '퀵 블록',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: MacColors.mutedInk,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                if (sub != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    sub,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                chips,
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.bolt,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '퀵 블록 (시간 제한 · 해제 지연)',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (_busy)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                if (sub != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    sub,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                chips,
              ],
            ),
          );

    return Material(color: bg, child: body);
  }
}
