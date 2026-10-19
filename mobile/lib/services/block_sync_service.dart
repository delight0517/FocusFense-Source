import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../enforcement/enforcement_controller.dart';
import '../enforcement/enforcement_layer.dart';
import '../models/active_app_block_entry.dart';
import '../models/block_app.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'block_apply_prefs.dart';
import 'local_database.dart';
import 'active_app_block_registry_service.dart';
import 'boot_apply_idempotency_service.dart';
import 'mac_app_block_service.dart';
import 'mac_system_block_service.dart';
import 'usage_quota_enforcer_service.dart';
import 'work_context_tracker.dart';
import 'quick_block_session_service.dart';
import 'windows_app_block_service.dart';
import 'windows_game_app_aliases.dart';
import 'game_daily_budget_service.dart';
import 'locale_controller.dart';
import 'extension_rules_snapshot_service.dart';
import 'universal_browser_block_service.dart';
import 'windows_firewall_block_service.dart';
import 'windows_five_layer_block_service.dart';
import 'windows_five_layer_sync_service.dart';
import 'chrome_core_principles_service.dart';
import 'windows_system_block_service.dart';
import 'windows_protection_mode_prefs.dart';

/// Coalesces "the rule set changed — re-apply the system block" pings into
/// a single debounced re-write of the OS hosts file (`/etc/hosts` on macOS,
/// `%WINDIR%\\System32\\drivers\\etc\\hosts` on Windows). Without this,
/// every keystroke in the schedule editor would trigger an admin prompt.
///
/// Behaviour:
///   * `requestApply()` schedules a re-apply after a short debounce.
///   * Consecutive calls within the debounce window collapse into one.
///   * When the managed block is **already** in the hosts file, debounced
///     applies refresh it without extra prompts (cached admin on macOS).
///   * When the block is **missing** but the DB reports at least one
///     **enabled** domain rule, we still run `activate()` so the first UAC /
///     admin prompt can complete — avoids a deadlock where auto-sync never
///     wrote because `isActive()` was false.
///   * If that first-time elevate fails or is cancelled, a short cooldown
///     suppresses repeated UAC spam until the user fixes the situation.
List<BlockApp> _mergeBlockApps(List<BlockApp> a, List<BlockApp> b) {
  final Map<String, BlockApp> byExe = <String, BlockApp>{};
  for (final BlockApp app in <BlockApp>[...a, ...b]) {
    if (app.exeName.isEmpty) continue;
    byExe[app.exeName] = app;
  }
  return byExe.values.toList();
}

List<ActiveAppBlockEntry> _expandGameAliasEntries(
  List<ActiveAppBlockEntry> entries,
) {
  final Map<String, ActiveAppBlockEntry> byKey =
      <String, ActiveAppBlockEntry>{};
  for (final ActiveAppBlockEntry e in entries) {
    final List<BlockApp> expanded = WindowsGameAppAliases.expand(<BlockApp>[
      e.app,
    ]);
    for (final BlockApp app in expanded) {
      final String key = app.exeName.isNotEmpty
          ? app.exeName
          : 'lt:${(app.windowTitleMatch ?? app.displayName).toLowerCase()}';
      byKey[key] = ActiveAppBlockEntry(app: app, context: e.context);
    }
  }
  return byKey.values.toList();
}

final class BlockSyncService {
  BlockSyncService._();
  static final BlockSyncService instance = BlockSyncService._();

  /// How long to wait after the last `requestApply()` before actually
  /// writing /etc/hosts. macOS caches the osascript admin auth for a few
  /// minutes, so consecutive applies are silent — but we still debounce
  /// to avoid stacking apply jobs on rapid edits.
  static const Duration _kDebounce = Duration(milliseconds: 1500);

  /// After a failed/cancelled first-time hosts elevate, ignore auto-elevate
  /// until this instant (per-process).
  static const Duration _kFirstHostsElevateCooldown = Duration(seconds: 90);

  Timer? _timer;
  bool _running = false;
  bool _enabled = !WindowsProtectionModePrefs.isProtectionExplicitlyOff;
  bool? _deferHostsApplyCache;
  DateTime? _firstHostsElevateCooldownUntil;

  /// True when rules changed but hosts/DNS were not written yet (manual apply).
  final ValueNotifier<bool> hostsApplyPending = ValueNotifier<bool>(false);

  /// Most recent apply result, exposed for the UI status banner. Null
  /// until the first apply runs in this session.
  MacBlockResult? lastResult;

  /// User-visible toggle. When false, calls to `requestApply()` are dropped.
  bool get enabled =>
      _enabled && !WindowsProtectionModePrefs.isProtectionExplicitlyOff;
  set enabled(bool v) => _enabled = v;

  /// Push app-block targets immediately (schedules + active quick-block session).
  void syncAppTargetsNow() {
    if (!enabled) return;
    if (Platform.isMacOS || Platform.isWindows) {
      unawaited(_syncAppTargets());
    }
  }

  /// Schedule a debounced re-apply. Cheap to call from any DB write path.
  ///
  /// Delegates to EnforcementController (5-layer architecture).
  void requestApply() {
    if (!enabled) return;
    if (Platform.isMacOS || Platform.isWindows) {
      hostsApplyPending.value = true;
    }
    EnforcementController.instance.requestApply(reason: 'rules_changed');
  }

  Future<void> _scheduleHostsApplyDebounced() async {
    final bool defer = await _deferHostsApply();
    if (defer) {
      _timer?.cancel();
      hostsApplyPending.value = true;
      return;
    }
    if (Platform.isMacOS) {
      _timer?.cancel();
      _timer = Timer(_kDebounce, () => _flush(force: false));
    } else if (Platform.isWindows) {
      _timer?.cancel();
      _timer = Timer(_kDebounce, () => _flushWindows(force: false));
    }
  }

  Future<bool> _deferHostsApply() async {
    _deferHostsApplyCache ??= await BlockApplyPrefs.instance.deferHostsApply();
    return _deferHostsApplyCache!;
  }

  void refreshDeferHostsApplyCache() {
    _deferHostsApplyCache = null;
  }

  Future<void> _syncAppTargets() async {
    try {
      if (Platform.isMacOS) {
        final List<String> schedule = await LocalDatabase.instance
            .blockedAppsActiveNow(DateTime.now());
        final List<String> quick = await QuickBlockSessionService.instance
            .activeAppExeNames();
        final Set<String> merged = <String>{...schedule, ...quick};
        await MacAppBlockService.instance.setTargets(merged.toList());
      } else if (Platform.isWindows) {
        final List<ActiveAppBlockEntry> entries =
            await ActiveAppBlockRegistryService.instance.activeEntriesNow();
        final now = DateTime.now();
        final quotaLabel = <String, String>{
          'en': 'Daily game time limit', 'ko': '하루 게임 시간 한도',
          'ja': '1日のゲーム時間上限', 'zh': '每日游戏时间上限',
          'he': 'מגבלת זמן משחק יומית', 'ar': 'الحد اليومي لوقت اللعب',
        }[LocaleController.instance.locale.languageCode] ?? 'Daily game time limit';
        final gameEntries = GameDailyBudgetService.instance.lockedTargets.map(
          (exe) => ActiveAppBlockEntry(
            app: BlockApp(exeName: exe, displayName: exe),
            context: AppBlockContext(
              source: AppBlockSource.maintenance,
              scheduleLabels: [quotaLabel],
              endsAt: DateTime(now.year, now.month, now.day + 1),
            ),
          ),
        );
        await WindowsAppBlockService.instance.setBlockEntries(
          _expandGameAliasEntries([...entries, ...gameEntries]),
        );
      }
    } catch (_) {
      /* best-effort */
    }
  }

  Completer<MacBlockResult>? _flushCompleter;

  /// Force an immediate apply (no debounce, no active-state guard).
  /// Delegates to EnforcementController (5-layer architecture).
  Future<MacBlockResult> applyNow() async {
    if (!enabled) {
      return MacBlockResult.failure('Windows 보호가 수동으로 꺼져 있습니다.');
    }
    return WorkContextTracker.instance.run('block_sync.applyNow', () async {
      final RuleSet? rules = await _buildCurrentRuleSet();
      if (rules == null) {
        return MacBlockResult.failure('No rules');
      }
      await EnforcementController.instance.updateRules(rules);
      final EnforcementReport report = await EnforcementController.instance
          .applyNow(reason: 'manual');

      if (report.overallSuccess) {
        hostsApplyPending.value = false;
        BlockActivityLogService.instance.record(
          kind: BlockActivityKind.hostsApply,
          message: '적용 성공 (5계층)',
        );
        return MacBlockResult.success();
      } else {
        hostsApplyPending.value = true;
        BlockActivityLogService.instance.record(
          kind: BlockActivityKind.hostsApply,
          message: '적용 실패: ${report.failureReason}',
          level: 'warn',
        );
        return MacBlockResult.failure(report.failureReason ?? 'unknown');
      }
    });
  }

  Future<RuleSet?> _buildCurrentRuleSet() async {
    try {
      // Phase 6 (L5): blockedApps was hardcoded empty, which the resume
      // prompt flagged as the top wiring defect — ProcessLayer.apply() only
      // used it for the cosmetic `appsWritten` count (the actual block
      // targets always came from ActiveAppBlockRegistryService via
      // syncAppTargetsNow(), independent of RuleSet), so this fixes the
      // reported count without changing behavior.
      final List<ActiveAppBlockEntry> entries =
          await ActiveAppBlockRegistryService.instance.activeEntriesNow();
      final List<String> blockedApps = entries
          .map((ActiveAppBlockEntry e) => e.app.exeName)
          .where((String exe) => exe.isNotEmpty)
          .toSet()
          .toList();
      return RuleSet(
        blockedDomains: <String>[],
        allowedDomains: [],
        blockedApps: blockedApps,
        blockedYoutubeChannels: [],
        blockedYoutubeVideos: [],
      );
    } catch (_) {
      return null;
    }
  }

  Future<MacBlockResult> _flushWindows({bool force = false}) async {
    if (!Platform.isWindows) {
      return MacBlockResult.unsupported();
    }
    if (!enabled) {
      _timer?.cancel();
      hostsApplyPending.value = false;
      return MacBlockResult.failure('Windows 보호가 수동으로 꺼져 있습니다.');
    }
    if (_running) {
      final Completer<MacBlockResult>? existing = _flushCompleter;
      if (existing != null) {
        return existing.future;
      }
      if (!force) {
        _timer = Timer(_kDebounce, () => _flushWindows(force: force));
        return lastResult ?? MacBlockResult.unsupported();
      }
    }
    final Completer<MacBlockResult> completer = Completer<MacBlockResult>();
    _flushCompleter = completer;
    _running = true;
    bool firstTimeHostsElevate = false;
    try {
      if (!force) {
        final bool active = await WindowsSystemBlockService.instance.isActive();
        if (!active) {
          final DateTime now = DateTime.now();
          if (_firstHostsElevateCooldownUntil != null &&
              now.isBefore(_firstHostsElevateCooldownUntil!)) {
            lastResult = lastResult ?? MacBlockResult.unsupported();
            return lastResult!;
          }
          final RuleCounts c = await LocalDatabase.instance.ruleCounts();
          final List<String> quota = await UsageQuotaEnforcerService.instance
              .quotaLockedHostsExpanded();
          if (c.domainsEnabled <= 0 && quota.isEmpty) {
            lastResult = MacBlockResult.unsupported();
            return lastResult!;
          }
          firstTimeHostsElevate = true;
        }
      }
      try {
        lastResult = await WindowsSystemBlockService.instance.activate();
      } catch (e, st) {
        AppLogger.instance.error(
          'windows hosts apply failed',
          error: e,
          stack: st,
        );
        lastResult = MacBlockResult.failure(e.toString());
      }
      if (firstTimeHostsElevate &&
          lastResult!.status != MacBlockStatus.success) {
        _firstHostsElevateCooldownUntil = DateTime.now().add(
          _kFirstHostsElevateCooldown,
        );
      } else if (lastResult!.status == MacBlockStatus.success) {
        _firstHostsElevateCooldownUntil = null;
      }
      if (lastResult!.status == MacBlockStatus.success) {
        ExtensionRulesSnapshotService.instance.scheduleWriteToChromePayload();
        unawaited(
          ChromeCorePrinciplesService.instance.applyNow(reason: 'hosts_apply'),
        );
      }
      if (Platform.isWindows) {
        UniversalBrowserBlockService.instance.scheduleSync(
          reason: 'hosts_apply',
        );
        unawaited(
          WindowsFiveLayerBlockService.instance.syncLayers(
            reason: 'hosts_apply',
          ),
        );
        unawaited(
          WindowsFirewallBlockService.instance.syncFromHosts(force: true),
        );
      }
      return lastResult!;
    } finally {
      _running = false;
      final MacBlockResult? result = lastResult;
      final Completer<MacBlockResult>? c = _flushCompleter;
      _flushCompleter = null;
      if (c != null && !c.isCompleted && result != null) {
        c.complete(result);
      }
    }
  }

  Future<MacBlockResult> _flush({bool force = false}) async {
    if (!Platform.isMacOS) {
      return MacBlockResult.unsupported();
    }
    if (_running) {
      _timer = Timer(_kDebounce, () => _flush(force: force));
      return lastResult ?? MacBlockResult.unsupported();
    }
    _running = true;
    bool firstTimeHostsElevate = false;
    try {
      if (!force) {
        final bool active = await MacSystemBlockService.instance.isActive();
        if (!active) {
          final DateTime now = DateTime.now();
          if (_firstHostsElevateCooldownUntil != null &&
              now.isBefore(_firstHostsElevateCooldownUntil!)) {
            lastResult = lastResult ?? MacBlockResult.unsupported();
            return lastResult!;
          }
          final RuleCounts c = await LocalDatabase.instance.ruleCounts();
          final List<String> quota = await UsageQuotaEnforcerService.instance
              .quotaLockedHostsExpanded();
          if (c.domainsEnabled <= 0 && quota.isEmpty) {
            lastResult = MacBlockResult.unsupported();
            return lastResult!;
          }
          firstTimeHostsElevate = true;
        }
      }
      lastResult = await MacSystemBlockService.instance.activate();
      if (firstTimeHostsElevate &&
          lastResult!.status != MacBlockStatus.success) {
        _firstHostsElevateCooldownUntil = DateTime.now().add(
          _kFirstHostsElevateCooldown,
        );
      } else if (lastResult!.status == MacBlockStatus.success) {
        _firstHostsElevateCooldownUntil = null;
      }
      return lastResult!;
    } finally {
      _running = false;
    }
  }
}
