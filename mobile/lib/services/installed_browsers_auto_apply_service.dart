import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'brave_extension_install_service.dart';
import 'browser_block_health_monitor_service.dart';
import 'browser_extension_force_install_service.dart';
import 'chromium_derivative_extension_service.dart';
import 'new_browser_install_notifier.dart';
import 'universal_browser_block_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_policy_acl_unlock_service.dart';
import 'chrome_extension_payload_service.dart';
import 'work_context_tracker.dart';

/// 설치된 **모든** 브라우저(Chrome~Opera)에 URL 차단·확장을 자동 적용.
/// 부트 적용은 [BootBrowserAutofixService]가 담당 — 여기서는 주기 점검만.
final class InstalledBrowsersAutoApplyService {
  InstalledBrowsersAutoApplyService._();
  static final InstalledBrowsersAutoApplyService instance =
      InstalledBrowsersAutoApplyService._();

  static const Duration kPeriodicInterval = Duration(minutes: 15);
  static const Duration kCooldown = Duration(minutes: 8);

  Timer? _periodicTimer;
  bool _running = false;
  bool _started = false;
  bool _allowElevation = true;
  DateTime? _lastFullApply;

  bool get isBusy => _running;

  String _reportPath() {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker', 'installed_browsers_auto_apply.json');
  }

  void start({bool allowElevation = true}) {
    _allowElevation = allowElevation;
    if (!Platform.isWindows || _started) return;
    _started = true;
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(kPeriodicInterval, (_) {
      unawaited(_periodicHealthRepair());
    });
    AppLogger.instance.info(
      'installed_browsers_auto_apply: periodic only (${kPeriodicInterval.inMinutes}m)',
    );
  }

  void stop() {
    _started = false;
    _periodicTimer?.cancel();
  }

  Future<InstalledBrowsersApplyReport> applyAllInstalled({
    String reason = 'auto',
    bool force = false,
    bool showBanner = true,
  }) async {
    if (!Platform.isWindows) {
      return InstalledBrowsersApplyReport.skipped('Windows 전용');
    }
    if (_running) {
      return InstalledBrowsersApplyReport.skipped('이미 적용 중');
    }
    if (WorkContextTracker.instance.isBusy && !force) {
      return InstalledBrowsersApplyReport.skipped('부트 파이프라인 실행 중');
    }
    final DateTime now = DateTime.now();
    if (!force &&
        _lastFullApply != null &&
        now.difference(_lastFullApply!) < kCooldown) {
      return InstalledBrowsersApplyReport.skipped('쿨다운');
    }

    _running = true;
    final List<String> steps = <String>[];
    final DateTime started = DateTime.now();

    if (showBanner) {
      NewBrowserInstallNotifier.instance.report(
        NewBrowserInstallEvent(
          browserId: 'all',
          displayName: '설치된 브라우저 전체',
          phase: NewBrowserInstallPhase.applying,
          messageKo:
              '설치된 브라우저에 URL 차단·플러그인을 자동 적용 중입니다…\n'
              '잠시만 기다려 주세요.',
          at: DateTime.now(),
        ),
      );
    }

    try {
      AppLogger.instance.info('installed_browsers_auto_apply: start $reason');

      try {
        if (_allowElevation || force) {
          await WindowsPolicyAclUnlockService.instance
              .runElevatedUnlockIfNeeded();
        }
        steps.add('policy_acl');
      } catch (_) {
        steps.add('policy_acl_skip');
      }

      final String? folder =
          await ChromeExtensionPayloadService.ensureStablePayload();
      if (folder != null) {
        await WindowsExtensionSelfHealService.instance.reapplyHkcuOnly(
          sourceFolder: folder,
        );
        steps.add('hkcu_forcelist');
      }

      final UniversalBlockResult universal = await UniversalBrowserBlockService
          .instance
          .syncNow(reason: force ? 'installed_browsers_$reason' : reason);
      steps.add(universal.ok ? 'universal_ok' : 'universal_partial');

      final BrowserExtensionForceInstallReport ext =
          await BrowserExtensionForceInstallService.instance.installAll(
            reason: 'all_browsers_$reason',
            force: force,
            attemptElevated: force,
          );
      steps.add(ext.ok ? 'force_install_ok' : 'force_install_partial');

      final BraveExtensionApplyResult brave = await BraveExtensionInstallService
          .instance
          .apply(reason: 'all_browsers_$reason', force: true);
      steps.add(brave.ok ? 'brave_ok' : 'brave_partial');

      final List<DerivativeExtensionApplyResult> derivatives =
          await ChromiumDerivativeExtensionService.instance.applyAllInstalled(
            reason: 'all_browsers_$reason',
            force: true,
          );
      for (final DerivativeExtensionApplyResult d in derivatives) {
        steps.add(d.ok ? '${d.browserId}_ok' : '${d.browserId}_partial');
      }

      BrowserBlockHealthReport after = await BrowserBlockHealthMonitorService
          .instance
          .probe(reason: 'installed_browsers_$reason');

      final List<String> unprotected = after.browsers
          .where((BrowserHealth b) => b.installed && !b.blockActive)
          .map((BrowserHealth b) => b.id)
          .toList();
      if (unprotected.isNotEmpty) {
        steps.add('retry:${unprotected.join(",")}');
        await UniversalBrowserBlockService.instance.syncNow(
          reason: 'installed_browsers_retry',
        );
        after = await BrowserBlockHealthMonitorService.instance.probe(
          reason: 'installed_browsers_post',
        );
      }
      final List<BrowserHealth> installed = after.browsers
          .where((BrowserHealth b) => b.installed)
          .toList();
      final int ready = installed
          .where((BrowserHealth b) => b.blockActive)
          .length;
      final bool ok = installed.isEmpty || ready == installed.length;

      _lastFullApply = DateTime.now();
      final InstalledBrowsersApplyReport report = InstalledBrowsersApplyReport(
        at: DateTime.now(),
        reason: reason,
        ok: ok,
        installedCount: installed.length,
        readyCount: ready,
        steps: steps,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        health: after,
      );
      await _persist(report);

      if (showBanner) {
        NewBrowserInstallNotifier.instance.report(
          NewBrowserInstallEvent(
            browserId: 'all',
            displayName: '설치된 브라우저 전체',
            phase: ok
                ? NewBrowserInstallPhase.done
                : NewBrowserInstallPhase.failed,
            messageKo: ok
                ? '전체 $ready/${installed.length} 브라우저 URL 차단 적용 완료.\n'
                      '각 브라우저를 완전히 닫았다가 다시 열어주세요.'
                : '일부 브라우저($ready/${installed.length})만 적용됨.\n'
                      '「원탭 차단 적용」을 한 번 더 누르거나 브라우저를 재시작하세요.',
            at: DateTime.now(),
          ),
        );
      }

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: report.summaryKo,
        data: report.toJson(),
        level: ok ? 'info' : 'warn',
        debounceKey: 'installed_browsers_auto',
      );

      return report;
    } catch (e, st) {
      AppLogger.instance.warn('installed_browsers_auto_apply failed: $e\n$st');
      if (showBanner) {
        NewBrowserInstallNotifier.instance.report(
          NewBrowserInstallEvent(
            browserId: 'all',
            displayName: '설치된 브라우저 전체',
            phase: NewBrowserInstallPhase.failed,
            messageKo: '자동 적용 오류: $e',
            at: DateTime.now(),
          ),
        );
      }
      return InstalledBrowsersApplyReport(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        steps: <String>[...steps, 'error:$e'],
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: '$e',
      );
    } finally {
      _running = false;
    }
  }

  Future<void> _periodicHealthRepair() async {
    if (_running || WorkContextTracker.instance.isBusy) return;
    final BrowserBlockHealthReport? latest =
        BrowserBlockHealthMonitorService.instance.latest;
    final bool needsProbe =
        latest == null ||
        DateTime.now().difference(latest.checkedAt) >
            const Duration(minutes: 10);
    BrowserBlockHealthReport? report = latest;
    if (needsProbe) {
      report = await BrowserBlockHealthMonitorService.instance.probe(
        reason: 'auto_apply_precheck',
      );
    }
    if (report == null) return;
    final bool needs = report.browsers.any(
      (BrowserHealth b) => b.installed && !b.blockActive,
    );
    if (!needs) return;
    await applyAllInstalled(
      reason: 'health_repair',
      force: false,
      showBanner: false,
    );
  }

  Future<void> _persist(InstalledBrowsersApplyReport report) async {
    try {
      final File f = File(_reportPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(report.toJson()), flush: true);
    } catch (_) {}
  }
}

final class InstalledBrowsersApplyReport {
  const InstalledBrowsersApplyReport({
    required this.at,
    required this.reason,
    required this.ok,
    this.installedCount = 0,
    this.readyCount = 0,
    this.steps = const <String>[],
    this.durationMs = 0,
    this.health,
    this.error,
    this.skipped = false,
  });

  factory InstalledBrowsersApplyReport.skipped(String why) {
    return InstalledBrowsersApplyReport(
      at: DateTime.now(),
      reason: why,
      ok: true,
      skipped: true,
    );
  }

  final DateTime at;
  final String reason;
  final bool ok;
  final bool skipped;
  final int installedCount;
  final int readyCount;
  final List<String> steps;
  final int durationMs;
  final BrowserBlockHealthReport? health;
  final String? error;

  String get summaryKo {
    if (skipped) return '스킵: $reason';
    if (error != null) return '전체 브라우저 적용 실패: $error';
    return ok
        ? '전체 브라우저 URL 차단 $readyCount/$installedCount 적용'
        : '일부만 적용 $readyCount/$installedCount — 브라우저 재시작 필요';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toUtc().toIso8601String(),
    'reason': reason,
    'ok': ok,
    'skipped': skipped,
    'installedCount': installedCount,
    'readyCount': readyCount,
    'steps': steps,
    'durationMs': durationMs,
    'error': error,
  };
}
