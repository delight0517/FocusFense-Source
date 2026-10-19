import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/block_app.dart';
import '../models/quick_block_user_bundle.dart';
import 'schedule_rule_validation.dart';
import 'block_sync_service.dart';
import 'local_database.dart';
import 'lock_policy_service.dart';
import 'quick_block_controller.dart';
import 'quick_block_prefs_store.dart';
import 'quick_block_service.dart';
import '../models/rules_meta.dart';
import 'mac_system_block_service.dart';

/// Result of attempting to end a timed quick-block session.
enum QuickBlockClearOutcome {
  cleared,
  policyLocked,
  cancelDelayPending,
  notActive,
}

/// Timed quick block with optional cancel cooldown and merged app kill list.
final class QuickBlockSessionService {
  QuickBlockSessionService._()
    : _prefs = QuickBlockPrefsStore.instance,
      _quick = QuickBlockService.instance,
      _db = LocalDatabase.instance,
      _clearQuickBlocksOverride = null,
      _applyBundleOverride = null,
      _requestApplyOverride = null;
  static final QuickBlockSessionService instance = QuickBlockSessionService._();

  @visibleForTesting
  QuickBlockSessionService.forTesting({
    Future<void> Function()? clearQuickBlocks,
    Future<int> Function(String bundleId)? applyBundle,
    VoidCallback? requestApply,
  }) : _prefs = QuickBlockPrefsStore.instance,
       _quick = QuickBlockService.instance,
       _db = LocalDatabase.instance,
       _clearQuickBlocksOverride = clearQuickBlocks,
       _applyBundleOverride = applyBundle,
       _requestApplyOverride = requestApply;

  final QuickBlockPrefsStore _prefs;
  final QuickBlockService _quick;
  final LocalDatabase _db;
  final Future<void> Function()? _clearQuickBlocksOverride;
  final Future<int> Function(String bundleId)? _applyBundleOverride;
  final VoidCallback? _requestApplyOverride;

  QuickBlockSession? _cached;
  final ValueNotifier<int> sessionTick = ValueNotifier<int>(0);

  static bool isBrowserHoldTestTarget(
    QuickBlockSession session,
    QuickBlockUserBundle? bundle,
  ) {
    if (!session.releaseRequired ||
        session.bundleIds.length != 1 ||
        bundle == null ||
        bundle.id != session.bundleIds.single ||
        bundle.domains.isNotEmpty ||
        bundle.keywords.isNotEmpty) {
      return false;
    }
    const Set<String> requiredBrowserIds = <String>{
      'win|chrome.exe|_main',
      'win|aside.exe|_main',
    };
    final Set<String> bundleAppIds = bundle.apps
        .map((app) => app.bundleId)
        .whereType<String>()
        .toSet();
    return bundleAppIds.length == requiredBrowserIds.length &&
        bundleAppIds.containsAll(requiredBrowserIds);
  }

  Future<QuickBlockSession?> activeSession() async {
    final int? leaseUntil = await _prefs.loadTestLeaseUntilMs();
    if (leaseUntil != null) {
      if (DateTime.now().millisecondsSinceEpoch < leaseUntil) return null;
      await _restoreAfterTestLease();
    }
    _cached ??= await _prefs.loadSession();
    if (_cached != null && !_cached!.isActive) {
      await _expireSession(silent: true);
      return null;
    }
    return _cached;
  }

  /// Temporarily releases only the app-level browser hold for a bounded test.
  /// The original session stays persisted and is restored on timeout or startup.
  Future<int> beginBrowserHoldTestLease({required int durationMinutes}) async {
    if (durationMinutes < 1 || durationMinutes > 60) {
      throw ArgumentError.value(durationMinutes, 'durationMinutes');
    }
    final int? existingLease = await _prefs.loadTestLeaseUntilMs();
    if (existingLease != null &&
        existingLease > DateTime.now().millisecondsSinceEpoch) {
      throw StateError('A browser test lease is already active');
    }
    final QuickBlockSession? session = await activeSession();
    if (session == null || !session.releaseRequired) {
      throw StateError('An explicit browser release hold is required');
    }
    if (session.bundleIds.length != 1) {
      throw StateError('Test lease requires one browser hold bundle');
    }
    final QuickBlockUserBundle? bundle = await _userBundleById(
      session.bundleIds.single,
    );
    if (!isBrowserHoldTestTarget(session, bundle)) {
      throw StateError('Test lease is limited to the Chrome/Aside hold');
    }
    final int untilMs = DateTime.now()
        .add(Duration(minutes: durationMinutes))
        .millisecondsSinceEpoch;
    // Persist the recovery deadline before removing any live quick-block data.
    await _prefs.saveTestLeaseUntilMs(untilMs);
    await _clearAllQuickBlocks();
    _cached = null;
    QuickBlockController.instance.bump();
    sessionTick.value++;
    _requestApply();
    return untilMs;
  }

  /// Restore the original hold early, or recover it after the persisted lease
  /// expires. Bundle application is idempotent, so an interrupted restore can
  /// be retried on the next service tick or app start.
  Future<void> endBrowserHoldTestLease() async {
    if (await _prefs.loadTestLeaseUntilMs() == null) {
      throw StateError('No browser test lease is active');
    }
    await _restoreAfterTestLease();
  }

  Future<void> _ensureNoActiveTestLease() async {
    final int? untilMs = await _prefs.loadTestLeaseUntilMs();
    if (untilMs == null) return;
    if (DateTime.now().millisecondsSinceEpoch < untilMs) {
      throw StateError('A browser test lease is active');
    }
    await _restoreAfterTestLease();
  }

  Future<void> _restoreAfterTestLease() async {
    final QuickBlockSession? session = await _prefs.loadSession();
    if (session != null) {
      for (final String bundleId in session.bundleIds) {
        await _applyBundle(bundleId);
      }
      _cached = session;
    } else {
      await _clearAllQuickBlocks();
      _cached = null;
    }
    await _prefs.clearTestLease();
    QuickBlockController.instance.bump();
    sessionTick.value++;
    _requestApply();
  }

  Future<bool> hasActiveSession() async => (await activeSession()) != null;

  Future<int?> testLeaseUntilMs() => _prefs.loadTestLeaseUntilMs();

  /// Upgrade this browser session without resetting its original 72-hour clock.
  Future<QuickBlockSession> holdForRelease(QuickBlockSession session) async {
    await _ensureNoActiveTestLease();
    final held = QuickBlockSession(
      startedAtMs: session.startedAtMs,
      untilMs: session.untilMs,
      cancelNotBeforeMs: session.untilMs,
      bundleIds: session.bundleIds,
      appNames: session.appNames,
      releaseRequired: true,
    );
    await _prefs.saveSession(held);
    _cached = held;
    QuickBlockController.instance.bump();
    sessionTick.value++;
    _requestApply();
    return held;
  }

  /// Display names from active quick-block bundles (macOS title match).
  Future<List<String>> activeAppExeNames() async {
    final List<BlockApp> apps = await activeBlockApps();
    return apps.map((BlockApp a) => a.displayName).toList();
  }

  Future<List<BlockApp>> activeBlockApps() async {
    final QuickBlockSession? s = await activeSession();
    if (s == null) return <BlockApp>[];
    final Map<String, BlockApp> byKey = <String, BlockApp>{};
    for (final String bundleId in s.bundleIds) {
      final QuickBlockUserBundle? b = await _userBundleById(bundleId);
      if (b == null) continue;
      for (final app in b.apps) {
        final BlockApp block = ScheduleRuleValidation.blockAppFromStored(
          displayName: app.displayName,
          bundleId: app.bundleId,
        );
        final String key = block.exeName.isNotEmpty
            ? block.exeName
            : block.displayName.toLowerCase();
        byKey[key] = block;
      }
    }
    return byKey.values.toList();
  }

  /// Start timed session: applies domains (+ apps) then persists session metadata.
  Future<QuickBlockSession?> startWithBundles(
    List<String> bundleIds, {
    int? durationHours,
    int? cancelDelayMinutes,
  }) async {
    await _ensureNoActiveTestLease();
    if (bundleIds.isEmpty) return null;
    final int hours = durationHours ?? await _prefs.defaultDurationHours();
    final int cancelMin =
        cancelDelayMinutes ?? await _prefs.defaultCancelDelayMinutes();
    final DateTime now = DateTime.now();
    final DateTime until = now.add(Duration(hours: hours));
    final DateTime cancelNotBefore = now.add(Duration(minutes: cancelMin));

    int domainsAdded = 0;
    for (final String id in bundleIds) {
      domainsAdded += await _applyBundle(id);
    }

    final QuickBlockSession session = QuickBlockSession(
      startedAtMs: now.millisecondsSinceEpoch,
      untilMs: until.millisecondsSinceEpoch,
      cancelNotBeforeMs: cancelNotBefore.millisecondsSinceEpoch,
      bundleIds: bundleIds,
      appNames: <String>[],
    );
    _cached = session;
    await _prefs.saveSession(session);
    QuickBlockController.instance.bump();
    sessionTick.value++;
    _requestApply();
    if (kDebugMode) {
      // ignore: avoid_print
      print(
        '[QuickBlock] session ${hours}h cancelDelay=${cancelMin}m domains+=$domainsAdded bundles=${bundleIds.length}',
      );
    }
    return session;
  }

  Future<QuickBlockUserBundle?> _userBundleById(String id) async {
    final List<QuickBlockUserBundle> all = await _prefs.loadBundles();
    for (final QuickBlockUserBundle b in all) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// User requested clear — respects lock policy and cancel delay.
  Future<QuickBlockClearOutcome> tryClearSession({
    bool debugOverrideMinimum = false,
    bool debugOverridePolicy = false,
  }) async {
    final QuickBlockSession? s = await activeSession();
    if (s == null) return QuickBlockClearOutcome.notActive;

    final RulesMeta m = await _db.rulesMeta();
    if (!debugOverridePolicy &&
        LockPolicyService.instance.isLockedByPolicy(m)) {
      return QuickBlockClearOutcome.policyLocked;
    }
    final Duration? wait = s.cancelCountdownRemaining;
    if (!debugOverrideMinimum && wait != null && wait > Duration.zero) {
      return QuickBlockClearOutcome.cancelDelayPending;
    }
    await _clearDomainsAndSession();
    return QuickBlockClearOutcome.cleared;
  }

  /// Called when timer elapses.
  Future<void> tickSession() async {
    final QuickBlockSession? s = await activeSession();
    if (s == null) return;
    if (!s.isActive) {
      await _expireSession(silent: false);
    } else {
      sessionTick.value++;
    }
  }

  Future<void> _expireSession({required bool silent}) async {
    await _clearDomainsAndSession();
    if (!silent) {
      QuickBlockController.instance.bump();
    }
  }

  Future<void> _clearDomainsAndSession() async {
    await _clearAllQuickBlocks();
    _cached = null;
    await _prefs.clearSession();
    QuickBlockController.instance.bump();
    sessionTick.value++;
    _requestApply();
  }

  Future<void> _clearAllQuickBlocks() async {
    final Future<void> Function()? override = _clearQuickBlocksOverride;
    if (override != null) {
      await override();
    } else {
      await _quick.clearAllQuickBlocks();
    }
  }

  Future<int> _applyBundle(String bundleId) =>
      _applyBundleOverride?.call(bundleId) ?? _quick.applyBundle(bundleId);

  void _requestApply() {
    final VoidCallback? override = _requestApplyOverride;
    if (override != null) {
      override();
    } else {
      BlockSyncService.instance.requestApply();
    }
  }

  static String formatDuration(Duration d) {
    final int h = d.inHours;
    final int m = d.inMinutes.remainder(60);
    final int s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}시간 ${m}분';
    if (m > 0) return '${m}분 ${s}초';
    return '${s}초';
  }

  static String normalizeUserHost(String raw) {
    String s = raw.trim().toLowerCase();
    if (s.isEmpty) return '';
    if (s.contains('://')) {
      try {
        s = Uri.parse(s).host;
      } catch (_) {
        s = s.replaceFirst(RegExp(r'^https?://'), '');
        final int slash = s.indexOf('/');
        if (slash >= 0) s = s.substring(0, slash);
      }
    } else {
      final int slash = s.indexOf('/');
      if (slash >= 0) s = s.substring(0, slash);
    }
    return MacSystemBlockService.canonicalHost(s);
  }
}
