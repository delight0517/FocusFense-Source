import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/browser_extension_asset_manifest.dart';
import '../router/app_router.dart';
import 'app_logger.dart';
import 'automated_browser_handoff_service.dart';
import 'block_activity_log_service.dart';
import 'block_sync_service.dart';
import 'browser_block_experiment_service.dart';
import 'browser_extension_export_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'crash_journal_service.dart';
import 'cursor_agent_snapshot_service.dart';
import 'extension_rules_builder.dart';
import 'local_database.dart';
import 'usage_ingest_server.dart';
import 'windows_extension_policy_watchdog.dart';
import 'windows_extension_self_heal_service.dart';
import 'youtube_channel_boot_sync_service.dart';
import 'youtube_channel_videos_fetcher_service.dart';
import 'youtube_policy_layer_gap_healer.dart';
import 'youtube_video_block_resolver.dart';

/// 앱이 스스로 규칙을 읽고 YouTube 차단을 감지·실험·알림한다.
final class YoutubeProactiveGuardService {
  YoutubeProactiveGuardService._();
  static final YoutubeProactiveGuardService instance =
      YoutubeProactiveGuardService._();

  static const Duration kInterval = Duration(minutes: 12);
  static const Duration kBootDelay = Duration(seconds: 90);
  static const Duration kAlertCooldown = Duration(minutes: 10);
  static const Duration kExperimentCooldown = Duration(hours: 2);
  static const int kMaxNetworkProbesPerCycle = 2;

  final ValueNotifier<YoutubeProactiveGuardReport?> latest =
      ValueNotifier<YoutubeProactiveGuardReport?>(null);

  Timer? _timer;
  bool _running = false;
  DateTime? _lastAlertAt;
  DateTime? _lastExperimentAt;
  bool _lastCycleOk = true;
  bool _allowBrowserExperiments = true;

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'youtube_proactive_guard_last.json',
  );

  void start({bool allowBrowserExperiments = true}) {
    _allowBrowserExperiments = allowBrowserExperiments;
    if (!Platform.isWindows && !Platform.isMacOS) return;
    _timer?.cancel();
    _timer = Timer.periodic(kInterval, (_) {
      unawaited(
        runCycle(
          reason: 'periodic',
          runExperiments: _allowBrowserExperiments && !_lastCycleOk,
        ),
      );
    });
    Future<void>.delayed(kBootDelay, () {
      unawaited(
        runCycle(reason: 'boot', runExperiments: _allowBrowserExperiments),
      );
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<YoutubeProactiveGuardReport> runCycle({
    String reason = 'manual',
    bool runExperiments = true,
    bool userInitiated = false,
  }) async {
    if (_running) {
      return latest.value ??
          YoutubeProactiveGuardReport(
            at: DateTime.now(),
            reason: reason,
            ok: true,
            verdict: '이전 주기 실행 중',
            ruleChecks: const <YoutubeRuleCheck>[],
            experiments: const <BrowserBlockExperimentResult>[],
            actions: const <String>[],
          );
    }
    _running = true;
    try {
      if (!UsageIngestServer.instance.isRunning) {
        UsageIngestServer.instance.start();
      }

      final List<String> actions = <String>[];

      if (reason == 'boot' || reason == 'post_rebuild' || userInitiated) {
        final int synced = await YoutubeChannelBootSyncService.instance
            .runIfDue(reason: reason, force: userInitiated);
        if (synced > 0) {
          actions.add('boot_channel_sync:$synced');
        }
      }

      ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildForBrowserEnforcement();
      final int policyHealed = await YoutubePolicyLayerGapHealer.instance
          .healFromRules(rules);
      if (policyHealed > 0) {
        actions.add('policy_layer_gap_heal:$policyHealed');
        BlockSyncService.instance.requestApply();
        rules = await ExtensionRulesBuilder.buildForBrowserEnforcement();
      }
      final List<String> probeIds = _collectProbeVideoIds(rules);

      final bool heavyNetwork =
          userInitiated || reason == 'boot' || runExperiments || !_lastCycleOk;
      final int probeLimit = heavyNetwork
          ? probeIds.length
          : kMaxNetworkProbesPerCycle.clamp(1, probeIds.length);

      final List<YoutubeRuleCheck> ruleChecks = <YoutubeRuleCheck>[];
      for (final String vid in probeIds.take(probeLimit)) {
        final YoutubeBlockCheckResult r = await YoutubeVideoBlockResolver
            .instance
            .checkVideo(vid);
        ruleChecks.add(
          YoutubeRuleCheck(
            videoId: vid,
            url: 'https://www.youtube.com/watch?v=$vid',
            shouldBlock: r.blocked,
            rule: r.rule,
            channelHandle: r.channelHandle,
            authorName: r.authorName,
            error: r.error,
          ),
        );
      }

      final List<BrowserBlockExperimentResult> experiments =
          <BrowserBlockExperimentResult>[];

      // When channel rules exist but watch-page resolver says "not blocked",
      // fetch recent videos and push watch?v= into URLBlocklist — the #1 gap
      // for Korean @handles where YouTube serves percent-encoded paths.
      if (rules.hasYoutubeChannelBlocks) {
        final List<YoutubeRuleCheck> watchGaps = ruleChecks
            .where((YoutubeRuleCheck c) => !c.shouldBlock)
            .toList();
        if (watchGaps.isNotEmpty) {
          final int healed = await _healWatchPageGaps(rules, watchGaps);
          if (healed > 0) {
            actions.add('channel_video_autofetch:$healed');
            BlockSyncService.instance.requestApply();
            for (final YoutubeRuleCheck check in watchGaps) {
              final YoutubeBlockCheckResult retry =
                  await YoutubeVideoBlockResolver.instance.checkVideo(
                    check.videoId,
                  );
              final int idx = ruleChecks.indexWhere(
                (YoutubeRuleCheck c) => c.videoId == check.videoId,
              );
              if (idx >= 0) {
                ruleChecks[idx] = YoutubeRuleCheck(
                  videoId: check.videoId,
                  url: check.url,
                  shouldBlock: retry.blocked,
                  rule: retry.rule,
                  channelHandle: retry.channelHandle,
                  authorName: retry.authorName,
                  error: retry.error,
                );
              }
            }
          }
        }
      }

      final List<YoutubeRuleCheck> mustBlockAfterHeal = ruleChecks
          .where((YoutubeRuleCheck c) => c.shouldBlock)
          .toList();

      // Browser experiments OPEN Chrome and Firefox to a YouTube URL and
      // wait for the extension to log a block. That made Chrome / Firefox
      // pop open at random — every boot and every 12-min periodic cycle when
      // the last cycle was unhappy. Now we ONLY run experiments when the
      // user explicitly triggered this cycle (e.g. tapped the diagnostic
      // button). Boot and periodic ticks no longer surprise-launch browsers.
      //
      // See docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md §2.3. DO NOT broaden
      // `mayExperiment` to include `reason == 'boot'` or `!_lastCycleOk` —
      // both made Chrome open without the user asking.
      final bool mayExperiment =
          runExperiments &&
          Platform.isWindows &&
          mustBlockAfterHeal.isNotEmpty &&
          userInitiated;
      final DateTime now = DateTime.now();
      final bool experimentCooldownOk =
          _lastExperimentAt == null ||
          now.difference(_lastExperimentAt!) >= kExperimentCooldown;

      if (mayExperiment && experimentCooldownOk) {
        _lastExperimentAt = now;
        await _ensureExtensionPayload(actions);

        for (final YoutubeRuleCheck check in mustBlockAfterHeal.take(1)) {
          for (final String browser in <String>['chrome', 'firefox']) {
            final BrowserBlockExperimentResult exp =
                await BrowserBlockExperimentService.instance.run(
                  url: check.url,
                  browser: browser,
                  label: check.videoId,
                  expectBlocked: true,
                );
            experiments.add(exp);
          }
        }
      }

      final bool chromeUnprotected =
          Platform.isWindows &&
          (await AutomatedBrowserHandoffService.probeBrowsers())
              .chromeUnprotected;
      final bool experimentsFailed = experiments.any(
        (BrowserBlockExperimentResult e) => !e.ok,
      );

      if (chromeUnprotected) {
        actions.add('chrome_handoff');
        await AutomatedBrowserHandoffService.instance.runZeroTouch(
          reason: 'youtube_guard',
          force: true,
        );
      }

      if (experimentsFailed ||
          (mustBlockAfterHeal.isNotEmpty && chromeUnprotected)) {
        actions.add('extension_self_heal');
        await WindowsExtensionPolicyWatchdog.instance.tick();
        await WindowsExtensionSelfHealService.instance.runSelfHeal(
          attemptElevated: false,
          userInitiated: false,
        );
        BlockSyncService.instance.requestApply();
      }

      final bool ok = !experimentsFailed && !chromeUnprotected;

      if (!ok || userInitiated) {
        unawaited(
          CursorAgentSnapshotService.instance.refresh(
            reason: 'youtube_guard',
            light: ok && !userInitiated,
          ),
        );
      }
      final String verdict = _verdict(
        ok: ok,
        mustBlock: mustBlockAfterHeal,
        experiments: experiments,
        chromeUnprotected: chromeUnprotected,
      );

      final YoutubeProactiveGuardReport report = YoutubeProactiveGuardReport(
        at: DateTime.now(),
        reason: reason,
        ok: ok,
        verdict: verdict,
        ruleChecks: ruleChecks,
        experiments: experiments,
        actions: actions,
      );

      _lastCycleOk = ok;
      latest.value = report;
      await _persist(report);

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: 'YouTube 선제 감지: $verdict',
        data: report.toJson(),
        level: ok ? 'info' : 'warn',
        debounceKey: 'youtube_proactive_guard',
      );

      if (!ok) {
        _maybeAlertUser(report);
      }

      return report;
    } catch (e, st) {
      AppLogger.instance.error(
        'youtube_proactive_guard failed',
        error: e,
        stack: st,
      );
      final YoutubeProactiveGuardReport fail = YoutubeProactiveGuardReport(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        verdict: 'YouTube 선제 감지 오류: $e',
        ruleChecks: const <YoutubeRuleCheck>[],
        experiments: const <BrowserBlockExperimentResult>[],
        actions: const <String>['error'],
      );
      latest.value = fail;
      return fail;
    } finally {
      _running = false;
    }
  }

  List<String> _collectProbeVideoIds(ExtensionRulesPayload rules) {
    final Set<String> ids = <String>{
      ...CursorAgentSnapshotService.kDefaultProbeVideoIds,
      ...YoutubePolicyLayerGapHealer.kMandatoryPolicyVideoIds,
      ...rules.blockedYoutubeVideoIds.map((String v) => v.toLowerCase()),
    };
    for (final String k in rules.keywords) {
      final RegExpMatch? m = RegExp(
        r'[?&]v=([\w-]{6,})',
        caseSensitive: false,
      ).firstMatch(k);
      if (m != null) ids.add(m.group(1)!.toLowerCase());
    }
    return ids.toList()..sort();
  }

  /// Returns count of newly inserted watch?v= rows.
  Future<int> _healWatchPageGaps(
    ExtensionRulesPayload rules,
    List<YoutubeRuleCheck> gaps,
  ) async {
    int inserted = 0;
    for (final YoutubeRuleCheck gap in gaps) {
      final YoutubeVideoResolveResult resolved = await YoutubeVideoBlockResolver
          .instance
          .resolveVideo(gap.videoId);
      final String? handle = resolved.channelHandle?.trim().toLowerCase();
      if (handle == null || handle.isEmpty) continue;

      final Set<String> blockedHandles = <String>{
        ...rules.blockedYoutubeHandles.map(
          (String h) => h.trim().toLowerCase(),
        ),
      };
      for (final String k in rules.keywords) {
        final RegExpMatch? at = RegExp(
          r'youtube\.com/@([^/?#\s]+)',
          caseSensitive: false,
        ).firstMatch(k);
        if (at != null) {
          blockedHandles.add(Uri.decodeComponent(at.group(1)!).toLowerCase());
        }
      }

      if (!blockedHandles.contains(handle)) continue;

      inserted += await YoutubeChannelVideosFetcherService.instance
          .fetchVideoIdsForHandle(handle)
          .then((List<String> vids) async {
            int n = 0;
            for (final String vid in vids) {
              try {
                await LocalDatabase.instance.insertKeyword(
                  id: 'yt_guard_${handle}_$vid',
                  pattern: 'https://www.youtube.com/watch?v=$vid',
                );
                n++;
              } catch (_) {}
            }
            return n;
          });
    }
    if (inserted > 0) {
      AppLogger.instance.info(
        'youtube_proactive_guard: autofetched $inserted watch?v= rows',
      );
    }
    return inserted;
  }

  Future<void> _ensureExtensionPayload(List<String> actions) async {
    if (await ChromeLoadExtensionLauncher.hasValidPayload()) return;
    actions.add('export_extension_assets');
    final BrowserExtensionExportResult export =
        await BrowserExtensionExportService.exportAssets(
          assetPaths: BrowserExtensionAssetManifest.chrome,
          subdirName: BrowserExtensionExportService.kChromeSubdir,
        );
    if (export.ok) {
      await ChromeLoadExtensionLauncher.mirrorExtensionFolder(export.path);
    }
  }

  String _verdict({
    required bool ok,
    required List<YoutubeRuleCheck> mustBlock,
    required List<BrowserBlockExperimentResult> experiments,
    required bool chromeUnprotected,
  }) {
    if (ok && mustBlock.isEmpty) {
      return 'YouTube 규칙 없음 — 점검 완료';
    }
    if (ok) {
      return '차단 규칙 ${mustBlock.length}건 · Chrome/Firefox 실험 통과';
    }
    final List<String> parts = <String>[];
    if (chromeUnprotected) {
      parts.add('Chrome에 확장 없음');
    }
    final int failed = experiments
        .where((BrowserBlockExperimentResult e) => !e.ok)
        .length;
    if (failed > 0) {
      parts.add('브라우저 실험 $failed건 실패');
    }
    if (mustBlock.any(
          (YoutubeRuleCheck c) =>
              c.videoId == 'ebjHn1wY_HA' || c.videoId == 'oYVEqFdjNDs',
        ) &&
        !ok) {
      parts.add('뷰티풀너드 영상 차단 미적용');
    }
    return parts.join(' · ');
  }

  void _maybeAlertUser(YoutubeProactiveGuardReport report) {
    final DateTime now = DateTime.now();
    if (_lastAlertAt != null &&
        now.difference(_lastAlertAt!) < kAlertCooldown) {
      return;
    }
    _lastAlertAt = now;
    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 12),
        backgroundColor: const Color(0xFFB42318),
        content: Text(
          'YouTube 차단 문제 감지: ${report.verdict}\n'
          '설정→진단에서 「YouTube 선제 점검」 확인',
        ),
        action: SnackBarAction(
          label: '지금 점검',
          textColor: Colors.white,
          onPressed: () {
            unawaited(
              instance.runCycle(
                reason: 'user_snack',
                runExperiments: true,
                userInitiated: true,
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _persist(YoutubeProactiveGuardReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      final File f = File(reportPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (_) {}
  }
}

final class YoutubeRuleCheck {
  const YoutubeRuleCheck({
    required this.videoId,
    required this.url,
    required this.shouldBlock,
    this.rule,
    this.channelHandle,
    this.authorName,
    this.error,
  });

  final String videoId;
  final String url;
  final bool shouldBlock;
  final String? rule;
  final String? channelHandle;
  final String? authorName;
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'videoId': videoId,
    'url': url,
    'shouldBlock': shouldBlock,
    if (rule != null) 'rule': rule,
    if (channelHandle != null) 'channelHandle': channelHandle,
    if (authorName != null) 'authorName': authorName,
    if (error != null) 'error': error,
  };
}

final class YoutubeProactiveGuardReport {
  const YoutubeProactiveGuardReport({
    required this.at,
    required this.reason,
    required this.ok,
    required this.verdict,
    required this.ruleChecks,
    required this.experiments,
    required this.actions,
  });

  final DateTime at;
  final String reason;
  final bool ok;
  final String verdict;
  final List<YoutubeRuleCheck> ruleChecks;
  final List<BrowserBlockExperimentResult> experiments;
  final List<String> actions;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'reason': reason,
    'ok': ok,
    'verdict': verdict,
    'ruleChecks': ruleChecks.map((YoutubeRuleCheck c) => c.toJson()).toList(),
    'experiments': experiments
        .map((BrowserBlockExperimentResult e) => e.toJson())
        .toList(),
    'actions': actions,
  };
}
