import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/rules_meta.dart';
import '../models/scheduled_rule_removal.dart';
import 'local_database.dart';
import 'lock_policy_service.dart';
import 'quick_block_controller.dart';

/// Runs delayed rule removals while the app is open and resumes overdue ones
/// after launch. The due timestamp is persisted in SharedPreferences, so a
/// shutdown pauses execution without losing the scheduled request.
final class DelayedRuleRemovalService extends ChangeNotifier {
  DelayedRuleRemovalService._([this._deleteRuleForTesting]);

  @visibleForTesting
  DelayedRuleRemovalService.forTesting({
    required Future<void> Function(ScheduledRuleRemoval) deleteRule,
  }) : this._(deleteRule);

  static final DelayedRuleRemovalService instance =
      DelayedRuleRemovalService._();

  static const String _storageKey = 'delayed_rule_removals_v1';
  static const Duration defaultDelay = Duration(hours: 3);
  static const Duration _lockedRetryDelay = Duration(minutes: 1);

  final Future<void> Function(ScheduledRuleRemoval)? _deleteRuleForTesting;
  final List<ScheduledRuleRemoval> _pending = <ScheduledRuleRemoval>[];
  Future<void>? _loading;
  Timer? _timer;
  bool _processing = false;

  Future<void> start() async {
    await _ensureLoaded();
    await processDueRemovals();
    _armTimer();
  }

  Future<List<ScheduledRuleRemoval>> loadPending() async {
    await _ensureLoaded();
    return List<ScheduledRuleRemoval>.unmodifiable(_pending);
  }

  Future<ScheduledRuleRemoval> scheduleRemoval({
    required ScheduledRuleKind ruleKind,
    required String ruleId,
    required String label,
    Duration delay = defaultDelay,
  }) async {
    await _ensureLoaded();
    final ScheduledRuleRemoval entry = ScheduledRuleRemoval(
      ruleKind: ruleKind,
      ruleId: ruleId,
      label: label,
      dueAt: DateTime.now().add(delay),
    );
    _pending.removeWhere((ScheduledRuleRemoval old) => old.key == entry.key);
    _pending.add(entry);
    await _persist();
    notifyListeners();
    _armTimer();
    return entry;
  }

  Future<bool> cancelRemoval({
    required ScheduledRuleKind ruleKind,
    required String ruleId,
  }) async {
    await _ensureLoaded();
    final String key = '${ruleKind.name}:$ruleId';
    final int before = _pending.length;
    _pending.removeWhere((ScheduledRuleRemoval item) => item.key == key);
    final bool removed = _pending.length < before;
    if (!removed) return false;
    await _persist();
    notifyListeners();
    _armTimer();
    return true;
  }

  ScheduledRuleRemoval? pendingFor(ScheduledRuleKind ruleKind, String ruleId) {
    final String key = '${ruleKind.name}:$ruleId';
    for (final ScheduledRuleRemoval item in _pending) {
      if (item.key == key) return item;
    }
    return null;
  }

  Future<void> processDueRemovals({DateTime? now}) async {
    await _ensureLoaded();
    if (_processing) return;
    _processing = true;
    try {
      final DateTime current = now ?? DateTime.now();
      final List<ScheduledRuleRemoval> due = _pending
          .where((ScheduledRuleRemoval item) => !item.dueAt.isAfter(current))
          .toList(growable: false);
      if (due.isEmpty) return;

      final Set<String> removedKeys = <String>{};
      for (final ScheduledRuleRemoval item in due) {
        try {
          if (_deleteRuleForTesting != null) {
            await _deleteRuleForTesting(item);
          } else {
            final RulesMeta meta = await LocalDatabase.instance.rulesMeta();
            if (LockPolicyService.instance.isLockedByPolicy(meta)) break;
            switch (item.ruleKind) {
              case ScheduledRuleKind.domain:
                await LocalDatabase.instance.deleteDomain(item.ruleId);
                break;
              case ScheduledRuleKind.keyword:
                await LocalDatabase.instance.deleteKeyword(item.ruleId);
                break;
            }
          }
          removedKeys.add(item.key);
        } catch (_) {
          // Keep failed requests on disk for the next timer tick or app resume.
        }
      }

      if (removedKeys.isNotEmpty) {
        _pending.removeWhere(
          (ScheduledRuleRemoval item) => removedKeys.contains(item.key),
        );
        await _persist();
        QuickBlockController.instance.bump();
        notifyListeners();
      }
    } finally {
      _processing = false;
      _armTimer();
    }
  }

  Future<void> _ensureLoaded() => _loading ??= _readPending();

  Future<void> _readPending() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _pending
        ..clear()
        ..addAll(
          decoded
              .whereType<Map>()
              .map(
                (Map item) => ScheduledRuleRemoval.fromJson(
                  Map<String, Object?>.from(item),
                ),
              )
              .whereType<ScheduledRuleRemoval>(),
        );
    } catch (_) {
      _pending.clear();
    }
  }

  Future<void> _persist() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String raw = jsonEncode(
      _pending.map((ScheduledRuleRemoval item) => item.toJson()).toList(),
    );
    await prefs.setString(_storageKey, raw);
  }

  void _armTimer() {
    _timer?.cancel();
    if (_pending.isEmpty) return;
    _pending.sort(
      (ScheduledRuleRemoval a, ScheduledRuleRemoval b) =>
          a.dueAt.compareTo(b.dueAt),
    );
    final Duration untilDue = _pending.first.dueAt.difference(DateTime.now());
    final Duration delay = untilDue.isNegative || untilDue == Duration.zero
        ? _lockedRetryDelay
        : untilDue;
    _timer = Timer(delay, () => unawaited(processDueRemovals()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
