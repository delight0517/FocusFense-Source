import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'browser_extension_force_install_service.dart';
import 'build_identity_service.dart';
import 'chrome_extension_identity.dart';
import 'chromium_policy_service.dart';
import 'numeric_apex_hosts_gap_healer_service.dart';
import 'universal_browser_block_service.dart';
import 'url_block_hardening_audit_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_extension_policy_watchdog.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_firefox_extension_install_service.dart';
import 'windows_hidden_process.dart';
import 'windows_policy_acl_unlock_service.dart';

/// One-tap orchestrator: runs every layer the block pipeline needs, in the
/// right order, captures per-step results, and writes a structured JSON
/// **failure report** that an external agent (Cursor / Claude / this app
/// next boot) can read to know exactly what is broken and where the code
/// for the broken layer lives.
///
/// Design points:
///
/// * Sequence is fixed and ordered by dependency — ACL unlock first
///   (without it every later write fails), then files on disk, then
///   policies, then URLBlocklist, then verify.
/// * Every step records its **own** status independently. One layer
///   failing does not abort the rest; the report shows the full picture.
/// * Each step in the report carries `codeAnchors`: paths the AI agent
///   should read to fix that specific failure. This is the contract that
///   makes the report actionable.
/// * Report is overwritten on every run (no append) — the file is the
///   *current state*, not a log. The user / agent always sees the latest.
///
/// See `docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md` for the full pipeline.
final class OneTapBlockEverythingService {
  OneTapBlockEverythingService._();
  static final OneTapBlockEverythingService instance =
      OneTapBlockEverythingService._();

  bool _running = false;
  DateTime? _runStartedAt;
  String? _progressRunId;
  String _progressBuildLabel = '';
  void Function(String id, String title, String detail)? _onStepStarted;

  /// If a previous run hung (typically waiting on a UAC dialog the user never
  /// saw or that the system silently dismissed), the `_running` lock would
  /// stay true forever and every subsequent click returned "이미 실행 중".
  /// This window expires the lock so the user can re-trigger.
  static const Duration _kStaleLockWindow = Duration(seconds: 90);

  /// Force-clear the running lock. Exposed for the UI so the user can press
  /// a "리셋" button when they suspect a stuck run.
  void forceResetRunningLock() {
    _running = false;
    _runStartedAt = null;
  }

  /// Where the structured JSON report is written. Stable path so an agent
  /// can read it without hunting for it.
  static String reportPath() {
    final String base = Platform.isWindows
        ? (Platform.environment['LOCALAPPDATA'] ?? r'C:\Users\Public')
        : (Platform.environment['HOME'] ?? '');
    return p.join(base, 'SixVPNBlocker', 'block_everything_report.json');
  }

  /// Live progress log for the latest one-tap run. JSONL: one object per line.
  static String progressLogPath() {
    final String base = Platform.isWindows
        ? (Platform.environment['LOCALAPPDATA'] ?? r'C:\Users\Public')
        : (Platform.environment['HOME'] ?? '');
    return p.join(base, 'SixVPNBlocker', 'block_everything_progress.jsonl');
  }

  /// Run the full pipeline. [onStatus] is called with a Korean
  /// user-facing string after each step so the caller can drive a
  /// progress UI without knowing the internal step names.
  ///
  /// [onElevationHint] fires exactly once, before the first step that may
  /// pop a Windows UAC (administrator) prompt. The UI should use this to
  /// tell the user **in the app** to expect and approve that prompt —
  /// without it, the prompt can appear (or be silently swallowed by AV)
  /// while the user has no idea one was coming.
  Future<OneTapResult> run({
    void Function(String step, OneTapStepStatus status)? onStatus,
    void Function(String id, String title, String detail)? onStepStarted,
    void Function()? onElevationHint,
  }) async {
    if (_running) {
      // Stale-lock detection. A previous click started a run that's been
      // pending for longer than [_kStaleLockWindow] — almost always because
      // the elevated `runElevatedUnlockIfNeeded` is blocked on a UAC dialog
      // that was silently dismissed by AV/EDR or never reached the user.
      // Reclaim the lock and proceed so the user isn't stuck staring at
      // "이미 실행 중".
      if (_runStartedAt != null &&
          DateTime.now().difference(_runStartedAt!) > _kStaleLockWindow) {
        AppLogger.instance.warn(
          'one_tap_block: reclaiming stale lock '
          '(stuck for ${DateTime.now().difference(_runStartedAt!).inSeconds}s)',
        );
        _running = false;
        _runStartedAt = null;
      } else {
        return OneTapResult.alreadyRunning();
      }
    }
    _running = true;
    _runStartedAt = DateTime.now();
    _progressRunId = _runStartedAt!.toIso8601String();
    _onStepStarted = onStepStarted;
    try {
      _progressBuildLabel = await BuildIdentityService.instance.summaryLine();
    } catch (_) {
      _progressBuildLabel = 'unknown';
    }
    await _resetProgressLog();
    await _appendProgressEvent(
      event: 'run_start',
      detail: 'one-tap apply started',
    );
    final List<OneTapStepReport> steps = <OneTapStepReport>[];

    void emit(OneTapStepReport report) {
      steps.add(report);
      onStatus?.call(report.title, report.status);
      AppLogger.instance.info(
        'one_tap_block: ${report.id} → ${report.status.name} '
        '${report.detail.isEmpty ? "" : "— ${report.detail}"}',
      );
    }

    try {
      if (!Platform.isWindows) {
        emit(
          const OneTapStepReport(
            id: 'platform',
            title: 'Windows 전용',
            status: OneTapStepStatus.skipped,
            detail: 'macOS / Linux는 자체 파이프라인 사용',
            codeAnchors: <String>[],
          ),
        );
        return _finish(steps, ok: true);
      }

      // A fresh user-initiated run always gets its own elevation attempt,
      // even if an earlier run this session silently failed (AV/EDR ate
      // the UAC prompt before the user ever saw it).
      WindowsPolicyAclUnlockService.instance.resetAttemptGate();
      // Tell the UI a UAC prompt may be about to appear — before we make
      // the elevation call, not after it silently fails. See [run] doc.
      onElevationHint?.call();

      // ── Step 1: ACL unlock ────────────────────────────────────────────
      await _runStep(
        emit: emit,
        id: 'acl_unlock',
        title: 'HKCU 정책 키 잠금 확인',
        codeAnchors: const <String>[
          'mobile/lib/services/windows_policy_acl_unlock_service.dart',
          'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md#22-hkcusoftwarepolicies-acl-lockdown-the-big-one',
        ],
        body: () async {
          final bool writable = await WindowsPolicyAclUnlockService.instance
              .hkcuPoliciesWritable();
          if (writable) {
            return _OneTapStepOutcome.ok('정책 키 쓰기 가능 — 잠금 없음');
          }
          final bool unlocked = await WindowsPolicyAclUnlockService.instance
              .runElevatedUnlockIfNeeded();
          if (unlocked) {
            return _OneTapStepOutcome.ok('UAC 잠금 해제 성공');
          }
          return _OneTapStepOutcome.failed(
            'HKCU\\SOFTWARE\\Policies가 ACL 잠금 상태이며 UAC 거부됨. '
            'reg.exe 쓰기가 모두 실패하므로 forcelist·URLBlocklist 미적용.',
            suggestedFix:
                '사용자에게 다시 「예」를 누르도록 안내하고 재실행. '
                '또는 관리자 권한으로 앱 실행.',
            machineState: <String, Object?>{
              'hkcuPoliciesWritable': false,
              'elevationDeclined': true,
            },
          );
        },
      );

      // ── Step 2: extension files on disk ───────────────────────────────
      await _runStep(
        emit: emit,
        id: 'extension_files',
        title: '확장 파일 디스크 배포',
        codeAnchors: const <String>[
          'mobile/lib/services/browser_extension_export_service.dart',
          'mobile/lib/services/chrome_extension_payload_service.dart',
        ],
        body: () async {
          final List<String> candidates = <String>[
            p.join(
              Platform.environment['LOCALAPPDATA'] ?? '',
              'SixVPNBlocker',
              'chrome_blocker',
              'manifest.json',
            ),
            p.join(
              Platform.environment['ProgramData'] ?? r'C:\ProgramData',
              'SixVPNBlocker',
              'chrome_blocker',
              'manifest.json',
            ),
          ];
          for (final String c in candidates) {
            if (await File(c).exists()) {
              return _OneTapStepOutcome.ok(
                '확장 파일 정상 → ${p.dirname(c)}',
                machineState: <String, Object?>{'manifestPath': c},
              );
            }
          }
          return _OneTapStepOutcome.failed(
            '확장 파일이 디스크에 없음. 다음 단계에서 강제 설치가 재배포 시도.',
          );
        },
      );

      // ── Step 3: force install (Chrome + Edge + Firefox) ───────────────
      await _runStep(
        emit: emit,
        id: 'force_install',
        title: '확장 강제 설치 (Chrome · Edge · Firefox)',
        codeAnchors: const <String>[
          'mobile/lib/services/browser_extension_force_install_service.dart',
          'mobile/lib/services/windows_extension_self_heal_service.dart',
        ],
        body: () async {
          WindowsExtensionGuardService.invalidateVerifyCache();
          final ExtensionPolicyVerifyResult before =
              await WindowsExtensionGuardService.verifyAllPolicies(force: true);
          final bool chromeReadyBefore =
              before.chromeEnforcementReady ||
              before.chromeForcelistOk ||
              before.chromeHkcuForcelistOk;
          final bool edgeReadyBefore =
              before.edgeEnforcementReady ||
              before.edgeForcelistOk ||
              before.edgeHkcuForcelistOk;
          if (chromeReadyBefore && edgeReadyBefore) {
            return _OneTapStepOutcome.ok(
              'Chrome · Edge 정책 이미 적용됨 — 무거운 재설치 건너뜀',
              machineState: <String, Object?>{
                'fastPath': true,
                'chromeReady': chromeReadyBefore,
                'edgeReady': edgeReadyBefore,
                'chromeForcelistOk': before.chromeForcelistOk,
                'chromeHkcuForcelistOk': before.chromeHkcuForcelistOk,
                'edgeForcelistOk': before.edgeForcelistOk,
                'edgeHkcuForcelistOk': before.edgeHkcuForcelistOk,
              },
            );
          }

          BrowserExtensionForceInstallReport? r;
          try {
            r = await BrowserExtensionForceInstallService.instance
                .installAll(
                  reason: 'one_tap',
                  force: true,
                  userInitiated: true,
                  attemptElevated: true,
                )
                .timeout(const Duration(seconds: 50));
          } on TimeoutException {
            WindowsExtensionGuardService.invalidateVerifyCache();
            final ExtensionPolicyVerifyResult v =
                await WindowsExtensionGuardService.verifyAllPolicies(
                  force: true,
                );
            final bool chromeReady =
                v.chromeEnforcementReady ||
                v.chromeForcelistOk ||
                v.chromeHkcuForcelistOk;
            final bool edgeReady =
                v.edgeEnforcementReady ||
                v.edgeForcelistOk ||
                v.edgeHkcuForcelistOk;
            if (chromeReady && edgeReady) {
              return _OneTapStepOutcome.ok(
                '권한 보조 작업은 응답 없음 — 하지만 Chrome · Edge 정책은 이미 적용됨',
                machineState: <String, Object?>{
                  'timeoutSeconds': 50,
                  'chromeReady': chromeReady,
                  'edgeReady': edgeReady,
                  'chromeForcelistOk': v.chromeForcelistOk,
                  'chromeHkcuForcelistOk': v.chromeHkcuForcelistOk,
                  'edgeForcelistOk': v.edgeForcelistOk,
                  'edgeHkcuForcelistOk': v.edgeHkcuForcelistOk,
                },
              );
            }
            return _OneTapStepOutcome.failed(
              '권한 보조 작업 시간 초과 — Chrome/Edge 정책도 아직 확인되지 않음',
              machineState: <String, Object?>{
                'timeoutSeconds': 50,
                'chromeReady': chromeReady,
                'edgeReady': edgeReady,
              },
            );
          }
          final BrowserExtensionForceInstallReport report = r;
          if (report.ok) {
            return _OneTapStepOutcome.ok(
              report.verdict,
              machineState: <String, Object?>{'actions': report.actions},
            );
          }
          return _OneTapStepOutcome.failed(
            report.verdict,
            machineState: <String, Object?>{
              'actions': report.actions,
              'verify': report.verify == null
                  ? null
                  : <String, Object?>{
                      'chromeOk': report.verify!.chromeOk,
                      'edgeOk': report.verify!.edgeOk,
                      'firefoxOk': report.verify!.firefoxPolicyOk,
                      'chromeHkcuForcelistOk':
                          report.verify!.chromeHkcuForcelistOk,
                      'edgeHkcuForcelistOk': report.verify!.edgeHkcuForcelistOk,
                    },
            },
          );
        },
      );

      // ── Step 4: re-apply HKCU policies (forcelist + settings + dev mode)
      await _runStep(
        emit: emit,
        id: 'hkcu_policies',
        title: 'HKCU 정책 (force-install + 개발자 모드 잠금)',
        codeAnchors: const <String>[
          'mobile/lib/services/windows_extension_self_heal_service.dart',
          'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md#24-self-heal-was-gated-on-the-wrong-condition',
        ],
        body: () async {
          final String? source = await _findExtensionSource();
          if (source == null) {
            return _OneTapStepOutcome.failed('확장 소스 폴더 없음 — 강제 설치 단계 실패 결과.');
          }
          await WindowsExtensionSelfHealService.instance.reapplyHkcuOnly(
            sourceFolder: source,
          );
          WindowsExtensionGuardService.invalidateVerifyCache();
          final ExtensionPolicyVerifyResult v =
              await WindowsExtensionGuardService.verifyAllPolicies(force: true);
          final bool forcelistOk =
              v.chromeHkcuForcelistOk || v.chromeForcelistOk
              ? (v.edgeHkcuForcelistOk || v.edgeForcelistOk)
              : false;
          if (forcelistOk) {
            return _OneTapStepOutcome.ok('Chrome · Edge forcelist 적용됨');
          }
          return _OneTapStepOutcome.failed(
            'HKCU forcelist 적용 후에도 검증 실패. '
            r'ACL 잠금이 여전히 살아있을 가능성.',
            machineState: <String, Object?>{
              'chromeForcelistOk': v.chromeForcelistOk,
              'chromeHkcuForcelistOk': v.chromeHkcuForcelistOk,
              'edgeForcelistOk': v.edgeForcelistOk,
              'edgeHkcuForcelistOk': v.edgeHkcuForcelistOk,
            },
          );
        },
      );

      // ── Step 5: URLBlocklist + PAC ────────────────────────────────────
      await _runStep(
        emit: emit,
        id: 'url_blocklist',
        title: 'URLBlocklist · PAC 동기화',
        codeAnchors: const <String>[
          'mobile/lib/services/universal_browser_block_service.dart',
          'mobile/lib/services/windows_hkcu_policy_service.dart',
          'mobile/lib/services/chromium_policy_service.dart',
        ],
        body: () async {
          final List<String> expectedBefore =
              await ChromiumPolicyService.activeBlocklistPatterns();
          final List<String> appliedBefore =
              await _readHkcuUrlBlocklistEntries();
          final int requiredBefore = expectedBefore.length > 1000
              ? 1000
              : expectedBefore.length;
          final Set<String> appliedSetBefore = appliedBefore.toSet();
          final bool alreadyCurrent =
              requiredBefore > 0 &&
              expectedBefore
                  .take(requiredBefore)
                  .every(appliedSetBefore.contains);
          if (alreadyCurrent) {
            return _OneTapStepOutcome.ok(
              'URLBlocklist 이미 최신 — 무거운 동기화 건너뜀',
              machineState: <String, Object?>{
                'fastPath': true,
                'patternsExpected': expectedBefore.length,
                'patternsRequired': requiredBefore,
                'patternsApplied': appliedBefore.length,
              },
            );
          }

          // 120s: writing up to 1000 URLBlocklist patterns per browser
          // (Chrome/Edge/derivatives/Firefox) through a single PowerShell
          // process is genuinely slow at that volume — this was previously
          // 50s, which cut the worker off mid-write on real machines
          // (verified: registry left with an incomplete pattern count,
          // not a UAC hang — HKCU needs no elevation at all). Must stay
          // below `_kStepTimeout` (150s) so the outer wrapper doesn't fire
          // first and swallow this step's own timeout handling below.
          UniversalBlockResult? r;
          try {
            r = await UniversalBrowserBlockService.instance
                .syncNow(reason: 'one_tap')
                .timeout(const Duration(seconds: 120));
          } on TimeoutException {
            final List<String> expected =
                await ChromiumPolicyService.activeBlocklistPatterns();
            final List<String> applied = await _readHkcuUrlBlocklistEntries();
            final int requiredCount = expected.length > 1000
                ? 1000
                : expected.length;
            final Set<String> appliedSet = applied.toSet();
            final bool currentAfterTimeout =
                requiredCount > 0 &&
                expected.take(requiredCount).every(appliedSet.contains);
            if (currentAfterTimeout) {
              return _OneTapStepOutcome.ok(
                'URLBlocklist worker timed out, but registry is already current',
                machineState: <String, Object?>{
                  'timeoutSeconds': 120,
                  'patternsExpected': expected.length,
                  'patternsRequired': requiredCount,
                  'patternsApplied': applied.length,
                },
              );
            }
            return _OneTapStepOutcome.failed(
              'URLBlocklist worker timed out and registry entries are incomplete',
              machineState: <String, Object?>{
                'timeoutSeconds': 120,
                'patternsExpected': expected.length,
                'patternsRequired': requiredCount,
                'patternsApplied': applied.length,
              },
            );
          }
          // Cross-check by re-reading the registry.
          final List<String> expected =
              await ChromiumPolicyService.activeBlocklistPatterns();
          final int actual = await _countHkcuUrlBlocklistEntries();
          final UniversalBlockResult report = r;
          final int requiredCount = expected.length > 1000
              ? 1000
              : expected.length;
          if (report.ok && actual >= requiredCount && actual > 0) {
            return _OneTapStepOutcome.ok(
              'URLBlocklist 적용 — $actual개 패턴',
              machineState: <String, Object?>{
                'patternsExpected': expected.length,
                'patternsRequired': requiredCount,
                'patternsApplied': actual,
              },
            );
          }
          if (expected.isEmpty) {
            return _OneTapStepOutcome.ok(
              '차단 키워드 없음 — URLBlocklist 비움이 정상',
              machineState: <String, Object?>{'patternsExpected': 0},
            );
          }
          return _OneTapStepOutcome.failed(
            'URLBlocklist 적용 실패. '
            '예상 ${expected.length}개, 실제 $actual개. '
            'reg.exe 쓰기가 ACL 잠금으로 막혔거나 syncNow 자체가 실패.',
            machineState: <String, Object?>{
              'syncOk': report.ok,
              'syncMessage': report.message,
              'patternsExpected': expected.length,
              'patternsRequired': requiredCount,
              'patternsApplied': actual,
            },
          );
        },
      );

      // ── Step 6: Firefox profile XPI ───────────────────────────────────
      await _runStep(
        emit: emit,
        id: 'firefox_profiles',
        title: 'Firefox 프로필 XPI 사이드로드',
        codeAnchors: const <String>[
          'mobile/lib/services/windows_firefox_extension_install_service.dart',
          'mobile/lib/services/firefox_xpi_packager.dart',
        ],
        body: () async {
          final FirefoxInstallVerifyResult v =
              await WindowsFirefoxExtensionInstallService.verify();
          if (v.profileTotal == 0) {
            return _OneTapStepOutcome.skipped('Firefox 프로필 없음 — 미설치 PC');
          }
          if (v.profileCount > 0) {
            return _OneTapStepOutcome.ok(
              'XPI 사이드로드 ${v.profileCount}/${v.profileTotal} 프로필',
            );
          }
          return _OneTapStepOutcome.failed(
            'Firefox 프로필 ${v.profileTotal}개 중 0개에 XPI 적용. '
            'XPI 파일이 ProgramData에 없거나 프로필 폴더 쓰기 권한 문제.',
            machineState: <String, Object?>{
              'policiesOk': v.policiesOk,
              'xpiInProgramData': v.xpiInProgramData,
              'profileCount': v.profileCount,
              'profileTotal': v.profileTotal,
            },
          );
        },
      );

      // ── Step 7: final per-layer verify ────────────────────────────────
      await _runStep(
        emit: emit,
        id: 'numeric_hosts_dns_repair',
        title: '숫자 우회 도메인 hosts/DNS 복구',
        codeAnchors: const <String>[
          'mobile/lib/services/numeric_apex_hosts_gap_healer_service.dart',
          'mobile/lib/services/windows_system_block_service.dart',
        ],
        timeout: const Duration(minutes: 5),
        body: () async {
          final List<String> probeHosts = await NumericApexHostsGapHealerService
              .instance
              .priorityProbeHosts(maxHosts: 8);
          final List<String> hostsLeaks = await NumericApexHostsGapHealerService
              .instance
              .findHostsFileLeaks(hosts: probeHosts);
          final List<String> dnsLeaks = await NumericApexHostsGapHealerService
              .instance
              .findDnsLeaks(hosts: probeHosts);
          if (hostsLeaks.isEmpty && dnsLeaks.isEmpty) {
            return _OneTapStepOutcome.ok(
              '숫자 우회 도메인 DNS sinkhole 정상',
              machineState: <String, Object?>{
                'probeHosts': probeHosts,
                'hostsLeaksBefore': hostsLeaks,
                'dnsLeaksBefore': dnsLeaks,
              },
            );
          }
          final NumericApexHostsHealReport report =
              await NumericApexHostsGapHealerService.instance.healIfNeeded(
                reason: 'one_tap_numeric_hosts_dns',
                force: true,
                allowElevatedHosts: true,
              );
          if (report.reason == 'skipped' &&
              report.message.toLowerCase().contains('실행')) {
            return _OneTapStepOutcome.failed(
              '숫자 우회 DNS 복구가 이미 실행 중이라 이번 원탭에서 완료 확인을 못 했습니다.',
              machineState: report.toJson(),
              suggestedFix: '잠시 후 다시 누르거나, 진행 로그를 복사해서 원인을 확인해주세요.',
            );
          }
          if (report.ok) {
            return _OneTapStepOutcome.ok(
              report.message,
              machineState: report.toJson(),
            );
          }
          return _OneTapStepOutcome.failed(
            report.message,
            machineState: report.toJson(),
            suggestedFix: '관리자 권한 승인 창에서 「예」를 누른 뒤 다시 적용해주세요.',
          );
        },
      );

      await _runStep(
        emit: emit,
        id: 'url_block_hardening_15',
        title: 'URL 차단 실패 구멍 15개 자동 봉쇄',
        codeAnchors: const <String>[
          'mobile/lib/services/url_block_hardening_audit_service.dart',
          'mobile/lib/services/universal_browser_block_service.dart',
          'mobile/lib/services/numeric_apex_hosts_gap_healer_service.dart',
          'mobile/lib/services/windows_browser_bypass_closer_service.dart',
        ],
        timeout: const Duration(minutes: 3),
        body: () async {
          final UrlBlockHardeningReport report =
              await UrlBlockHardeningAuditService.instance.auditAndRepair(
                reason: 'one_tap',
              );
          final String summary =
              '${report.passedCount}/15 통과, 핵심 실패 ${report.criticalFailedCount}개';
          if (report.ok) {
            return _OneTapStepOutcome.ok(
              'URL 차단 실패 구멍 점검 완료 — $summary',
              machineState: report.toJson(),
            );
          }
          return _OneTapStepOutcome.failed(
            'URL 차단 구멍이 아직 남아 있습니다 — $summary',
            machineState: report.toJson(),
            suggestedFix:
                '진행 로그를 복사해 주세요. 실패 항목별로 어떤 계층(URLBlocklist/hosts/DNS/PAC/브라우저)이 남았는지 포함됩니다.',
          );
        },
      );

      await _runStep(
        emit: emit,
        id: 'final_verify',
        title: '최종 검증 (브라우저별 차단 가능 상태)',
        codeAnchors: const <String>[
          'mobile/lib/services/windows_extension_guard_service.dart',
          'mobile/lib/services/windows_extension_policy_watchdog.dart',
          'mobile/lib/services/numeric_apex_hosts_gap_healer_service.dart',
        ],
        body: () async {
          WindowsExtensionGuardService.invalidateVerifyCache();
          final ExtensionPolicyVerifyResult v =
              await WindowsExtensionGuardService.verifyAllPolicies(force: true);
          final List<String> numericProbeHosts = Platform.isWindows
              ? await NumericApexHostsGapHealerService.instance
                    .priorityProbeHosts(maxHosts: 8)
              : const <String>[];
          final List<String> hostsLeaks = Platform.isWindows
              ? await NumericApexHostsGapHealerService.instance
                    .findHostsFileLeaks(hosts: numericProbeHosts)
              : const <String>[];
          final List<String> dnsLeaks = Platform.isWindows
              ? await NumericApexHostsGapHealerService.instance.findDnsLeaks(
                  hosts: numericProbeHosts,
                )
              : const <String>[];
          final List<String> missing = <String>[
            if (!v.chromeEnforcementReady) 'chrome',
            if (!v.edgeEnforcementReady) 'edge',
            if (!v.firefoxEnforcementReady) 'firefox',
            if (hostsLeaks.isNotEmpty) 'hosts:${hostsLeaks.first}',
            if (dnsLeaks.isNotEmpty) 'dns:${dnsLeaks.first}',
          ];
          if (missing.isEmpty) {
            return _OneTapStepOutcome.ok(
              'Chrome · Edge · Firefox 모두 차단 가능 상태',
              machineState: <String, Object?>{
                'chromeOk': true,
                'edgeOk': true,
                'firefoxOk': true,
                'numericProbeHosts': numericProbeHosts,
                'hostsLeaks': hostsLeaks,
                'dnsLeaks': dnsLeaks,
              },
            );
          }
          return _OneTapStepOutcome.failed(
            '미완료: ${missing.join(" · ")} — 보조 단계의 실패 사유 참조.',
            machineState: <String, Object?>{
              'chromeOk': v.chromeEnforcementReady,
              'edgeOk': v.edgeEnforcementReady,
              'firefoxOk': v.firefoxEnforcementReady,
              'chromeForcelistOk':
                  v.chromeForcelistOk || v.chromeHkcuForcelistOk,
              'edgeForcelistOk': v.edgeForcelistOk || v.edgeHkcuForcelistOk,
              'urlBlocklistCount': await _countHkcuUrlBlocklistEntries(),
              'numericProbeHosts': numericProbeHosts,
              'hostsLeaks': hostsLeaks,
              'dnsLeaks': dnsLeaks,
            },
            suggestedFix:
                'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md §3 의 파이프라인 그림 '
                '에서 미완료 브라우저별로 어느 정책이 안 박혔는지 확인. '
                'ACL 잠금이 가장 흔한 원인.',
          );
        },
      );

      // ── Wake the policy watchdog so it picks up any partial fix ──────
      unawaited(WindowsExtensionPolicyWatchdog.instance.tick());

      final bool ok = steps.every(
        (OneTapStepReport s) =>
            s.status == OneTapStepStatus.ok ||
            s.status == OneTapStepStatus.skipped,
      );
      return _finish(steps, ok: ok);
    } catch (e, st) {
      AppLogger.instance.error('one_tap_block crashed', error: e);
      AppLogger.instance.log('DEBUG', 'one_tap_block stack', stack: st);
      emit(
        OneTapStepReport(
          id: 'orchestrator_crash',
          title: '오케스트레이터 예외',
          status: OneTapStepStatus.failed,
          detail: '$e',
          codeAnchors: const <String>[
            'mobile/lib/services/one_tap_block_everything_service.dart',
          ],
          machineState: <String, Object?>{
            'stack': st.toString().split('\n').take(15).join('\n'),
          },
        ),
      );
      return _finish(steps, ok: false);
    } finally {
      await _appendProgressEvent(
        event: 'run_unlock',
        detail: 'one-tap lock released',
      );
      _running = false;
      _runStartedAt = null;
      _onStepStarted = null;
    }
  }

  /// Hard ceiling per step so the whole pipeline never hangs forever on a
  /// single sub-process that's blocked (waiting for UAC, network call to a
  /// dead host, etc.). The user reported "실행 중…" stuck for 3+ minutes;
  /// in practice each step takes <10s when not hung.
  ///
  /// Bumped 60s -> 150s: the `url_blocklist` step writes up to 1000
  /// URLBlocklist patterns per browser (Chrome/Edge/derivatives/Firefox)
  /// via a single PowerShell process — no UAC involved (HKCU is
  /// user-writable), but the sheer registry-write volume can legitimately
  /// take more than 60s. The step's own inner timeout is 120s (see
  /// `url_blocklist`'s `.timeout()` call) — this outer ceiling must stay
  /// above that or it cuts the inner one off before it ever gets to
  /// report its own result.
  static const Duration _kStepTimeout = Duration(seconds: 150);

  Future<void> _resetProgressLog() async {
    try {
      final File f = File(progressLogPath());
      await f.parent.create(recursive: true);
      await f.writeAsString('', flush: true);
    } catch (e) {
      AppLogger.instance.warn('one_tap_progress reset failed: $e');
    }
  }

  Future<void> _appendProgressEvent({
    required String event,
    String? stepId,
    String? title,
    String? status,
    String? detail,
    int? elapsedMs,
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    try {
      final File f = File(progressLogPath());
      await f.parent.create(recursive: true);
      final Map<String, Object?> row = <String, Object?>{
        'at': DateTime.now().toIso8601String(),
        'runId': _progressRunId,
        'build': _progressBuildLabel,
        'event': event,
      };
      if (stepId != null) row['stepId'] = stepId;
      if (title != null) row['title'] = title;
      if (status != null) row['status'] = status;
      if (detail != null) row['detail'] = detail;
      if (elapsedMs != null) row['elapsedMs'] = elapsedMs;
      if (extra.isNotEmpty) row['extra'] = extra;
      await f.writeAsString(
        '${jsonEncode(row)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('one_tap_progress append failed: $e');
    }
  }

  Future<void> _runStep({
    required void Function(OneTapStepReport) emit,
    required String id,
    required String title,
    required List<String> codeAnchors,
    required Future<_OneTapStepOutcome> Function() body,
    Duration? timeout,
  }) async {
    final DateTime started = DateTime.now();
    final Duration stepTimeout = timeout ?? _kStepTimeout;
    _onStepStarted?.call(id, title, '시작됨 · 제한 ${stepTimeout.inSeconds}초');
    await _appendProgressEvent(
      event: 'step_start',
      stepId: id,
      title: title,
      detail: 'timeout=${stepTimeout.inSeconds}s',
    );
    try {
      final _OneTapStepOutcome outcome = await body().timeout(
        stepTimeout,
        onTimeout: () => _OneTapStepOutcome.failed(
          '단계 시간 초과 (${stepTimeout.inSeconds}초). '
          '하위 프로세스가 응답하지 않음 — UAC 대화상자가 사라졌거나 '
          '레지스트리 접근이 막혀있을 가능성. 다음 단계로 진행.',
          suggestedFix:
              '관리자 권한으로 실행 중인 6VPN_FIX.cmd로 ACL 잠금을 먼저 해제하고 '
              '다시 「지금 모두 적용」을 눌러주세요.',
          machineState: <String, Object?>{
            'timeoutSeconds': stepTimeout.inSeconds,
            'stepId': id,
          },
        ),
      );
      emit(
        OneTapStepReport(
          id: id,
          title: title,
          status: outcome.status,
          detail: outcome.detail,
          codeAnchors: codeAnchors,
          machineState: outcome.machineState,
          suggestedFix: outcome.suggestedFix,
          durationMs: DateTime.now().difference(started).inMilliseconds,
        ),
      );
      await _appendProgressEvent(
        event: 'step_finish',
        stepId: id,
        title: title,
        status: outcome.status.name,
        detail: outcome.detail,
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
        extra: <String, Object?>{
          if (outcome.machineState.isNotEmpty)
            'machineState': outcome.machineState,
          if (outcome.suggestedFix != null)
            'suggestedFix': outcome.suggestedFix,
        },
      );
    } catch (e, st) {
      emit(
        OneTapStepReport(
          id: id,
          title: title,
          status: OneTapStepStatus.failed,
          detail: '단계 실행 중 예외: $e',
          codeAnchors: codeAnchors,
          machineState: <String, Object?>{
            'stack': st.toString().split('\n').take(8).join('\n'),
          },
          durationMs: DateTime.now().difference(started).inMilliseconds,
        ),
      );
      await _appendProgressEvent(
        event: 'step_exception',
        stepId: id,
        title: title,
        status: OneTapStepStatus.failed.name,
        detail: '$e',
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
        extra: <String, Object?>{
          'stack': st.toString().split('\n').take(8).join('\n'),
        },
      );
    }
  }

  Future<OneTapResult> _finish(
    List<OneTapStepReport> steps, {
    required bool ok,
  }) async {
    final OneTapResult result = OneTapResult(
      ok: ok,
      steps: steps,
      finishedAt: DateTime.now(),
    );
    await _appendProgressEvent(
      event: 'run_finish',
      status: ok ? 'ok' : 'failed',
      detail: ok
          ? 'all one-tap steps completed'
          : '${result.failedCount} one-tap step(s) failed',
      extra: <String, Object?>{
        'failedCount': result.failedCount,
        'okCount': result.okCount,
        'reportPath': reportPath(),
        'progressLogPath': progressLogPath(),
      },
    );
    await _writeReport(result);
    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.selfHeal,
      message: ok ? '원탭 차단 — 모든 단계 OK' : '원탭 차단 — 실패한 단계 있음 (리포트 참조)',
      data: result.toJson(),
      level: ok ? 'info' : 'warn',
      debounceKey: 'one_tap_block',
    );
    return result;
  }

  Future<void> _writeReport(OneTapResult r) async {
    try {
      final File f = File(reportPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(r.toJson()),
        flush: true,
      );
      AppLogger.instance.info('one_tap_block: report written → ${f.path}');
    } catch (e) {
      AppLogger.instance.warn('one_tap_block: report write failed: $e');
    }
  }

  Future<String?> _findExtensionSource() async {
    final List<String> candidates = <String>[
      WindowsExtensionSelfHealService.localChromeBlockerDir,
      p.join(
        Platform.environment['USERPROFILE'] ?? '',
        'Documents',
        'SixVPN_Extensions',
        'chrome_blocker',
      ),
      p.join(
        Platform.environment['ProgramData'] ?? r'C:\ProgramData',
        'SixVPNBlocker',
        'chrome_blocker',
      ),
    ];
    for (final String c in candidates) {
      if (await File(p.join(c, 'manifest.json')).exists()) return c;
    }
    return null;
  }

  Future<int> _countHkcuUrlBlocklistEntries() async {
    return (await _readHkcuUrlBlocklistEntries()).length;
  }

  Future<List<String>> _readHkcuUrlBlocklistEntries() async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String regExe = p.join(windir, 'System32', 'reg.exe');
    try {
      final ProcessResult pr = await windowsRunHidden(regExe, <String>[
        'query',
        r'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
      ]);
      if (pr.exitCode != 0) return const <String>[];
      // reg.exe `query` output lists one value per line — count REG_SZ rows.
      final String out = '${pr.stdout}';
      final RegExp re = RegExp(
        r'^\s+\S+\s+REG_SZ\s+(.+?)\s*$',
        multiLine: true,
      );
      return re
          .allMatches(out)
          .map((RegExpMatch m) => (m.group(1) ?? '').trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }
}

enum OneTapStepStatus { ok, failed, skipped }

class OneTapStepReport {
  const OneTapStepReport({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
    required this.codeAnchors,
    this.machineState = const <String, Object?>{},
    this.suggestedFix,
    this.durationMs,
  });

  final String id;
  final String title;
  final OneTapStepStatus status;
  final String detail;

  /// File paths an external agent should READ to fix this specific failure.
  /// Stable contract: if a step fails, the listed files are the ones whose
  /// logic / config controls that step's behaviour.
  final List<String> codeAnchors;

  /// Machine-readable extra state — the raw booleans, counts, paths the
  /// agent needs to decide what to do without re-running diagnostics.
  final Map<String, Object?> machineState;

  /// Human-readable hint (also helpful to AI agents).
  final String? suggestedFix;

  final int? durationMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'status': status.name,
    'detail': detail,
    'codeAnchors': codeAnchors,
    if (machineState.isNotEmpty) 'machineState': machineState,
    if (suggestedFix != null) 'suggestedFix': suggestedFix,
    if (durationMs != null) 'durationMs': durationMs,
  };
}

class OneTapResult {
  const OneTapResult({
    required this.ok,
    required this.steps,
    required this.finishedAt,
  });

  factory OneTapResult.alreadyRunning() => OneTapResult(
    ok: false,
    steps: const <OneTapStepReport>[
      OneTapStepReport(
        id: 'already_running',
        title: '이미 실행 중',
        status: OneTapStepStatus.failed,
        detail: '원탭 실행이 이미 진행 중이므로 중복 실행 거부.',
        codeAnchors: <String>[
          'mobile/lib/services/one_tap_block_everything_service.dart',
        ],
      ),
    ],
    finishedAt: null,
  );

  final bool ok;
  final List<OneTapStepReport> steps;
  final DateTime? finishedAt;

  int get failedCount => steps
      .where((OneTapStepReport s) => s.status == OneTapStepStatus.failed)
      .length;

  int get okCount => steps
      .where((OneTapStepReport s) => s.status == OneTapStepStatus.ok)
      .length;

  Map<String, Object?> toJson() => <String, Object?>{
    // Schema marker — bump when we change the shape so agents can detect.
    'schemaVersion': 1,
    'reportKind': 'six_vpn_block_everything_report',
    'docsRef': 'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md',
    'ok': ok,
    'failedCount': failedCount,
    'okCount': okCount,
    'finishedAt': finishedAt?.toIso8601String(),
    'extensionId': ChromeExtensionIdentity.extensionId,
    'host': Platform.localHostname,
    'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'progressLogPath': OneTapBlockEverythingService.progressLogPath(),
    'steps': steps.map((OneTapStepReport s) => s.toJson()).toList(),
    // Top-level "if you're an agent reading this file, here's where to
    // look first" hint. Mirrored from per-step anchors for convenience.
    'agentHints': <String, Object?>{
      'primaryDoc': 'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md',
      'failureModes': <String>[
        'Non-ASCII handle URL encoding (§2.1)',
        'HKCU\\Policies ACL lockdown (§2.2 — most common silent failure)',
        'Random browser launches (§2.3)',
        'Self-heal wrong gate (§2.4)',
      ],
      'failedSteps': steps
          .where((OneTapStepReport s) => s.status == OneTapStepStatus.failed)
          .map(
            (OneTapStepReport s) => <String, Object?>{
              'id': s.id,
              'codeAnchors': s.codeAnchors,
              'suggestedFix': s.suggestedFix,
            },
          )
          .toList(),
    },
  };
}

class _OneTapStepOutcome {
  const _OneTapStepOutcome._({
    required this.status,
    required this.detail,
    this.machineState = const <String, Object?>{},
    this.suggestedFix,
  });

  factory _OneTapStepOutcome.ok(
    String detail, {
    Map<String, Object?> machineState = const <String, Object?>{},
  }) => _OneTapStepOutcome._(
    status: OneTapStepStatus.ok,
    detail: detail,
    machineState: machineState,
  );

  factory _OneTapStepOutcome.failed(
    String detail, {
    Map<String, Object?> machineState = const <String, Object?>{},
    String? suggestedFix,
  }) => _OneTapStepOutcome._(
    status: OneTapStepStatus.failed,
    detail: detail,
    machineState: machineState,
    suggestedFix: suggestedFix,
  );

  factory _OneTapStepOutcome.skipped(String detail) =>
      _OneTapStepOutcome._(status: OneTapStepStatus.skipped, detail: detail);

  final OneTapStepStatus status;
  final String detail;
  final Map<String, Object?> machineState;
  final String? suggestedFix;
}
