import 'dart:io';

import 'package:flutter/material.dart';

import '../router/app_router.dart';
import 'automated_browser_handoff_service.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart';
import 'easy_setup_bulletproof_prefs.dart';
import 'protected_browser_realtime_guard_service.dart';

/// On app launch: scan every Chrome/Edge/Firefox `.lnk` and repoint to protected VBS launchers.
final class ChromeShortcutBootRepairService {
  ChromeShortcutBootRepairService._();
  static final ChromeShortcutBootRepairService instance =
      ChromeShortcutBootRepairService._();

  static DateTime? _lastRun;
  static const Duration kCooldown = Duration(minutes: 3);

  Future<ShortcutBootRepairResult> runOnLaunch({bool force = false}) async {
    if (!Platform.isWindows) {
      return const ShortcutBootRepairResult(
        skipped: true,
        message: 'Windows 전용',
      );
    }
    if (!await EasySetupBulletproofPrefs.instance.hijackShortcuts()) {
      return const ShortcutBootRepairResult(
        skipped: true,
        message: '바로가기 보호 꺼짐',
      );
    }
    final DateTime now = DateTime.now();
    if (!force && _lastRun != null && now.difference(_lastRun!) < kCooldown) {
      return const ShortcutBootRepairResult(skipped: true, message: '최근 점검됨');
    }
    _lastRun = now;

    final String? folder =
        await ChromeExtensionPayloadService.ensureStablePayload();
    if (folder == null) {
      return const ShortcutBootRepairResult(
        ok: false,
        message: '확장 파일 없음 — 먼저 앱 초기 설정을 완료하세요.',
      );
    }

    await ChromeLoadExtensionLauncher.install(extensionFolder: folder);

    final ShortcutHijackResult hijack = await ChromeShortcutHijackService
        .instance
        .apply(extensionFolder: folder, force: true);

    await ProtectedBrowserRealtimeGuardService.instance.runOnce();

    final BrowserProcessProbe probe =
        await AutomatedBrowserHandoffService.probeBrowsers();
    if (probe.chromeUnprotected) {
      await AutomatedBrowserHandoffService.instance.runZeroTouch(
        reason: 'boot_shortcut_repair',
        force: true,
      );
    }

    String message;
    if (hijack.patchedCount > 0) {
      message = 'Chrome·Edge·Firefox 바로가기 ${hijack.patchedCount}개 → 보호 실행기로 수정';
    } else if (probe.chromeUnprotected) {
      message = '순정 Chrome 창 감지 → 보호 모드로 전환 시도';
    } else {
      message = '바로가기 점검 완료 (이미 보호 모드)';
    }

    return ShortcutBootRepairResult(
      ok: hijack.ok,
      patchedCount: hijack.patchedCount,
      chromeWasUnprotected: probe.chromeUnprotected,
      message: message,
    );
  }

  void notifyUser(ShortcutBootRepairResult result) {
    if (result.skipped) return;
    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;

    final bool highlight =
        result.patchedCount > 0 || result.chromeWasUnprotected;
    // A no-op check in an already protected state is expected background
    // maintenance; don't interrupt the user with a completion toast.
    if (!highlight && result.ok) return;

    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        duration: Duration(seconds: result.patchedCount > 0 ? 14 : 8),
        backgroundColor: result.patchedCount > 0
            ? const Color(0xFF0F6E56)
            : null,
        content: Text(
          result.patchedCount > 0
              ? '🔧 ${result.message}\n'
                    '이제 작업 표시줄·시작 메뉴 Chrome을 눌러도 확장이 붙습니다.'
              : result.chromeWasUnprotected
              ? '🔄 ${result.message}'
              : '⚠️ ${result.message}',
        ),
      ),
    );
  }
}

final class ShortcutBootRepairResult {
  const ShortcutBootRepairResult({
    this.ok = true,
    this.skipped = false,
    this.patchedCount = 0,
    this.chromeWasUnprotected = false,
    this.message = '',
  });

  final bool ok;
  final bool skipped;
  final int patchedCount;
  final bool chromeWasUnprotected;
  final String message;
}
