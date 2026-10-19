import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../router/app_router.dart';
import 'app_force_restart_notice_service.dart';
import 'windows_watchdog_service.dart';

/// Maps macOS “menu bar extra / keep in background” intent to the Windows
/// notification area (system tray): optional hide-on-close + tray menu.
final class WindowsTrayController with TrayListener {
  WindowsTrayController._();
  static final WindowsTrayController instance = WindowsTrayController._();

  bool _ready = false;

  static bool get _eligible =>
      Platform.isWindows && Platform.environment['FLUTTER_TEST'] != 'true';

  Future<void> init() async {
    if (!_eligible || _ready) return;
    try {
      await trayManager.setIcon('assets/app_icon.ico');
      await trayManager.setToolTip(
        'Focus Fense — 트레이에서 종료. 재실행 워치독이 켜져 있으면 작업 관리자로 끈 뒤에도 다시 켜질 수 있습니다.',
      );
      await _installMenu();
      trayManager.addListener(this);
      _ready = true;
    } catch (e, st) {
      debugPrint('WindowsTrayController.init failed: $e\n$st');
    }
  }

  Future<void> _installMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: <MenuItem>[
          MenuItem(
            key: 'show',
            label: '창 보이기',
            onClick: (_) => showMainWindow(),
          ),
          MenuItem(
            key: 'hide',
            label: '트레이로 숨기기',
            onClick: (_) => hideMainWindow(),
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'quit',
            label: '종료',
            onClick: (_) {
              unawaited(quitApp());
            },
          ),
        ],
      ),
    );
  }

  Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hideMainWindow() async {
    await windowManager.hide();
  }

  Future<void> quitApp() async {
    if (Platform.isWindows && WindowsWatchdogService.instance.isSupported) {
      if (await WindowsWatchdogService.instance.isInstalled()) {
        final BuildContext? ctx = appRootNavigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          final String? choice = await showDialog<String>(
            context: ctx,
            barrierDismissible: false,
            builder: (BuildContext c) => AlertDialog(
              title: const Text('앱 종료'),
              content: const Text(
                '재실행 워치독(작업 스케줄러)이 켜져 있습니다.\n\n'
                '• 「그냥 종료」— 프로세스만 종료되며, 최대 '
                '${WindowsWatchdogService.kIntervalMinutes}분 안에 자동으로 다시 켜질 수 있습니다.\n'
                '• 「워치독 끄고 종료」— 재실행을 멈춘 뒤 완전히 종료합니다.\n\n'
                '참고: hosts(DNS) 차단은 보통 그대로 남지만, 브라우저 확장·사용량 집계는 앱이 켜져 있을 때만 동작합니다.',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(c, 'cancel'),
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(c, 'quit'),
                  child: const Text('그냥 종료'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, 'off_quit'),
                  child: const Text('워치독 끄고 종료'),
                ),
              ],
            ),
          );
          if (choice == null || choice == 'cancel') {
            return;
          }
          if (choice == 'off_quit') {
            await WindowsWatchdogService.instance.uninstall();
          }
        }
      }
    }
    // User-initiated quit (even "그냥 종료" with watchdog on, which respawns) is
    // a GRACEFUL exit — mark it so the watchdog's restart isn't reported as a
    // force-kill recovery.
    AppForceRestartNoticeService.instance.markCleanExit();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseUp() {
    unawaited(showMainWindow());
  }
}
