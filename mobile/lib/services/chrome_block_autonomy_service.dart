import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'chrome_extension_auto_sync_service.dart';
import 'chrome_extension_install_verifier.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_extension_state_probe.dart';
import 'chrome_load_extension_launcher.dart';
import 'crash_journal_service.dart';
import 'extension_rules_snapshot_service.dart';
import 'tier_enforcement_service.dart';
import 'universal_browser_block_service.dart';
import 'windows_protection_mode_prefs.dart';
import 'usage_ingest_server.dart';
import 'automated_browser_handoff_service.dart';
import 'windows_extension_guard_service.dart';

/// Autonomous Chrome block health: test → repair → log (no user steps).
final class ChromeBlockAutonomyService {
  ChromeBlockAutonomyService._();
  static final ChromeBlockAutonomyService instance =
      ChromeBlockAutonomyService._();

  static const Duration kRepairCooldown = Duration(minutes: 8);

  final ValueNotifier<ChromeBlockStatus?> latest =
      ValueNotifier<ChromeBlockStatus?>(null);

  bool _running = false;
  DateTime? _lastRepairAt;

  String get reportPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'chrome_block_status_last.json',
      );

  /// Lightweight check + optional repair. Safe to call from boot / self-heal.
  Future<ChromeBlockStatus> runOnce({
    String reason = 'manual',
    bool repair = true,
  }) async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return ChromeBlockStatus(
        at: DateTime.now(),
        reason: reason,
        blockingOk: true,
        userMessage: '수동 보호가 꺼져 있어 Chrome 복구를 건너뜁니다.',
      );
    }
    if (!Platform.isWindows) {
      return ChromeBlockStatus(
        at: DateTime.now(),
        reason: reason,
        blockingOk: true,
        userMessage: 'Windows 전용',
      );
    }
    if (_running) {
      return latest.value ??
          ChromeBlockStatus(
            at: DateTime.now(),
            reason: reason,
            blockingOk: false,
            userMessage: 'Chrome 점검 실행 중…',
          );
    }
    _running = true;
    try {
      final List<String> actions = <String>[];
      final ChromeBlockStatus status = await _evaluate();

      if (!status.blockingOk && repair && _repairAllowed()) {
        actions.addAll(await _repair(status));
        _lastRepairAt = DateTime.now();
        final ChromeBlockStatus after = await _evaluate();
        final ChromeBlockStatus out = after.copyWith(
          reason: reason,
          actions: <String>[...actions, ...after.actions],
          repaired: true,
        );
        latest.value = out;
        await _persist(out);
        _log(out);
        return out;
      }

      final ChromeBlockStatus out = status.copyWith(
        reason: reason,
        actions: actions,
      );
      latest.value = out;
      await _persist(out);
      _log(out);
      return out;
    } catch (e, st) {
      AppLogger.instance.error('chrome_block_autonomy failed', error: e, stack: st);
      final ChromeBlockStatus fail = ChromeBlockStatus(
        at: DateTime.now(),
        reason: reason,
        blockingOk: false,
        userMessage: 'Chrome 점검 오류 — 앱을 다시 실행해 주세요.',
      );
      latest.value = fail;
      return fail;
    } finally {
      _running = false;
    }
  }

  bool _repairAllowed() {
    if (_lastRepairAt == null) return true;
    return DateTime.now().difference(_lastRepairAt!) >= kRepairCooldown;
  }

  Future<ChromeBlockStatus> _evaluate() async {
    final List<String> issues = <String>[];
    final DateTime at = DateTime.now();

    final bool payloadOk = await ChromeExtensionPayloadService.stablePayloadReady();
    if (!payloadOk) {
      issues.add('확장 파일 없음');
    }

    final bool launchers = await ChromeLoadExtensionLauncher.isInstalled();
    if (!launchers) {
      issues.add('보호 Chrome 실행기 없음');
    }

    final String snapPath = p.join(
      ChromeLoadExtensionLauncher.stableChromeExtDir,
      ExtensionRulesSnapshotService.kSnapshotFileName,
    );
    bool snapshotOk = false;
    int domainCount = 0;
    int keywordCount = 0;
    try {
      final File f = File(snapPath);
      if (await f.exists()) {
        final Object? decoded = jsonDecode(await f.readAsString());
        if (decoded is Map<String, dynamic>) {
          final List<dynamic>? doms = decoded['blockedDomains'] as List<dynamic>?;
          final List<dynamic>? kws = decoded['keywords'] as List<dynamic>?;
          domainCount = doms?.length ?? 0;
          keywordCount = kws?.length ?? 0;
          snapshotOk = domainCount > 0 || keywordCount > 0;
        }
      }
    } catch (_) {}
    if (!snapshotOk) {
      issues.add('차단 규칙 스냅샷 없음');
    }

    bool rulesApiOk = false;
    int apiDomains = 0;
    if (!UsageIngestServer.instance.isRunning) {
      UsageIngestServer.instance.start();
    }
    if (UsageIngestServer.instance.isRunning) {
      try {
        final HttpClient client = HttpClient();
        final int port = UsageIngestServer.instance.boundPort;
        final HttpClientRequest req = await client.get(
          '127.0.0.1',
          port,
          '/rules',
        );
        final HttpClientResponse res =
            await req.close().timeout(const Duration(seconds: 2));
        if (res.statusCode == 200) {
          final String body = await utf8.decoder.bind(res).join();
          final Object? decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            rulesApiOk = true;
            apiDomains =
                (decoded['blockedDomains'] as List<dynamic>?)?.length ?? 0;
          }
        }
        client.close(force: true);
      } catch (_) {}
    }
    if (!rulesApiOk) {
      issues.add('규칙 API 미동작');
    }

    final ExtensionPolicyVerifyResult v =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final ChromeExtensionProbeResult prefsProbe =
        await ChromeExtensionStateProbe.probe(browser: 'chrome');
    final bool chromeInProfile = !prefsProbe.extensionNotPresent;

    final BrowserProcessProbe probe =
        await AutomatedBrowserHandoffService.probeBrowsers();
    final bool chromeRuntimeOk =
        await AutomatedBrowserHandoffService.isChromeEffectivelyProtected();
    if (probe.chromeUnprotected && !chromeRuntimeOk) {
      issues.add('보호 없는 Chrome 실행 중');
    }
    if (!chromeInProfile && !v.chromeEnforcementReady) {
      issues.add('프로필에 확장 없음');
    }

    final bool enforcementOk = v.chromeEnforcementReady || chromeInProfile;
    final bool blockingOk = payloadOk &&
        launchers &&
        snapshotOk &&
        rulesApiOk &&
        enforcementOk &&
        (chromeRuntimeOk || !probe.chromeRunning);

    String userMessage;
    if (blockingOk) {
      userMessage =
          '✅ Chrome 차단 준비됨 (도메인 $domainCount · 키워드 $keywordCount). '
          '앱이 보호 Chrome을 자동 적용합니다 — 별도 조작 불필요.';
    } else if (probe.chromeUnprotected && !chromeRuntimeOk) {
      userMessage =
          '⚠️ Chrome이 확장 없이 열려 있습니다 — 앱이 보호 브라우저로 자동 전환합니다.';
    } else {
      userMessage =
          '⚠️ Chrome 차단 미완료 — 앱이 자동 복구 중입니다. '
          '${issues.join(' · ')}';
    }

    return ChromeBlockStatus(
      at: at,
      reason: 'evaluate',
      blockingOk: blockingOk,
      userMessage: userMessage,
      payloadOk: payloadOk,
      launchersOk: launchers,
      rulesSnapshotOk: snapshotOk,
      rulesApiOk: rulesApiOk,
      domainCount: domainCount,
      apiDomainCount: apiDomains,
      keywordCount: keywordCount,
      loadExtensionFallback: v.chromeLoadExtensionFallbackOk,
      registryChromeOk: v.chromeOk,
    );
  }

  Future<List<String>> _repair(ChromeBlockStatus before) async {
    final List<String> done = <String>[];
    final ChromeExtensionSyncResult sync =
        await ChromeExtensionAutoSyncService.instance.syncIfNeeded(
      force: true,
      reason: 'chrome_repair',
    );
    if (!sync.skipped) done.add('extension_auto_sync');
    final String? folder = await ChromeExtensionPayloadService.ensureStablePayload();
    if (!before.payloadOk) {
      done.add('payload_repair');
    }
    if (folder != null) {
      await ChromeLoadExtensionLauncher.install(extensionFolder: folder);
      done.add('launchers_refresh');
      final ChromeInstallVerifyReport verify =
          await ChromeExtensionInstallVerifier.instance.verifyAndRepair(
        reason: 'chrome_repair',
        force: true,
      );
      done.add('chrome_verify:${verify.ok}');
      await ExtensionRulesSnapshotService.instance.writeToChromePayload(
        sourceFolder: folder,
      );
      done.add('rules_snapshot');
      final TierEnforcementResult tier =
          await TierEnforcementService.instance.installAllTiers(
        extensionFolder: folder,
        force: false,
      );
      done.addAll(tier.steps);
      if (!tier.ok) done.add('tier_partial');
    }
    await TierEnforcementService.instance.runTier3Once();
    done.add('tier3_once');
    await UniversalBrowserBlockService.instance.syncNow(reason: 'chrome_repair');
    done.add('universal_pac');
    final AutomatedHandoffResult handoff =
        await AutomatedBrowserHandoffService.instance.runZeroTouch(
      reason: 'chrome_repair',
      force: true,
    );
    done.addAll(handoff.actions);
    return done;
  }

  Future<void> _persist(ChromeBlockStatus status) async {
    try {
      await CrashJournalService.instance.warmup();
      await File(reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(status.toJson()),
        flush: true,
      );
    } catch (_) {}
  }

  void _log(ChromeBlockStatus status) {
    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.selfHeal,
      message: status.userMessage,
      data: status.toJson(),
      level: status.blockingOk ? 'info' : 'warn',
      debounceKey: 'chrome_block_autonomy',
    );
    AppLogger.instance.info(
      'chrome_block_autonomy ok=${status.blockingOk} domains=${status.domainCount}',
    );
  }
}

@immutable
final class ChromeBlockStatus {
  const ChromeBlockStatus({
    required this.at,
    required this.reason,
    required this.blockingOk,
    required this.userMessage,
    this.payloadOk = false,
    this.launchersOk = false,
    this.rulesSnapshotOk = false,
    this.rulesApiOk = false,
    this.domainCount = 0,
    this.apiDomainCount = 0,
    this.keywordCount = 0,
    this.loadExtensionFallback = false,
    this.registryChromeOk = false,
    this.actions = const <String>[],
    this.repaired = false,
  });

  final DateTime at;
  final String reason;
  final bool blockingOk;
  final String userMessage;
  final bool payloadOk;
  final bool launchersOk;
  final bool rulesSnapshotOk;
  final bool rulesApiOk;
  final int domainCount;
  final int apiDomainCount;
  final int keywordCount;
  final bool loadExtensionFallback;
  final bool registryChromeOk;
  final List<String> actions;
  final bool repaired;

  ChromeBlockStatus copyWith({
    String? reason,
    bool? blockingOk,
    String? userMessage,
    List<String>? actions,
    bool? repaired,
  }) {
    return ChromeBlockStatus(
      at: at,
      reason: reason ?? this.reason,
      blockingOk: blockingOk ?? this.blockingOk,
      userMessage: userMessage ?? this.userMessage,
      payloadOk: payloadOk,
      launchersOk: launchersOk,
      rulesSnapshotOk: rulesSnapshotOk,
      rulesApiOk: rulesApiOk,
      domainCount: domainCount,
      apiDomainCount: apiDomainCount,
      keywordCount: keywordCount,
      loadExtensionFallback: loadExtensionFallback,
      registryChromeOk: registryChromeOk,
      actions: actions ?? this.actions,
      repaired: repaired ?? this.repaired,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'reason': reason,
        'blockingOk': blockingOk,
        'userMessage': userMessage,
        'payloadOk': payloadOk,
        'launchersOk': launchersOk,
        'rulesSnapshotOk': rulesSnapshotOk,
        'rulesApiOk': rulesApiOk,
        'domainCount': domainCount,
        'apiDomainCount': apiDomainCount,
        'keywordCount': keywordCount,
        'loadExtensionFallback': loadExtensionFallback,
        'registryChromeOk': registryChromeOk,
        'actions': actions,
        'repaired': repaired,
      };
}
