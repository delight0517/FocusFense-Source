import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/build_identity_service.dart';
import '../services/in_app_rebuild_actions.dart';
import '../services/windows_desktop_rebuild_service.dart';
import '../services/windows_rebuild_monitor.dart';
import '../theme/app_colors.dart';

/// 홈 화면용 — 최신 버전 빌드 버튼 (Windows).
class InAppRebuildPromoCard extends StatefulWidget {
  const InAppRebuildPromoCard({super.key});

  @override
  State<InAppRebuildPromoCard> createState() => _InAppRebuildPromoCardState();
}

class _InAppRebuildPromoCardState extends State<InAppRebuildPromoCard> {
  BuildIdentity? _running;
  SourceVersion? _source;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WindowsRebuildMonitor.instance.addListener(_onMon);
      _timer = Timer.periodic(
        const Duration(seconds: 12),
        (_) => unawaited(_refresh()),
      );
      unawaited(_refresh());
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (Platform.isWindows) {
      WindowsRebuildMonitor.instance.removeListener(_onMon);
    }
    super.dispose();
  }

  void _onMon() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final BuildIdentity r = await BuildIdentityService.instance.current();
    final SourceVersion? s =
        await WindowsDesktopRebuildService.readSourceVersion();
    if (!mounted) return;
    setState(() {
      _running = r;
      _source = s;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    if (WindowsRebuildMonitor.instance.isActive) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);
    if (_loading || _running == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox(
            height: 24,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
      );
    }

    final BuildIdentity r = _running!;
    final SourceVersion? s = _source;
    final bool sourceOk = s != null;
    final bool matches = s?.matchesRunning(
          runningVersion: r.version,
          runningBuildNumber: r.buildNumber,
        ) ??
        false;

    return Card(
      elevation: 0,
      color: AppColors.accent.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  matches ? Icons.check_circle : Icons.system_update_alt,
                  color: matches ? AppColors.success : AppColors.accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '앱 업데이트 (최신 버전 빌드)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _versionRow('지금 실행 중', 'v${r.version}+${r.buildNumber}', AppColors.ink),
            const SizedBox(height: 4),
            _versionRow(
              '빌드 대상',
              sourceOk ? 'v${s.display}' : '(소스 폴더 없음)',
              sourceOk
                  ? (matches ? AppColors.success : AppColors.accent)
                  : AppColors.warning,
            ),
            if (matches) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '✓ pubspec과 실행 빌드가 같습니다. 이미 최신이에요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ] else if (sourceOk) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '⬇ 새 버전을 다운로드·빌드할 수 있어요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => InAppRebuildActions.startRebuild(context),
              icon: Icon(matches ? Icons.refresh : Icons.download),
              label: Text(
                matches ? '최신 버전 다시 빌드' : '최신 버전 빌드·설치',
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '상단 바에서도 같은 버튼을 쓸 수 있어요. 빌드 로그는 「전체 복사」로 복사할 수 있습니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.3,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _versionRow(String label, String value, Color valueColor) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontFamily: 'Menlo',
            fontWeight: FontWeight.w700,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}
