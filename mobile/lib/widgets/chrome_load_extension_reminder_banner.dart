import 'dart:io';

import 'package:flutter/material.dart';

import '../services/build_identity_service.dart';
import '../services/chrome_extension_payload_service.dart';
import '../services/chrome_load_extension_launcher.dart';
import '../services/chrome_shortcut_hijack_service.dart';
import '../services/extension_guard_prefs.dart';
import '../theme/app_colors.dart';

/// Persistent reminder when Chrome/Edge rely on desktop `--load-extension` shortcuts.
class ChromeLoadExtensionReminderBanner extends StatefulWidget {
  const ChromeLoadExtensionReminderBanner({super.key});

  @override
  State<ChromeLoadExtensionReminderBanner> createState() =>
      _ChromeLoadExtensionReminderBannerState();
}

class _ChromeLoadExtensionReminderBannerState
    extends State<ChromeLoadExtensionReminderBanner> {
  bool _visible = false;
  String _buildLine = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!Platform.isWindows) return;
    final bool fallback =
        await ExtensionGuardPrefs.instance.isLoadExtensionFallback();
    final bool installed = await ChromeLoadExtensionLauncher.isInstalled();
    if (!mounted) return;
    if (!fallback && !installed) return;
    final String build = await BuildIdentityService.instance.shortUiLine();
    if (!mounted) return;
    setState(() {
      _visible = true;
      _buildLine = build;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Material(
      color: AppColors.accent.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.desktop_windows_outlined, color: AppColors.accent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Chrome·Edge·Firefox — 일반 아이콘 = 보호 브라우저',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '작업 표시줄·시작 메뉴의 브라우저 아이콘을 누르면 깜빡임 없이 보호 모드로 열립니다. '
                    '앱이 백그라운드에서 바로가기를 유지합니다.',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                  ),
                  if (_buildLine.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      _buildLine,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () async {
                final String? folder =
                    await ChromeExtensionPayloadService.ensureStablePayload();
                if (folder != null) {
                  await ChromeShortcutHijackService.instance.apply(
                    extensionFolder: folder,
                    force: true,
                  );
                }
                await ChromeLoadExtensionLauncher.launchChrome();
              },
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              child: const Text('바로가기 재연결'),
            ),
          ],
        ),
      ),
    );
  }
}
