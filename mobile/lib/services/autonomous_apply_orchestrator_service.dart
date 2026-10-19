import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'app_operation_progress_service.dart';
import 'block_activity_log_service.dart';
import 'blocking_self_heal_agent_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'boot_apply_idempotency_service.dart';
import 'boot_browser_autofix_service.dart';
import 'crash_journal_service.dart';
import 'blocking_repair_failure_tracker_service.dart';
import 'cursor_agent_fix_log_service.dart';
import 'cursor_agent_snapshot_service.dart';
import 'local_database.dart';
import 'network_url_block_service.dart';
import 'post_rebuild_bootstrap_service.dart';
import 'windows_hkcu_policy_service.dart';
import 'work_context_tracker.dart';
import 'numeric_apex_hosts_gap_healer_service.dart';
import 'youtube_hosts_autofix_service.dart';

/// **Single launch orchestrator** — 점검 + 적용 + Cursor fix 로그 (복붙 불필요).
///
/// 앱 런치 직후 1회만 실행. YouTube DNS·PAC·hosts·확장·자가점검을 순서대로
/// 시도하고 `autonomous_apply_last.json` + `cursor_agent_fix_last.json`에
/// 성공/실패·미적용 레이어를 기록한다.
/// Why this exists:
/// Browser policies, PAC files, hosts markers, and extension payloads can be
/// changed outside the app by browser updates, Windows policy refresh, security
/// tools, or manual edits. This launch check is only meant to verify drift and
/// re-apply user-space layers when needed; admin/UAC repair must stay behind an
/// explicit user action.
final class AutonomousApplyOrchestratorService {
  AutonomousApplyOrchestratorService._();
  static final AutonomousApplyOrchestratorService instance =
      AutonomousApplyOrchestratorService._();

  bool _scheduled = false;
  bool _running = false;
  String? _progressId;

  static const Duration kPhaseBTimeout = Duration(minutes: 5);
  static const Duration kBootstrapWaitTimeout = Duration(seconds: 90);
  static const Duration kFullPipelineTimeout = Duration(minutes: 8);

  static const Map<String, double> _phaseFraction = <String, double>{
    'warmup': 0.05,
    'phase_a_youtube': 0.12,
    'phase_a_numeric_apex': 0.20,
    'phase_a_complete': 0.30,
    'phase_b_wait': 0.38,
    'phase_b_boot': 0.55,
    'phase_b_self_heal': 0.78,
    'phase_b_complete': 0.95,
    'done': 1.0,
  };

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'autonomous_apply_last.json',
  );

  /// Call once from [main] after first frame.
  ///
  /// Waits for [PostRebuildBootstrapService] when it is running so Phase A
  /// does not spawn a second PowerShell storm in parallel with post-rebuild.
  ///
  /// 2026-06-20 UX fix: was 4s → 30s. Live user-impersonation test caught
  /// the modal popping up while the user was still clicking the first tab.
  /// The 3-minute "PC가 잠시 느려질 수 있어요" overlay landing on top of an
  /// active user is the worst possible time. We now (1) wait 30s for the
  /// user to settle, then (2) defer further while WorkContextTracker says
  /// the user is busy (up to 90s extra), then (3) actually run the pipeline.
  void scheduleOnLaunch({required bool postRebuildLight}) {
    if (!Platform.isWindows || _scheduled) return;
    _scheduled = true;
    unawaited(_persistScheduled('launch_light'));
    unawaited(
      Future<void>.delayed(const Duration(seconds: 30), () async {
        // Defer further if the user is actively interacting — up to 90s.
        int waitTicks = 0;
        while (WorkContextTracker.instance.isBusy && waitTicks < 30) {
          await Future<void>.delayed(const Duration(seconds: 3));
          waitTicks++;
        }
        if (PostRebuildBootstrapService.instance.isRunning) {
          AppLogger.instance.info(
            'autonomous_apply: waiting for post_rebuild_bootstrap…',
          );
          await PostRebuildBootstrapService.instance.whenIdle(
            timeout: kBootstrapWaitTimeout,
          );
        }
        await runFullPipeline(reason: 'launch_light', light: true);
      }),
    );
  }

  Future<void> _persistScheduled(String reason) async {
    await _persist(
      AutonomousApplyReport(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        verdict: '자율 점검·적용 예약됨 (2초 후 시작)',
        steps: const <AutonomousApplyStep>[],
        failedLayers: const <String>[],
        appliedLayers: const <String>[],
        durationMs: 0,
        phase: 'scheduled',
      ),
    );
  }

  /// Resume — retry incomplete launch pipeline + lighter browser repair.
  void scheduleOnResume() {
    if (!Platform.isWindows || _running) return;
    if (WorkContextTracker.instance.isBusy ||
        PostRebuildBootstrapService.instance.isRunning) {
      return;
    }
    BootBrowserAutofixService.instance.scheduleOnResume();
    unawaited(_retryIfIncomplete(reason: 'resume'));
  }

  Future<void> _retryIfIncomplete({required String reason}) async {
    try {
      final File f = File(reportPath);
      if (!await f.exists()) return;
      final Object? raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return;
      final String? phase = raw['phase'] as String?;
      if (phase == 'complete') return;
      final DateTime? at = DateTime.tryParse('${raw['at']}');
      if (at != null &&
          DateTime.now().difference(at) > const Duration(minutes: 30)) {
        AppLogger.instance.warn(
          'autonomous_apply: stale incomplete phase=$phase — skip resume',
        );
        await _persist(
          AutonomousApplyReport(
            at: DateTime.now(),
            reason: reason,
            ok: true,
            verdict: '이전 자율 적용 세션 만료 — 재시도 생략',
            steps: const <AutonomousApplyStep>[],
            failedLayers: const <String>[],
            appliedLayers: const <String>[],
            durationMs: 0,
            phase: 'complete',
          ),
        );
        return;
      }
      AppLogger.instance.info(
        'autonomous_apply: resume incomplete phase=$phase',
      );
      await runFullPipeline(reason: reason, light: true);
    } catch (e) {
      AppLogger.instance.warn('autonomous_apply resume check failed: $e');
    }
  }

  Future<AutonomousApplyReport> runFullPipeline({
    required String reason,
    bool light = false,
    bool userInitiated = false,
  }) async {
    if (!Platform.isWindows) {
      return AutonomousApplyReport.skipped('Windows 전용');
    }
    if (_running) {
      return AutonomousApplyReport.skipped('이전 자율 적용 실행 중');
    }

    if (!userInitiated) {
      final BootApplySkipVerdict skip = await BootApplyIdempotencyService
          .instance
          .evaluateSkip(reason: reason, userInitiated: userInitiated);
      if (skip.skip) {
        final AutonomousApplyReport skipped = AutonomousApplyReport(
          at: DateTime.now(),
          reason: reason,
          ok: true,
          verdict: skip.messageKo ?? '부트 적용 생략 (변경 없음)',
          steps: <AutonomousApplyStep>[
            AutonomousApplyStep(
              name: 'idempotency_skip',
              ok: true,
              detail: skip.detail ?? 'steady_state',
            ),
          ],
          failedLayers: const <String>[],
          appliedLayers: const <String>[],
          durationMs: 0,
          phase: 'complete',
        );
        await _persist(skipped);
        await CursorAgentFixLogService.instance.record(
          CursorAgentFixEntry(
            component: 'autonomous_apply_orchestrator',
            action: '${reason}_skipped',
            ok: true,
            verdict: skipped.verdict,
            reason: reason,
            details: skipped.toJson(),
            failedLayers: const <String>[],
            appliedLayers: const <String>[],
            fixesAttempted: const <String>['idempotency_skip'],
          ),
        );
        AppLogger.instance.info('autonomous_apply: skipped (${skip.detail})');
        return skipped;
      }
    }

    _running = true;
    _progressId = AppOperationProgressService.instance.begin(
      title: '자율 점검·차단 적용',
      step: '시작',
      fraction: 0.02,
      estimatedTotal: const Duration(minutes: 3),
      id: 'autonomous_apply',
      explicit: false,
    );
    final DateTime started = DateTime.now();
    final List<AutonomousApplyStep> steps = <AutonomousApplyStep>[];
    final List<String> failedLayers = <String>[];
    final List<String> appliedLayers = <String>[];
    final Map<String, int> stepTimingsMs = <String, int>{};

    Future<T> _timed<T>(String stepName, Future<T> Function() body) async {
      final DateTime t0 = DateTime.now();
      try {
        return await body();
      } finally {
        stepTimingsMs[stepName] = DateTime.now().difference(t0).inMilliseconds;
      }
    }

    Future<void> flushProgress(String phase, String verdict) async {
      final String? pid = _progressId;
      if (pid != null) {
        AppOperationProgressService.instance.update(
          pid,
          step: verdict,
          fraction: _phaseFraction[phase] ?? 0.5,
        );
      }
      await _persist(
        AutonomousApplyReport(
          at: DateTime.now(),
          reason: reason,
          ok: failedLayers.isEmpty,
          verdict: verdict,
          steps: List<AutonomousApplyStep>.from(steps),
          failedLayers: List<String>.from(failedLayers),
          appliedLayers: List<String>.from(appliedLayers),
          durationMs: DateTime.now().difference(started).inMilliseconds,
          phase: phase,
        ),
      );
    }

    try {
      return await WorkContextTracker.instance.run(
        'autonomous_apply.full_pipeline',
        () {
          return () async {
            AppLogger.instance.info('autonomous_apply: start reason=$reason');

            await CrashJournalService.instance.warmup();
            try {
              await LocalDatabase.instance.database;
            } catch (e) {
              AppLogger.instance.warn('autonomous_apply: DB warmup: $e');
            }
            await BlockActivityLogService.instance.start();
            _step(steps, 'warmup', ok: true, detail: 'debug folder ready');
            await flushProgress('warmup', '자율 점검·적용 시작');

            final bool bootstrapFresh =
                PostRebuildBootstrapService.completedThisSession;

            final YoutubeHostsAutofixReport yt = bootstrapFresh
                ? YoutubeHostsAutofixReport.skipped(
                    'post_rebuild에서 이미 처리 — YouTube DNS 생략',
                  )
                : await _timed(
                    'youtube_dns',
                    () => YoutubeHostsAutofixService.instance.runAutofix(
                      reason: reason,
                    ),
                  );
            _step(
              steps,
              'youtube_dns',
              ok: yt.ok,
              detail: yt.verdict,
              data: yt.toJson(),
            );
            if (!yt.ok && !bootstrapFresh) {
              failedLayers.add('youtube_dns');
            } else if (!bootstrapFresh) {
              appliedLayers.add('youtube_dns');
            }
            await flushProgress('phase_a_youtube', yt.verdict);

            final NumericApexHostsHealReport apex = bootstrapFresh
                ? NumericApexHostsHealReport.skipped(
                    'post_rebuild에서 이미 처리 — numeric apex 생략',
                  )
                : await _timed(
                    'numeric_apex_dns',
                    () =>
                        NumericApexHostsGapHealerService.instance.healIfNeeded(
                          reason: reason,
                          force: reason.startsWith('launch') || userInitiated,
                          allowElevatedHosts: userInitiated,
                        ),
                  );
            _step(
              steps,
              'numeric_apex_dns',
              ok: apex.ok,
              detail: apex.message,
              data: apex.toJson(),
            );
            if (!apex.ok && !bootstrapFresh) {
              failedLayers.add('numeric_apex_dns');
            } else if (!bootstrapFresh) {
              appliedLayers.add('numeric_apex_dns');
            }
            await flushProgress('phase_a_numeric_apex', apex.message);

            final bool canSkipNetwork =
                bootstrapFresh &&
                await WindowsHkcuPolicyService.instance
                    .hasRequiredBrowserPolicies();
            final NetworkUrlBlockResult net = canSkipNetwork
                ? const NetworkUrlBlockResult(
                    ok: true,
                    message: 'post_rebuild PAC·URLBlocklist 생략',
                    pacActive: true,
                    hkcuOk: true,
                  )
                : await NetworkUrlBlockService.instance.enforceNow(
                    reason: bootstrapFresh
                        ? '${reason}_post_rebuild_policy_missing'
                        : reason,
                  );
            _step(
              steps,
              'network_pac_urlblocklist',
              ok: net.ok,
              detail: net.message,
            );
            if (net.ok) {
              appliedLayers.add('pac+urlblocklist');
            } else if (!bootstrapFresh) {
              failedLayers.add('pac+urlblocklist');
            }
            await flushProgress('phase_a_complete', net.message);

            final bool fullStack =
                userInitiated ||
                await BlockingSelfHealPrefs.instance.isEnabled();

            BootAutofixReport? boot;
            SelfHealReport? selfHeal;

            if (fullStack) {
              if (PostRebuildBootstrapService.completedThisSession) {
                _step(
                  steps,
                  'post_rebuild_skip',
                  ok: true,
                  detail: '이번 세션 리빌드 부트스트랩 완료 — 중복 boot 생략',
                );
                await flushProgress('phase_b_wait', '부트스트랩 완료 — 중복 생략');
              } else if (PostRebuildBootstrapService.instance.isRunning) {
                _step(
                  steps,
                  'post_rebuild_wait',
                  ok: true,
                  detail:
                      '리빌드 부트스트랩 완료 대기 (최대 ${kBootstrapWaitTimeout.inSeconds}초)…',
                );
                await flushProgress('phase_b_wait', '리빌드 부트스트랩 대기');
                await PostRebuildBootstrapService.instance.whenIdle(
                  timeout: kBootstrapWaitTimeout,
                );
                if (PostRebuildBootstrapService.instance.isRunning) {
                  _step(
                    steps,
                    'post_rebuild_wait_timeout',
                    ok: true,
                    detail: '부트스트랩 아직 실행 중 — boot_browser_autofix 생략 (중복 방지)',
                  );
                  await flushProgress(
                    'phase_b_boot',
                    '부트스트랩 진행 중 — boot 단계 생략',
                  );
                }
              }

              final bool skipBootDuplicate =
                  PostRebuildBootstrapService.completedThisSession ||
                  PostRebuildBootstrapService.instance.isRunning;

              final bool skipBootForLaunchLight =
                  light && reason == 'launch_light';

              if (!skipBootDuplicate && !skipBootForLaunchLight)
                try {
                  boot = await BootBrowserAutofixService.instance
                      .runBootPipeline(
                        reason: reason,
                        light: light,
                        ignoreCooldown: reason.startsWith('launch'),
                        skipYoutubeStep: true,
                      )
                      .timeout(
                        kPhaseBTimeout,
                        onTimeout: () => BootAutofixReport(
                          at: DateTime.now(),
                          reason: reason,
                          light: light,
                          ok: false,
                          steps: const <String>['timeout'],
                          durationMs: 0,
                          error: 'timeout_${kPhaseBTimeout.inMinutes}m',
                        ),
                      );
                } catch (e) {
                  boot = BootAutofixReport(
                    at: DateTime.now(),
                    reason: reason,
                    light: light,
                    ok: false,
                    steps: const <String>['error'],
                    durationMs: 0,
                    error: '$e',
                  );
                }
              if (boot != null) {
                stepTimingsMs['boot_browser_autofix'] = boot.durationMs;
                _step(
                  steps,
                  'boot_browser_autofix',
                  ok: boot.ok,
                  detail: boot.summary,
                  data: boot.toJson(),
                );
                if (!boot.ok) {
                  failedLayers.addAll(_failedFromBoot(boot));
                } else {
                  appliedLayers.add('boot_browser_autofix');
                }
                await flushProgress('phase_b_boot', boot.summary);
              }

              if (!light) {
                try {
                  selfHeal = await BlockingSelfHealAgentService.instance
                      .runCycle(reason: reason, userInitiated: userInitiated)
                      .timeout(
                        const Duration(minutes: 8),
                        onTimeout: () => SelfHealReport(
                          at: DateTime.now(),
                          reason: reason,
                          ok: false,
                          verdict: '자가점검 시간 초과 (8분)',
                          probes: const <SelfHealProbe>[],
                          actions: const <String>[],
                        ),
                      );
                } catch (e) {
                  selfHeal = SelfHealReport(
                    at: DateTime.now(),
                    reason: reason,
                    ok: false,
                    verdict: '자가점검 오류: $e',
                    probes: const <SelfHealProbe>[],
                    actions: const <String>[],
                  );
                }
                _step(
                  steps,
                  'blocking_self_heal',
                  ok: selfHeal.ok,
                  detail: selfHeal.verdict,
                  data: selfHeal.toJson(),
                );
                if (!selfHeal.ok) {
                  for (final SelfHealProbe p in selfHeal.probes) {
                    if (!p.ok) failedLayers.add('self_heal:${p.label}');
                  }
                } else {
                  appliedLayers.add('blocking_self_heal');
                }
                await flushProgress('phase_b_self_heal', selfHeal.verdict);
              }
            } else {
              _step(
                steps,
                'full_stack',
                ok: true,
                detail: '자가점검 꺼짐 — Phase A(DNS+PAC)만 적용',
              );
            }

            Map<String, Object?>? snapshot;
            if (!light || userInitiated) {
              try {
                snapshot = await CursorAgentSnapshotService.instance.refresh(
                  reason: reason,
                  light: light,
                );
                _step(
                  steps,
                  'cursor_snapshot',
                  ok: true,
                  detail: 'snapshot written',
                );
              } catch (e) {
                _step(steps, 'cursor_snapshot', ok: false, detail: '$e');
                failedLayers.add('cursor_snapshot');
              }
            } else {
              _step(
                steps,
                'cursor_snapshot',
                ok: true,
                detail: 'launch_light-skip',
              );
            }

            final bool ok = failedLayers.isEmpty;
            final String verdict = ok
                ? '자율 점검·적용 완료 (${steps.length}단계)'
                : '일부 실패 — failed: ${failedLayers.join(", ")}';

            final AutonomousApplyReport report = AutonomousApplyReport(
              at: DateTime.now(),
              reason: reason,
              ok: ok,
              verdict: verdict,
              steps: steps,
              failedLayers: failedLayers,
              appliedLayers: appliedLayers,
              durationMs: DateTime.now().difference(started).inMilliseconds,
              youtubeAutofix: yt,
              bootAutofix: boot,
              selfHeal: selfHeal,
              agentNotes: _agentNotesFromSnapshot(snapshot),
              phase: 'complete',
              stepTimingsMs: stepTimingsMs,
            );

            await _persist(report);
            await CursorAgentFixLogService.instance.record(
              CursorAgentFixEntry(
                component: 'autonomous_apply_orchestrator',
                action: reason,
                ok: ok,
                verdict: verdict,
                reason: reason,
                details: report.toJson(),
                failedLayers: failedLayers,
                appliedLayers: appliedLayers,
                fixesAttempted: steps
                    .map((AutonomousApplyStep s) => s.name)
                    .toList(),
              ),
            );
            await BlockingRepairFailureTrackerService.instance.record(
              component: 'autonomous_apply',
              action: reason,
              ok: ok,
              verdict: verdict,
              reason: reason,
              details: report.toJson(),
              failedLayers: failedLayers,
              appliedLayers: appliedLayers,
              fixesAttempted: steps
                  .map((AutonomousApplyStep s) => s.name)
                  .toList(),
            );

            BlockActivityLogService.instance.record(
              kind: BlockActivityKind.selfHeal,
              message: verdict,
              data: report.toJson(),
              level: ok ? 'info' : 'warn',
              debounceKey: 'autonomous_apply',
            );

            await flushProgress('done', verdict);
            if (ok) {
              await BootApplyIdempotencyService.instance.recordSuccess(
                source: 'autonomous_apply_$reason',
                verdict: verdict,
              );
            }
            AppLogger.instance.info('autonomous_apply: $verdict');
            return report;
          }().timeout(
            kFullPipelineTimeout,
            onTimeout: () async {
              failedLayers.add(
                'pipeline_timeout_${kFullPipelineTimeout.inMinutes}m',
              );
              final AutonomousApplyReport timeout = AutonomousApplyReport(
                at: DateTime.now(),
                reason: reason,
                ok: false,
                verdict:
                    '자율 적용 시간 초과 (${kFullPipelineTimeout.inMinutes}분) — WorkContext 해제',
                steps: List<AutonomousApplyStep>.from(steps),
                failedLayers: List<String>.from(failedLayers),
                appliedLayers: List<String>.from(appliedLayers),
                durationMs: DateTime.now().difference(started).inMilliseconds,
                phase: 'complete',
                stepTimingsMs: stepTimingsMs,
              );
              await _persist(timeout);
              await flushProgress('done', timeout.verdict);
              AppLogger.instance.warn('autonomous_apply: ${timeout.verdict}');
              return timeout;
            },
          );
        },
      );
    } catch (e, st) {
      AppLogger.instance.error('autonomous_apply failed', error: e, stack: st);
      failedLayers.add('orchestrator_exception');
      final AutonomousApplyReport fail = AutonomousApplyReport(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        verdict: '자율 적용 오류: $e',
        steps: steps,
        failedLayers: failedLayers,
        appliedLayers: appliedLayers,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: e.toString(),
        phase: 'error',
      );
      await _persist(fail);
      await CursorAgentFixLogService.instance.record(
        CursorAgentFixEntry(
          component: 'autonomous_apply_orchestrator',
          action: reason,
          ok: false,
          verdict: fail.verdict,
          reason: reason,
          details: fail.toJson(),
          failedLayers: failedLayers,
          appliedLayers: appliedLayers,
          fixesAttempted: steps.map((AutonomousApplyStep s) => s.name).toList(),
        ),
      );
      return fail;
    } finally {
      if (_progressId != null) {
        AppOperationProgressService.instance.end(_progressId!);
        _progressId = null;
      }
      _running = false;
    }
  }

  void _step(
    List<AutonomousApplyStep> out,
    String name, {
    required bool ok,
    required String detail,
    Map<String, Object?>? data,
  }) {
    out.add(
      AutonomousApplyStep(name: name, ok: ok, detail: detail, data: data),
    );
  }

  List<String> _failedFromBoot(BootAutofixReport boot) {
    final List<String> out = <String>[];
    if (boot.directVerify != null && !boot.directVerify!.ok) {
      out.add('direct_verify');
    }
    if (boot.triBrowser != null && !boot.triBrowser!.ok) {
      out.add('tri_browser');
    }
    if (boot.error != null) out.add('boot_error');
    if (out.isEmpty) out.add('boot_partial');
    return out;
  }

  List<String> _agentNotesFromSnapshot(Map<String, Object?>? snap) {
    if (snap == null) return const <String>[];
    final Object? notes = snap['agentNotes'];
    if (notes is List) {
      return notes.map((dynamic e) => e.toString()).toList();
    }
    return const <String>[];
  }

  Future<void> _persist(AutonomousApplyReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      final File f = File(reportPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('autonomous_apply persist failed: $e');
    }
  }
}

final class AutonomousApplyStep {
  const AutonomousApplyStep({
    required this.name,
    required this.ok,
    required this.detail,
    this.data,
  });

  final String name;
  final bool ok;
  final String detail;
  final Map<String, Object?>? data;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'ok': ok,
    'detail': detail,
    if (data != null) 'data': data,
  };
}

final class AutonomousApplyReport {
  AutonomousApplyReport({
    required this.at,
    required this.reason,
    required this.ok,
    required this.verdict,
    required this.steps,
    required this.failedLayers,
    required this.appliedLayers,
    required this.durationMs,
    this.youtubeAutofix,
    this.bootAutofix,
    this.selfHeal,
    this.agentNotes = const <String>[],
    this.error,
    this.phase,
    this.stepTimingsMs = const <String, int>{},
  });

  factory AutonomousApplyReport.skipped(String msg) => AutonomousApplyReport(
    at: DateTime.now(),
    reason: 'skipped',
    ok: true,
    verdict: msg,
    steps: const <AutonomousApplyStep>[],
    failedLayers: const <String>[],
    appliedLayers: const <String>[],
    durationMs: 0,
  );

  final DateTime at;
  final String reason;
  final bool ok;
  final String verdict;
  final List<AutonomousApplyStep> steps;
  final List<String> failedLayers;
  final List<String> appliedLayers;
  final int durationMs;
  final YoutubeHostsAutofixReport? youtubeAutofix;
  final BootAutofixReport? bootAutofix;
  final SelfHealReport? selfHeal;
  final List<String> agentNotes;
  final String? error;
  final String? phase;
  final Map<String, int> stepTimingsMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'reason': reason,
    'ok': ok,
    'verdict': verdict,
    'phase': phase,
    'steps': steps.map((AutonomousApplyStep s) => s.toJson()).toList(),
    'failedLayers': failedLayers,
    'appliedLayers': appliedLayers,
    'durationMs': durationMs,
    if (stepTimingsMs.isNotEmpty) 'stepTimingsMs': stepTimingsMs,
    'agentNotes': agentNotes,
    if (error != null) 'error': error,
    if (youtubeAutofix != null) 'youtubeAutofix': youtubeAutofix!.toJson(),
    if (bootAutofix != null) 'bootAutofix': bootAutofix!.toJson(),
    if (selfHeal != null) 'selfHeal': selfHeal!.toJson(),
    'reportPath': AutonomousApplyOrchestratorService.instance.reportPath,
    'cursorFixLog': CursorAgentFixLogService.instance.lastPath,
  };
}
