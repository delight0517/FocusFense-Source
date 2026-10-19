import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/build_identity_service.dart';
import '../services/in_app_rebuild_actions.dart';
import '../services/windows_desktop_rebuild_service.dart';
import '../services/windows_rebuild_monitor.dart';
import '../theme/app_colors.dart';

/// Windows-only: Focus Fense's in-app update/rebuild entry point.
class WindowsSidebarRebuildButton extends StatefulWidget {
  const WindowsSidebarRebuildButton({super.key});

  @override
  State<WindowsSidebarRebuildButton> createState() =>
      _WindowsSidebarRebuildButtonState();
}

class _WindowsSidebarRebuildButtonState
    extends State<WindowsSidebarRebuildButton> {
  bool _busy = false;
  BuildIdentity? _running;
  SourceVersion? _source;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _loadVersions();
    }
  }

  Future<void> _loadVersions() async {
    final BuildIdentity running = await BuildIdentityService.instance.current();
    final SourceVersion? source =
        await WindowsDesktopRebuildService.readSourceVersion();
    if (!mounted) return;
    setState(() {
      _running = running;
      _source = source;
    });
  }

  Future<void> _run() async {
    if (!Platform.isWindows) return;
    setState(() => _busy = true);
    await InAppRebuildActions.startRebuild(context);
    if (!mounted) return;
    await _loadVersions();
    if (mounted) setState(() => _busy = false);
  }

  String _versionDetail() {
    final BuildIdentity? running = _running;
    final SourceVersion? source = _source;
    if (running == null) return '버전 확인 중';
    final String current = 'v${running.version}+${running.buildNumber}';
    if (source == null) return '현재 $current';
    return '$current -> v${source.display}';
  }

  @override
  Widget build(BuildContext context) {
    final bool active = _busy || WindowsRebuildMonitor.instance.isActive;
    return Tooltip(
      message: 'Focus Fense 전용 업데이트: 이 앱을 새 빌드로 교체하고 다시 실행',
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: active ? null : _run,
          icon: active
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update_alt, size: 18),
          label: _UpdateButtonLabel(
            title: WindowsRebuildMonitor.instance.isActive
                ? '업데이트 중...'
                : _busy
                ? '시작 중...'
                : '6 VPN 업데이트',
            detail: _versionDetail(),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: MacColors.ink,
            side: BorderSide(color: MacColors.hairline),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
        ),
      ),
    );
  }
}

class _UpdateButtonLabel extends StatelessWidget {
  const _UpdateButtonLabel({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.black,
            fontSize: 10,
            fontFamily: 'Menlo',
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
