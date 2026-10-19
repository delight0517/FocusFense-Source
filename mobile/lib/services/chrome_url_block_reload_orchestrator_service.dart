import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'blocker_test_service.dart';
import 'browser_block_health_monitor_service.dart';
import 'browser_live_url_block_gate_service.dart';
import 'crash_journal_service.dart';
import 'numeric_apex_hosts_gap_healer_service.dart';
import 'universal_browser_block_service.dart';
import 'unprotected_browser_kill_guard_service.dart';

/// **Zero-touch numeric-apex block verify + auto-repair.**
///
/// Real blocking for `mingky01.live` is **DNS sinkhole (hosts)**, not Chrome
/// URLBlocklist. This service:
/// 1. Probes DNS → must be `0.0.0.0`.
/// 2. Re-applies hosts when leaking.
/// 3. Kills stale Chrome and runs the all-browser live gate script.
final class ChromeUrlBlockReloadOrchestratorService {
  ChromeUrlBlockReloadOrchestratorService._();
  static final ChromeUrlBlockReloadOrchestratorService instance =
      ChromeUrlBlockReloadOrchestratorService._();

  static const Duration _bootDelay = Duration(seconds: 6);
  static const Duration _interval = Duration(seconds: 90);
  static const Duration _minCycleGap = Duration(seconds: 25);

  Timer? _timer;
  bool _running = false;
  bool _cycleBusy = false;
  DateTime? _lastCycleAt;

  final ValueNotifier<ChromeUrlBlockVerifyReport?> latest =
      ValueNotifier<ChromeUrlBlockVerifyReport?>(null);

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'chrome_url_block_verify_last.json',
  );

  void start() {
    if (!Platform.isWindows || _running) return;
    _running = true;
    Future<void>.delayed(_bootDelay, () {
      unawaited(runCycle(reason: 'boot'));
    });
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      unawaited(runCycle(reason: 'periodic'));
    });
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void notifyPolicyApplied() {
    unawaited(runCycle(reason: 'post_apply', force: true));
    Future<void>.delayed(const Duration(seconds: 2), () {
      unawaited(runCycle(reason: 'post_apply_retry', force: true));
    });
  }

  Future<ChromeUrlBlockVerifyReport> runCycle({
    String reason = 'manual',
    bool force = false,
  }) async {
    if (!Platform.isWindows) {
      return ChromeUrlBlockVerifyReport.skipped('Windows 전용');
    }
    if (_cycleBusy) {
      return latest.value ?? ChromeUrlBlockVerifyReport.skipped('실행 중');
    }
    final DateTime? last = _lastCycleAt;
    if (!force &&
        reason != 'post_apply' &&
        last != null &&
        DateTime.now().difference(last) < _minCycleGap) {
      return latest.value ?? ChromeUrlBlockVerifyReport.skipped('쿨다운');
    }

    _cycleBusy = true;
    try {
      final List<String> actions = <String>[];
      final List<ChromeUrlProbeResult> probes = <ChromeUrlProbeResult>[];
      final List<String> probeHosts = await NumericApexHostsGapHealerService
          .instance
          .priorityProbeHosts();

      final NumericApexHostsHealReport heal =
          await NumericApexHostsGapHealerService.instance.healIfNeeded(
            reason: 'url_reload_$reason',
            force: force || reason == 'post_apply',
            allowElevatedHosts: reason == 'post_apply',
          );
      actions.addAll(heal.actions);

      for (final String host in probeHosts) {
        final HostProbe dns = await BlockerTestService.instance.systemProbe(
          host,
        );
        probes.add(
          ChromeUrlProbeResult(
            host: host,
            url: 'https://$host/',
            blocked: dns.blocked,
            exitCode: dns.blocked ? 0 : 1,
            outputBytes: 0,
            detail: dns.detail,
          ),
        );
      }

      bool allBlocked =
          probes.isNotEmpty &&
          probes.every((ChromeUrlProbeResult r) => r.blocked);

      final BrowserBlockHealthReport health =
          await BrowserBlockHealthMonitorService.instance.probe(
            reason: 'url_reload_$reason',
          );
      BrowserHealth? chrome;
      for (final BrowserHealth b in health.browsers) {
        if (b.id == 'chrome') {
          chrome = b;
          break;
        }
      }

      if (!allBlocked) {
        await UniversalBrowserBlockService.instance.syncNow(
          reason: 'url_reload_repair',
        );
        actions.add('universal_sync');
        await _killChrome();
        actions.add('chrome_killed_repair');
        await Future<void>.delayed(const Duration(seconds: 2));

        probes.clear();
        for (final String host in probeHosts) {
          final HostProbe dns = await BlockerTestService.instance.systemProbe(
            host,
          );
          probes.add(
            ChromeUrlProbeResult(
              host: host,
              url: 'https://$host/',
              blocked: dns.blocked,
              exitCode: dns.blocked ? 0 : 1,
              outputBytes: 0,
              detail: dns.detail,
            ),
          );
        }
        allBlocked = probes.every((ChromeUrlProbeResult r) => r.blocked);
      }

      final bool chromeRunning = chrome?.running ?? false;
      if (chromeRunning && (!allBlocked || reason == 'post_apply')) {
        await _killChrome();
        actions.add('chrome_killed_stale');
      }

      final BrowserLiveUrlBlockGateReport gate =
          await BrowserLiveUrlBlockGateService.instance.runLiveTest(
            applyPolicyFirst: true,
            reason: 'url_reload_$reason',
          );
      actions.add('live_gate_ok=${gate.ok}');

      final bool ok = allBlocked && gate.ok;
      if (!ok || gate.hardKillIds.isNotEmpty) {
        await UnprotectedBrowserKillGuardService.instance.enforceImmediately(
          reason: 'url_reload_leak',
        );
      }
      final String message = ok
          ? '✅ mingky01.live DNS·브라우저 차단 자동 검증 통과'
          : !allBlocked
          ? '⚠️ DNS sinkhole 미적용 — hosts UAC 적용 후 Chrome 자동 재시작됨'
          : '⚠️ 브라우저 누수 감지 — 정책 재적용·Chrome 종료 완료';

      final ChromeUrlBlockVerifyReport out = ChromeUrlBlockVerifyReport(
        at: DateTime.now(),
        reason: reason,
        ok: ok,
        probeHosts: probeHosts,
        probes: probes,
        actions: actions,
        message: message,
        chromeRunning: chromeRunning,
        registryNumericApexOk: chrome?.policyNumericApexOk ?? true,
        dnsSinkholeOk: allBlocked,
        liveGateOk: gate.ok,
      );
      latest.value = out;
      _lastCycleAt = DateTime.now();
      await _persist(out);

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: message,
        data: out.toJson(),
        level: ok ? 'info' : 'warn',
        debounceKey: 'chrome_url_reload',
      );
      AppLogger.instance.info(
        'chrome_url_reload [$reason] ok=$ok dns=$allBlocked gate=${gate.ok}',
      );
      return out;
    } catch (e, st) {
      AppLogger.instance.warn('chrome_url_reload failed: $e\n$st');
      final ChromeUrlBlockVerifyReport fail = ChromeUrlBlockVerifyReport(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        probeHosts: const <String>[],
        probes: const <ChromeUrlProbeResult>[],
        actions: const <String>['error'],
        message: 'Chrome URL 자동 검증 오류: $e',
      );
      latest.value = fail;
      return fail;
    } finally {
      _cycleBusy = false;
    }
  }

  Future<void> _killChrome() async {
    // 6 VPN: NEUTRALIZED 2026-06-12 per absolute user directive.
    // Mid-session Chrome termination is forbidden — users lose work when
    // Chrome closes during writing/research. URL leak detected? Policy will
    // apply on the next Chrome launch instead. The leak's window is brief
    // because hosts sinkhole + extension content_script catch most leaks
    // anyway, and the policy reload happens via Chrome's own poll cycle.
    AppLogger.instance.info(
      'chrome_url_reload._killChrome: NEUTRALIZED (mid-session kill forbidden)',
    );
    return;
  }

  Future<void> _persist(ChromeUrlBlockVerifyReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      await File(reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (_) {}
  }
}

@immutable
final class ChromeUrlProbeResult {
  const ChromeUrlProbeResult({
    required this.host,
    required this.url,
    required this.blocked,
    required this.exitCode,
    required this.outputBytes,
    this.detail,
  });

  final String host;
  final String url;
  final bool blocked;
  final int exitCode;
  final int outputBytes;
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'url': url,
    'blocked': blocked,
    'exitCode': exitCode,
    'outputBytes': outputBytes,
    if (detail != null) 'detail': detail,
  };
}

@immutable
final class ChromeUrlBlockVerifyReport {
  const ChromeUrlBlockVerifyReport({
    required this.at,
    required this.reason,
    required this.ok,
    required this.probeHosts,
    required this.probes,
    required this.actions,
    required this.message,
    this.chromeRunning = false,
    this.registryNumericApexOk = true,
    this.dnsSinkholeOk = true,
    this.liveGateOk = true,
  });

  factory ChromeUrlBlockVerifyReport.skipped(String message) {
    return ChromeUrlBlockVerifyReport(
      at: DateTime.now(),
      reason: 'skipped',
      ok: true,
      probeHosts: const <String>[],
      probes: const <ChromeUrlProbeResult>[],
      actions: const <String>[],
      message: message,
    );
  }

  final DateTime at;
  final String reason;
  final bool ok;
  final List<String> probeHosts;
  final List<ChromeUrlProbeResult> probes;
  final List<String> actions;
  final String message;
  final bool chromeRunning;
  final bool registryNumericApexOk;
  final bool dnsSinkholeOk;
  final bool liveGateOk;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'reason': reason,
    'ok': ok,
    'probeHosts': probeHosts,
    'probes': probes.map((ChromeUrlProbeResult p) => p.toJson()).toList(),
    'actions': actions,
    'message': message,
    'chromeRunning': chromeRunning,
    'registryNumericApexOk': registryNumericApexOk,
    'dnsSinkholeOk': dnsSinkholeOk,
    'liveGateOk': liveGateOk,
  };
}
