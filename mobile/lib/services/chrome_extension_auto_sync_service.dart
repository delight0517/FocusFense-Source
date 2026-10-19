import 'dart:io';

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'chrome_extension_identity.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_extension_version.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart';
import 'extension_rules_snapshot_service.dart';
import 'tier_enforcement_service.dart';
import 'windows_chrome_extension_registry_native.dart';
import 'windows_extension_guard_service.dart';
import 'windows_extension_self_heal_service.dart';

/// Keeps LOCALAPPDATA extension + launchers at the latest bundled version.
final class ChromeExtensionAutoSyncService {
  ChromeExtensionAutoSyncService._();
  static final ChromeExtensionAutoSyncService instance =
      ChromeExtensionAutoSyncService._();

  static const Duration kCooldown = Duration(minutes: 6);
  DateTime? _lastRun;
  ChromeExtensionSyncResult? _lastResult;

  Future<ChromeExtensionSyncResult> syncIfNeeded({
    bool force = false,
    String reason = 'auto',
  }) async {
    if (!Platform.isWindows) {
      return const ChromeExtensionSyncResult(ok: false, message: 'Windows 전용');
    }
    final DateTime now = DateTime.now();
    if (!force && _lastRun != null && now.difference(_lastRun!) < kCooldown) {
      return ChromeExtensionSyncResult(
        ok: _lastResult?.ok ?? false,
        message: _lastResult?.message ?? '이전 동기화 미완료 · 실제 차단 확인 필요',
        skipped: true,
      );
    }

    _lastRun = now;
    _lastResult = null;
    final String bundledVer = await ChromeExtensionVersion.bundled();
    final String? installedVer = await ChromeExtensionVersion.installed();
    final bool stale = installedVer == null || installedVer != bundledVer;

    String? folder = await ChromeExtensionPayloadService.ensureStablePayload();
    if (stale || folder == null) {
      folder = await ChromeExtensionPayloadService.exportBundledTo(
        ChromeLoadExtensionLauncher.stableChromeExtDir,
      );
      AppLogger.instance.info(
        'chrome_auto_sync: bundled $bundledVer '
        '(was $installedVer) reason=$reason',
      );
    }
    if (folder == null) {
      return const ChromeExtensionSyncResult(ok: false, message: '확장 파일 복사 실패');
    }

    final String ver = await ChromeExtensionVersion.bundled();
    await WindowsChromeExtensionRegistryNative.registerChromeAndEdge(
      extensionId: ChromeExtensionIdentity.extensionId,
      extensionFolder: folder,
      version: ver,
    );

    await ChromeLoadExtensionLauncher.install(extensionFolder: folder);
    await ExtensionRulesSnapshotService.instance.writeToChromePayload(
      sourceFolder: folder,
    );

    final bool policyBlocked =
        !await WindowsChromeExtensionRegistryNative.canWriteChromePolicies();
    if (policyBlocked) {
      await WindowsExtensionSelfHealService.instance.runSelfHeal(
        attemptElevated: false,
        userInitiated: false,
        chromeSourceOverride: folder,
      );
    }

    final ShortcutHijackResult hijack = await ChromeShortcutHijackService
        .instance
        .apply(extensionFolder: folder, force: force || policyBlocked || stale);

    await TierEnforcementService.instance.installAllTiers(
      extensionFolder: folder,
      force: force || policyBlocked,
    );

    WindowsExtensionGuardService.invalidateVerifyCache();
    final ExtensionPolicyVerifyResult v =
        await WindowsExtensionGuardService.verifyAllPolicies(force: true);

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.selfHeal,
      message: stale ? 'Chrome 확장 v$bundledVer 자동 업데이트' : 'Chrome 확장 동기화 확인',
      data: <String, Object?>{
        'bundled': bundledVer,
        'installedWas': installedVer,
        'policyBlocked': policyBlocked,
        'hijackPatched': hijack.patchedCount,
        'chromeReady': v.chromeEnforcementReady,
      },
    );

    final result = ChromeExtensionSyncResult(
      ok: v.chromeEnforcementReady,
      message: policyBlocked
          ? 'Chrome 정책 설정을 완료하지 못했습니다. 확장 실행·실제 차단은 아직 확인되지 않았습니다. (v$bundledVer)'
          : 'Chrome 확장 v$bundledVer 파일·정책 준비됨 · 실제 차단 확인 필요',
      bundledVersion: bundledVer,
      installedVersion: installedVer,
      policyBlocked: policyBlocked,
      hijackPatched: hijack.patchedCount,
    );
    _lastResult = result;
    return result;
  }
}

final class ChromeExtensionSyncResult {
  const ChromeExtensionSyncResult({
    required this.ok,
    required this.message,
    this.skipped = false,
    this.bundledVersion,
    this.installedVersion,
    this.policyBlocked = false,
    this.hijackPatched = 0,
  });

  final bool ok;
  final String message;
  final bool skipped;
  final String? bundledVersion;
  final String? installedVersion;
  final bool policyBlocked;
  final int hijackPatched;
}
