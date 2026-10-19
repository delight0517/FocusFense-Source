import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/browser_extension_asset_manifest.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'crash_journal_service.dart';
import 'extension_easy_setup_prefs.dart';
import 'extension_guard_prefs.dart';
import 'protection_coverage_service.dart';
import 'windows_extension_guard_service.dart';
import 'tier_enforcement_service.dart';
import 'windows_extension_setup_automation.dart';
import 'windows_protection_mode_prefs.dart';

/// Runs full 「쉬운 설치」 without the wizard — until all browsers report protection.
final class AutonomousBrowserProtectionService {
  AutonomousBrowserProtectionService._();
  static final AutonomousBrowserProtectionService instance =
      AutonomousBrowserProtectionService._();

  static const Duration kFullSetupCooldown = Duration(minutes: 12);

  final ValueNotifier<AutonomousProtectionStatus?> latest =
      ValueNotifier<AutonomousProtectionStatus?>(null);

  bool _running = false;
  DateTime? _lastFullSetupAt;

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'autonomous_protection_last.json',
  );

  /// Silent full easy-setup when Chrome/Edge/Firefox protection is missing.
  Future<AutonomousProtectionStatus> ensureAllBrowsersProtected({
    required String reason,
    bool force = false,
  }) async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return AutonomousProtectionStatus(
        at: DateTime.now(),
        reason: reason,
        ok: true,
        message: '수동 보호가 꺼져 있어 브라우저 보호 복구를 건너뜁니다.',
        actions: const <String>['manual_protection_off'],
      );
    }
    if (!Platform.isWindows) {
      return AutonomousProtectionStatus(
        at: DateTime.now(),
        reason: reason,
        ok: true,
        message: 'Windows 전용 — 스킵',
        actions: const <String>[],
      );
    }
    if (_running) {
      return latest.value ??
          AutonomousProtectionStatus(
            at: DateTime.now(),
            reason: reason,
            ok: false,
            message: '자율 설치 실행 중…',
            actions: const <String>['busy'],
          );
    }
    if (!await BlockingSelfHealPrefs.instance.autoEasySetup() && !force) {
      return AutonomousProtectionStatus(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        message: '자율 쉬운 설치 꺼짐',
        actions: const <String>[],
      );
    }

    ExtensionPolicyVerifyResult before =
        await WindowsExtensionGuardService.verifyAllPolicies(force: force);
    if (before.protectionOk) {
      await ExtensionEasySetupPrefs.instance.markComplete();
      final AutonomousProtectionStatus ok = AutonomousProtectionStatus(
        at: DateTime.now(),
        reason: reason,
        ok: true,
        message: 'Chrome · Edge · Firefox 보호 정상',
        verify: before,
        actions: const <String>['already_protected'],
      );
      latest.value = ok;
      return ok;
    }

    final DateTime now = DateTime.now();
    if (!force &&
        _lastFullSetupAt != null &&
        now.difference(_lastFullSetupAt!) < kFullSetupCooldown) {
      final AutonomousProtectionStatus wait = AutonomousProtectionStatus(
        at: now,
        reason: reason,
        ok: false,
        message: '자율 설치 쿨다운 — ${kFullSetupCooldown.inMinutes}분 후 재시도',
        verify: before,
        actions: const <String>['cooldown'],
      );
      latest.value = wait;
      return wait;
    }

    _running = true;
    final List<String> actions = <String>['full_easy_setup'];
    try {
      AppLogger.instance.info('autonomous_protection: start reason=$reason');
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: '자율 쉬운 설치 시작 ($reason)',
        debounceKey: 'autonomous_setup_start',
      );

      final ExtensionSetupAutomationResult setup =
          await WindowsExtensionSetupAutomation.instance.runFullSetup(
            chromeAssetPaths: BrowserExtensionAssetManifest.chrome,
            firefoxAssetPaths: BrowserExtensionAssetManifest.firefox,
            silent: true,
            onStatus: (String s) {
              AppLogger.instance.info('autonomous_setup: $s');
              BlockActivityLogService.instance.record(
                kind: BlockActivityKind.selfHeal,
                message: s,
                debounceKey: 'autonomous_setup_step',
              );
            },
          );

      _lastFullSetupAt = DateTime.now();
      actions.add('setup_${setup.phase.name}');

      if (setup.chromePath != null && setup.chromePath!.isNotEmpty) {
        final TierEnforcementResult tier = await TierEnforcementService.instance
            .installAllTiers(extensionFolder: setup.chromePath!, force: force);
        actions.addAll(tier.steps);
      }

      ExtensionPolicyVerifyResult after =
          setup.verify ??
          await WindowsExtensionGuardService.verifyAllPolicies(force: true);
      WindowsExtensionGuardService.invalidateVerifyCache();
      ProtectionCoverageService.instance.invalidateCache();

      final bool allOk = after.protectionOk;
      if (allOk || after.chromeOk) {
        await ExtensionEasySetupPrefs.instance.markComplete();
        await ExtensionGuardPrefs.instance.setWatchdogEnabled(true);
        actions.add('marked_complete');
      }

      final String headline = allOk
          ? '✅ 자율 설치 — Chrome · Edge · Firefox 보호 활성'
          : _headlineForPartial(after, setup);

      final AutonomousProtectionStatus status = AutonomousProtectionStatus(
        at: DateTime.now(),
        reason: reason,
        ok: allOk,
        message: headline,
        verify: after,
        setupResult: setup,
        actions: actions,
      );
      latest.value = status;
      await _persist(status);

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: headline,
        data: status.toJson(),
        level: allOk ? 'info' : 'warn',
      );
      AppLogger.instance.info('autonomous_protection: done ok=$allOk');
      return status;
    } catch (e, st) {
      AppLogger.instance.error(
        'autonomous_protection failed',
        error: e,
        stack: st,
      );
      final AutonomousProtectionStatus fail = AutonomousProtectionStatus(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        message: '자율 설치 오류: $e',
        actions: actions..add('error'),
      );
      latest.value = fail;
      return fail;
    } finally {
      _running = false;
    }
  }

  static String _headlineForPartial(
    ExtensionPolicyVerifyResult v,
    ExtensionSetupAutomationResult setup,
  ) {
    if (!v.firefoxPolicyOk && !v.chromeOk) {
      return '❌ 브라우저 보호 미완료 — UAC 「예」 필요할 수 있음';
    }
    if (v.firefoxPolicyOk && !v.chromeOk) {
      return 'Firefox ✅ · Chrome/Edge 미완료 — 바탕화면 「Focus Fense (Chrome)」 사용';
    }
    if (v.chromeLoadExtensionFallbackOk) {
      return 'Chrome/Edge — 바로가기 보호 모드 (레지스트리 없음)';
    }
    final String first = setup.message.split('\n').first.trim();
    return first.isEmpty ? '브라우저 보호 일부만 적용됨' : first;
  }

  Future<void> _persist(AutonomousProtectionStatus status) async {
    try {
      await CrashJournalService.instance.warmup();
      await File(reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(status.toJson()),
        flush: true,
      );
    } catch (_) {}
  }
}

final class AutonomousProtectionStatus {
  const AutonomousProtectionStatus({
    required this.at,
    required this.reason,
    required this.ok,
    required this.message,
    this.verify,
    this.setupResult,
    required this.actions,
  });

  final DateTime at;
  final String reason;
  final bool ok;
  final String message;
  final ExtensionPolicyVerifyResult? verify;
  final ExtensionSetupAutomationResult? setupResult;
  final List<String> actions;

  bool get chromeOk => verify?.chromeOk ?? false;
  bool get edgeOk => verify?.edgeOk ?? false;
  bool get firefoxOk => verify?.firefoxPolicyOk ?? false;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'reason': reason,
    'ok': ok,
    'message': message,
    'chromeOk': chromeOk,
    'edgeOk': edgeOk,
    'firefoxOk': firefoxOk,
    'protectionOk': verify?.protectionOk,
    'actions': actions,
  };
}
