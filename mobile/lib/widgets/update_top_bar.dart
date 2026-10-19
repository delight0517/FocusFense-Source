import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import '../services/build_identity_service.dart';
import '../services/in_app_rebuild_actions.dart';
import '../services/windows_desktop_rebuild_service.dart';
import '../services/windows_rebuild_monitor.dart';
import '../theme/app_colors.dart';

/// Full-width banner at the top of the app that surfaces:
///   * the **running build** (`v1.0.0+60` from PackageInfo)
///   * the **source build** read from `mobile/pubspec.yaml`
///   * a prominent **"새 버전 받기"** button when they differ, OR a
///     "✓ 최신 버전" pill when they match
///   * a live **progress strip** during rebuild, fed by [WindowsRebuildMonitor]
///
/// Windows desktop only — on other platforms this widget is invisible (returns
/// [SizedBox.shrink]) so the same shell tree works everywhere.
class UpdateTopBar extends StatefulWidget {
  const UpdateTopBar({super.key, this.macStyle = true});

  /// Mac shell uses [MacColors]; mobile/iPhone shell uses [AppColors].
  final bool macStyle;

  @override
  State<UpdateTopBar> createState() => _UpdateTopBarState();
}

class _UpdateTopBarState extends State<UpdateTopBar> {
  BuildIdentity? _running;
  SourceVersion? _source;
  bool _loading = true;
  bool _starting = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WindowsRebuildMonitor.instance.addListener(_onMonitorChange);
      unawaited(_refresh());
      // Poll source pubspec every ~15s in case the user edits it externally
      // (typical dev workflow: edit pubspec → bump build number → rebuild).
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(_refresh()),
      );
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    if (Platform.isWindows) {
      WindowsRebuildMonitor.instance.removeListener(_onMonitorChange);
    }
    super.dispose();
  }

  void _onMonitorChange() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!Platform.isWindows) return;
    final BuildIdentity running =
        await BuildIdentityService.instance.current();
    final SourceVersion? src =
        await WindowsDesktopRebuildService.readSourceVersion();
    if (!mounted) return;
    setState(() {
      _running = running;
      _source = src;
      _loading = false;
    });
  }

  Future<void> _start() async {
    if (!Platform.isWindows || _starting) return;
    setState(() => _starting = true);
    await InAppRebuildActions.startRebuild(context);
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    final WindowsRebuildMonitor mon = WindowsRebuildMonitor.instance;
    final bool building = mon.isActive;
    final Color bg = widget.macStyle ? MacColors.surface : AppColors.surface;
    final Color ink = widget.macStyle ? MacColors.ink : AppColors.ink;
    final Color muted = widget.macStyle ? MacColors.mutedInk : AppColors.muted;
    final Color hairline =
        widget.macStyle ? MacColors.hairline : const Color(0xFFE2E8F0);
    final Color accent = widget.macStyle ? MacColors.primary : AppColors.accent;

    if (building) {
      return _BuildingBar(
        macStyle: widget.macStyle,
        message: mon.displayMessage,
        progress: mon.displayProgress,
        tail: mon.consoleTail,
      );
    }
    if (_loading) {
      return Container(
        height: 38,
        color: bg,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final BuildIdentity? r = _running;
    final SourceVersion? s = _source;
    if (r == null) {
      return Container(
        height: 38,
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        child: Text(
          '버전 정보를 불러오는 중…',
          style: TextStyle(color: muted, fontSize: 12),
        ),
      );
    }
    final bool sourceFound = s != null;
    final bool matches = sourceFound &&
        s.matchesRunning(
          runningVersion: r.version,
          runningBuildNumber: r.buildNumber,
        );

    // 최신 빌드면 상단 바 숨김 — 설정에서만 재빌드.
    if (matches) return const SizedBox.shrink();

    final String runningLabel = 'v${r.version}+${r.buildNumber}';
    final String targetLabel =
        sourceFound ? 'v${s.display}' : '(소스 폴더 못 찾음)';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: hairline, width: 1)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(Icons.system_update_alt, size: 18, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 2,
                children: <Widget>[
                  Text(
                    '현재  ',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  Text(
                    runningLabel,
                    style: TextStyle(
                      color: ink,
                      fontSize: 13,
                      fontFamily: 'Menlo',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Icon(Icons.arrow_forward, size: 14, color: muted),
                  Text(
                    '대상  ',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  Text(
                    targetLabel,
                    style: TextStyle(
                      color: accent,
                      fontSize: 13,
                      fontFamily: 'Menlo',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (sourceFound)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '업데이트 사용 가능',
                        style: TextStyle(
                          color: accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (sourceFound)
              FilledButton.icon(
                onPressed: _starting ? null : _start,
                icon: _starting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download, size: 16),
                label: Text(_starting ? '시작 중…' : '최신 버전 빌드'),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: widget.macStyle
                      ? MacColors.ink
                      : Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BuildingBar extends StatelessWidget {
  const _BuildingBar({
    required this.macStyle,
    required this.message,
    required this.progress,
    required this.tail,
  });

  final bool macStyle;
  final String message;
  final double? progress;
  final List<String> tail;

  @override
  Widget build(BuildContext context) {
    final Color bg = macStyle ? MacColors.surface : AppColors.surface;
    final Color ink = macStyle ? MacColors.ink : AppColors.ink;
    final Color accent = macStyle ? MacColors.primary : AppColors.accent;
    final Color hairline =
        macStyle ? MacColors.hairline : const Color(0xFFE2E8F0);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: hairline, width: 1)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '⬇ 다운로드·빌드 중 — 앱을 닫지 마세요',
                    style: TextStyle(
                      color: ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (progress != null)
                  Text(
                    '${(progress!.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontFamily: 'Menlo',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress?.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: hairline,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
            if (tail.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              // Just the very last line — top-bar is height-constrained.
              // The full-screen overlay has the scrollable console box.
              Text(
                tail.last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: accent,
                  fontSize: 10,
                  fontFamily: 'Menlo',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
