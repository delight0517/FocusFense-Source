import 'dart:async';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/schedule_domain_presets.dart';
import '../models/block_app.dart';
import '../models/schedule_unified_rule_entry.dart';
import '../models/rules_meta.dart';
import '../models/unified_rule_kind.dart';
import 'running_apps_picker_screen.dart';
import '../services/app_logger.dart';
import '../services/crash_journal_service.dart';
import '../services/import_service.dart';
import '../services/local_database.dart';
import '../services/lock_policy_service.dart';
import '../theme/app_colors.dart';
import '../utils/cold_turkey_rule_parser.dart';
import '../utils/schedule_urge_edit_guard.dart';
import '../utils/url_rule_detector.dart';
import '../utils/time_quant.dart';
import '../services/block_sync_service.dart';
import '../services/smart_rule_apply_service.dart';
import '../widgets/smart_rule_input_bar.dart';
import '../widgets/unified_rule_kind_chip.dart';
/// Create or edit a schedule. Owns its own keywords + domains.
///
/// Behavior rules (the single most important invariant):
///
///   **Lock blocks REMOVALS, never ADDITIONS.**
///
///   Every code path here splits on "does this action shrink the user's
///   block coverage?" If yes → gated behind `_globalWriteLocked` /
///   `_committedBlocklistsLocked`. If no → allowed even while locked.
///
///   * **Session** (focus/PIN) lock blocks: slot delete, slot shrink,
///     "전체 교체"-style replaces, blocklist row deletes, schedule disable,
///     schedule delete, undo.
///   * **Session lock does NOT block**: adding a fresh slot to any day,
///     expanding an existing slot, adding domains / keywords / apps to
///     the blocklist, adding bulk slots without `replaceExisting`. The
///     "추가만 가능" copy in the snackbars is the user-visible contract.
///   * **Per-schedule urge buffer** (rolling window around "now"): narrowing
///     a slot that overlaps it is blocked; expanding is allowed.
///   * Save time is rounded to **15 분 단위**.
///   * Back-without-save warns; Save persists and pops.
///
/// If a future edit reintroduces a `_globalWriteLocked` guard that fires
/// on an ADD path, that's the bug we already fixed once — split the path
/// per outcome instead.
class ScheduleEditScreen extends StatefulWidget {
  const ScheduleEditScreen({super.key, this.scheduleId});

  final String? scheduleId;

  @override
  State<ScheduleEditScreen> createState() => _ScheduleEditScreenState();
}

class _ScheduleEditScreenState extends State<ScheduleEditScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  final LockPolicyService _lock = LockPolicyService.instance;

  late String _id;
  bool _isNew = true;
  bool _enabled = true;
  String _name = '';

  /// Per-day time slots. Replaces the old single (start/end + mask) model.
  /// Each slot belongs to one weekday (0=Mon..6=Sun) with [startMinute, endMinute).
  /// `start=0, end=1440` means "all day" for that weekday.
  List<_Slot> _slots = <_Slot>[];

  final TextEditingController _nameCtrl = TextEditingController();

  final TextEditingController _domainCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _shortcutsFocus = FocusNode();
  String _searchTerm = '';
  String? _domainWarning;
  bool _addAsStem = false;
  bool _addingRule = false;

  /// Undo stack: each entry is a callback that reverses one user action.
  /// Capped at 10 entries to keep memory tiny and avoid laggy UI.
  final List<_UndoAction> _undo = <_UndoAction>[];
  static const int _kUndoMax = 10;

  void _pushUndo(_UndoAction action) {
    _undo.add(action);
    if (_undo.length > _kUndoMax) _undo.removeAt(0);
  }

  Future<void> _doUndo() async {
    if (_scheduleMetaHardLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('잠금 중에는 되돌리기를 쓸 수 없습니다.')),
      );
      return;
    }
    if (_undo.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('되돌릴 작업이 없습니다.')),
      );
      return;
    }
    final _UndoAction action = _undo.removeLast();
    await action.undo();
    _domains = await _db.domainsForSchedule(_id);
    _keywords = await _db.keywordsForSchedule(_id);
    _searchQueries = await _db.searchQueryBlocksForSchedule(_id);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('되돌림: ${action.label}')),
    );
  }

  List<Map<String, Object?>> _domains = <Map<String, Object?>>[];
  List<Map<String, Object?>> _keywords = <Map<String, Object?>>[];
  List<Map<String, Object?>> _searchQueries = <Map<String, Object?>>[];
  List<Map<String, Object?>> _blockedApps = <Map<String, Object?>>[];
  /// Preset bundle IDs already applied to this schedule (see [ScheduleDomainPreset.id]).
  Set<String> _appliedPresetIds = <String>{};
  final TextEditingController _appCtrl = TextEditingController();
  String? _appWarning;

  RulesMeta _meta = RulesMeta.defaults;
  bool _inGrace = false;
  bool _dirty = false;
  bool _initialised = false;
  String? _loadError;

  // Per-schedule lock state (v8, pre-commitment model). Read at load and
  // after any lock action so delete buttons / cooldown picker immediately
  // reflect the new state.
  //
  // [_lockCooldownMinutes] is the *immutable-while-locked* mandatory wait
  // time the user pre-committed at schedule creation.
  // [_scheduleUnlockUntil] is the end of the 5-minute edit window (only
  // meaningful after the cooldown has elapsed).
  // [_schedulePhase] is the derived state machine phase used by the UI.
  bool _scheduleLocked = false;
  int _lockCooldownMinutes = 30;
  DateTime? _scheduleUnlockUntil;
  ScheduleLockPhase _schedulePhase = ScheduleLockPhase.unlocked;
  DateTime? _schedulePhaseTransitionAt;

  // Pagination — 10 items per page for both lists.
  static const int _kPageSize = 10;
  int _unifiedPage = 0;

  // Session-level unlock countdown.
  // Phase 1: user taps "Unlock" → countdown runs for unlockCooldownSeconds.
  // Phase 2: countdown hits 0 → startGrace() called → 5-min wall-clock window.
  // Phase 3: grace expires → back to locked.
  // Navigating away does NOT reset the grace (it's wall-clock in SharedPrefs).
  Timer? _unlockTimer;
  int _unlockCountdown = 0;       // >0 while countdown is running
  bool _countdownActive = false;  // true while Phase 1 is in progress
  DateTime? _graceExpiresAt;      // set after startGrace() so we can show remaining time
  Timer? _graceRefreshTimer;      // ticks every second to update remaining display

  static const List<String> _dayShort = <String>['월','화','수','목','금','토','일'];

  /// Too-broad inputs that would block legitimate services entirely.
  /// We block ADD with a clear explanation instead of letting users shoot
  /// their own foot (e.g. blocking "chrome" → would also break YT Music PWA
  /// only if user added 'chrome' as a domain, which doesn't actually do
  /// anything via DNS — but the keyword case can disable big SERPs).
  static const Set<String> _tooBroadHosts = <String>{
    'google.com', 'www.google.com',
    'chrome', 'safari', 'firefox',
    'apple.com',
    'microsoft.com',
    'github.com',
    'icloud.com',
    'localhost', '127.0.0.1',
  };

  static final List<ScheduleDomainPreset> _presets = scheduleDomainPresets();

  @override
  void initState() {
    super.initState();
    _id = widget.scheduleId ?? _newId();
    _isNew = widget.scheduleId == null;
    _load();
  }

  @override
  void dispose() {
    _unlockTimer?.cancel();
    _graceRefreshTimer?.cancel();
    _nameCtrl.dispose();
    _domainCtrl.dispose();
    _appCtrl.dispose();
    _searchCtrl.dispose();
    _shortcutsFocus.dispose();
    super.dispose();
  }

  String _newId() =>
      'sched_${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(Object())}';

  Future<void> _load() async {
    try {
      await _loadInner().timeout(const Duration(seconds: 30));
      _loadError = null;
    } on TimeoutException catch (e, st) {
      _loadError =
          '불러오기 시간 초과(30초). DB 또는 디스크가 느리면 이렇게 보일 수 있어요.\n$e';
      CrashJournalService.instance.record(
        kind: 'schedule_load',
        message: 'ScheduleEditScreen load timeout',
        error: e,
        stack: st,
      );
      AppLogger.instance.error('ScheduleEditScreen load timeout',
          error: e, stack: st);
    } catch (e, st) {
      _loadError = e.toString();
      CrashJournalService.instance.record(
        kind: 'schedule_load',
        message: 'ScheduleEditScreen load failed',
        error: e,
        stack: st,
      );
      AppLogger.instance.error('ScheduleEditScreen load failed',
          error: e, stack: st);
    } finally {
      if (mounted) {
        setState(() => _initialised = true);
      }
    }
  }

  Future<void> _loadInner() async {
    _meta = await _db.rulesMeta();
    _inGrace = await _lock.isInGrace();
    _graceExpiresAt = await _lock.graceExpiresAt();
    if (_inGrace && _graceExpiresAt != null) _startGraceRefresh();
    if (!_isNew) {
      final Map<String, Object?>? row = await _db.scheduleById(_id);
      if (row == null) {
        throw StateError('스케줄을 찾을 수 없습니다: $_id');
      }
      _name = row['name']! as String;
      _enabled = (row['enabled'] as int) == 1;
      _scheduleLocked = ((row['locked'] as int?) ?? 0) == 1;
      _lockCooldownMinutes = (row['lock_cooldown_minutes'] as int?) ?? 30;
      final int until = (row['unlock_until'] as int?) ?? 0;
      _scheduleUnlockUntil = until > DateTime.now().millisecondsSinceEpoch
          ? DateTime.fromMillisecondsSinceEpoch(until)
          : null;
      final ({ScheduleLockPhase phase, DateTime? transitionAt}) p =
          await _db.scheduleLockPhase(_id);
      _schedulePhase = p.phase;
      _schedulePhaseTransitionAt = p.transitionAt;
      if (p.phase == ScheduleLockPhase.countdown ||
          p.phase == ScheduleLockPhase.editWindow) {
        Future<void>.delayed(const Duration(seconds: 1), _refreshScheduleLock);
      }
      final List<Map<String, Object?>> slotRows =
          await _db.slotsForSchedule(_id);
      _slots = slotRows
          .map((Map<String, Object?> r) => _Slot(
                id: r['id']! as String,
                day: r['day']! as int,
                startMinute: r['start_minute']! as int,
                endMinute: r['end_minute']! as int,
              ))
          .toList();
      if (_slots.isEmpty) {
        final int start = (row['start_minute'] as int?) ?? 0;
        final int end = (row['end_minute'] as int?) ?? 0;
        final int mask = (row['days_mask'] as int?) ?? 0;
        _slots = _legacyToSlots(start, end, mask);
      }
      _domains = await _db.domainsForSchedule(_id);
      _keywords = await _db.keywordsForSchedule(_id);
      _searchQueries = await _db.searchQueryBlocksForSchedule(_id);
      _blockedApps = await _db.appsForSchedule(_id);
      _appliedPresetIds = await _db.appliedPresetIds(_id);
    } else {
      _name = '새 스케줄';
      _slots = List<_Slot>.generate(
        7,
        (int d) => _Slot(
          id: 'init_${DateTime.now().microsecondsSinceEpoch}_$d',
          day: d,
          startMinute: 0,
          endMinute: 1440,
        ),
      );
    }
    _nameCtrl.text = _name;
  }

  static List<_Slot> _legacyToSlots(int start, int end, int mask) {
    final List<_Slot> out = <_Slot>[];
    int counter = 0;
    String newId() => 'legacy_${DateTime.now().microsecondsSinceEpoch}_${counter++}';
    for (int d = 0; d < 7; d++) {
      if ((mask & (1 << d)) == 0) continue;
      if (start == end) {
        out.add(_Slot(id: newId(), day: d, startMinute: 0, endMinute: 1440));
      } else if (start < end) {
        out.add(_Slot(id: newId(), day: d, startMinute: start, endMinute: end));
      } else {
        out.add(_Slot(id: newId(), day: d, startMinute: start, endMinute: 1440));
        final int next = (d + 1) % 7;
        out.add(_Slot(id: newId(), day: next, startMinute: 0, endMinute: end));
      }
    }
    return out;
  }

  /// Focus / PIN policy: blocks broad edits until the session grace flow.
  bool get _globalWriteLocked =>
      _lock.isLockedByPolicy(_meta) && !_inGrace;

  /// Per-schedule pre-commitment without the short post-cooldown edit window.
  bool get _urgeTimeClampActive =>
      _scheduleLocked && _schedulePhase != ScheduleLockPhase.editWindow;

  bool _slotOverlapsUrgeBuffer(_Slot s, DateTime now) =>
      scheduleSlotTouchesUrgeWindow(
        s.day,
        s.startMinute,
        s.endMinute,
        now,
        horizon: kScheduleUrgeEditHorizon,
      );

  bool _slotUrgeWriteLocked(_Slot s) =>
      _urgeTimeClampActive && _slotOverlapsUrgeBuffer(s, DateTime.now());

  bool get _hasUrgeProtectedSlot =>
      _slots.any((_Slot s) => _slotOverlapsUrgeBuffer(s, DateTime.now()));

  /// Undo / delete whole schedule: session PIN lock only (urge는 슬롯 단위로 처리).
  bool get _scheduleMetaHardLocked => _globalWriteLocked;

  /// 스케줄 끄기: 세션 잠금이거나, 지금 막히는 구간이 있을 때는 충동 방지로 막음.
  bool get _scheduleDisableBlocked =>
      _globalWriteLocked || (_urgeTimeClampActive && _hasUrgeProtectedSlot);

  /// v8 pre-commitment: cannot remove existing blocklist rows while locked.
  bool get _committedBlocklistsLocked =>
      _scheduleLocked && _schedulePhase != ScheduleLockPhase.editWindow;

  /// Bars deleting domains / keywords / blocked apps (add-only while locked).
  bool get _blockListRemovals =>
      _globalWriteLocked || _committedBlocklistsLocked;

  void _showUrgeSlotLockedSnack() {
    _applyTimeLockPenaltyOnBypass();
    final int h = kScheduleUrgeEditHorizon.inHours;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '지금부터 약 $h시간 안에 걸리는 시간대는 충동 방지를 위해 잠겨 있어요. '
          '그 밖의 요일·이미 지난 시간대는 수정·삭제할 수 있습니다. '
          '이 구간까지 바꾸려면 아래 잠금 카드에서 해제를 진행하세요.',
        ),
      ),
    );
  }

  void _applyTimeLockPenaltyOnBypass() {
    final int penaltyMin = _meta.bypassTimeLockMinutes;
    if (penaltyMin >= 10) {
      unawaited(_db.applyBypassTimeLockPenalty(_id, penaltyMin));
    }
  }

  /// Phase 1: Start the unlock countdown. User must wait [unlockCooldownSeconds].
  /// After it hits zero, startGrace() is called and the 5-min edit window opens.
  void _startUnlockCountdown() {
    if (_countdownActive) return;
    _unlockTimer?.cancel();
    setState(() {
      _countdownActive = true;
      _unlockCountdown = _meta.unlockCooldownSeconds;
    });
    _unlockTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _unlockCountdown--);
      if (_unlockCountdown <= 0) {
        t.cancel();
        _onCountdownComplete();
      }
    });
  }

  Future<void> _onCountdownComplete() async {
    await _lock.startGrace();
    final DateTime? exp = await _lock.graceExpiresAt();
    if (!mounted) return;
    setState(() {
      _countdownActive = false;
      _unlockCountdown = 0;
      _inGrace = true;
      _graceExpiresAt = exp;
    });
    _startGraceRefresh();
  }

  void _cancelUnlockCountdown() {
    _unlockTimer?.cancel();
    setState(() { _countdownActive = false; _unlockCountdown = 0; });
  }

  /// Phase 2: tick every second to refresh the remaining grace time display.
  void _startGraceRefresh() {
    _graceRefreshTimer?.cancel();
    _graceRefreshTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) { t.cancel(); return; }
      final bool still = _graceExpiresAt != null &&
          DateTime.now().isBefore(_graceExpiresAt!);
      if (!still) {
        t.cancel();
        setState(() { _inGrace = false; _graceExpiresAt = null; });
      } else {
        setState(() {});
      }
    });
  }

  String _graceRemaining() {
    if (_graceExpiresAt == null) return '';
    final Duration r = _graceExpiresAt!.difference(DateTime.now());
    if (r.isNegative) return '0:00';
    final int m = r.inMinutes;
    final int s = r.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Guards every exit path (back button, PopScope) while `_dirty` is true.
  /// Deliberately offers only "취소" / "저장" — no silent-discard button —
  /// so a misclick can never throw away unsaved slot/preset edits. Picking
  /// "저장" runs the real save before allowing the pop.
  Future<bool> _confirmBackIfDirty() async {
    if (!_dirty) return true;
    final bool? ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('저장하지 않고 나가시겠어요?'),
        content: const Text(
          '아직 저장하지 않은 변경 사항이 있습니다. 지금 나가면 저장되지 않을 수 있습니다.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () async {
              await _save();
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _save() async {
    final String name = _nameCtrl.text.trim().isEmpty
        ? '새 스케줄'
        : _nameCtrl.text.trim();
    // Derive legacy fields from slots so the `schedules` row stays useful
    // for any code path that still reads them. The slot table is the truth.
    int daysMask = 0;
    int legacyStart = 0;
    int legacyEnd = 0;
    if (_slots.isNotEmpty) {
      for (final _Slot s in _slots) {
        daysMask |= 1 << s.day;
      }
      final _Slot first = _slots.first;
      legacyStart = first.startMinute;
      legacyEnd = first.endMinute >= 1440 ? 0 : first.endMinute;
    }
    await _db.upsertSchedule(
      id: _id,
      name: name,
      startMinute: legacyStart,
      endMinute: legacyEnd,
      daysMask: daysMask,
      enabled: _enabled,
    );
    await _db.deleteSlotsForSchedule(_id);
    for (final _Slot s in _slots) {
      // Must use each slot's stable in-memory id. Timestamp-only ids can
      // collide within one save loop (same microsecond) or for two windows
      // sharing day+start; sqflite then replaces rows and slots vanish.
      await _db.insertSlot(
        id: s.id,
        scheduleId: _id,
        day: s.day,
        startMinute: s.startMinute,
        endMinute: s.endMinute,
      );
    }
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _isNew = false;
      _name = name;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('저장됨')),
    );
  }

  String? _validateHost(String host) {
    if (host.isEmpty) return '값을 입력하세요.';
    if (_tooBroadHosts.contains(host)) {
      return '"$host" 는 너무 광범위해서 다른 앱·로그인도 깨질 수 있습니다. '
          '구체적인 하위 도메인(예: news.naver.com)을 추천합니다.';
    }
    return null;
  }

  Future<void> _addDomain() async {
    if (_addingRule) return;
    final String raw = _domainCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _domainWarning = '값을 입력하세요.');
      return;
    }
    setState(() => _addingRule = true);
    try {
      if (_isNew) await _save();
      if (!context.mounted) return;

      final Set<String> existingDomains = _domains
          .map((Map<String, Object?> r) => (r['host']! as String).toLowerCase())
          .toSet();
      final Set<String> existingKeywords = _keywords
          .map((Map<String, Object?> r) =>
              (r['pattern']! as String).toLowerCase())
          .toSet();
      final Set<String> existingSearchQueries = _searchQueries
          .map((Map<String, Object?> r) =>
              (r['term']! as String).toLowerCase())
          .toSet();

      final SmartRuleApplyResult result =
          await SmartRuleApplyService.instance.applyLine(
        context: context,
        rawLine: raw,
        scheduleId: _id,
        domainAsStem: _addAsStem,
        existingDomains: existingDomains,
        existingKeywords: existingKeywords,
        existingSearchQueries: existingSearchQueries,
        newId: _newId,
      );

      if (!context.mounted) return;
      if (result.cancelled) return;
      if (result.error != null) {
        setState(() => _domainWarning = result.error);
        return;
      }

      _domainCtrl.clear();
      await _reloadBlockRules();
      if (!mounted) return;
      setState(() => _domainWarning = null);

      final String canonical =
          UrlRuleDetector.detect(raw).pattern.trim().toLowerCase();

      if (result.ok) {
        final StringBuffer body = StringBuffer(result.summaryMessage());
        if (result.hostTruncationNote != null) {
          body.write('\n${result.hostTruncationNote}');
        }
        if (result.apexEnforceMessage != null &&
            result.apexEnforceMessage!.trim().isNotEmpty) {
          body.write('\n${result.apexEnforceMessage}');
        } else {
          body.write('\n스케줄 ON + 브라우저 확장 동기화 후 F5');
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(body.toString()),
            duration: Duration(
              seconds: result.apexEnforceMessage != null ? 7 : 5,
            ),
          ),
        );
        return;
      }

      if (result.duplicates > 0 || result.skippedDuplicates > 0) {
        final String label = canonical.isNotEmpty ? canonical : raw;
        final String dupMsg =
            '이미 이 스케줄에 「$label」이(가) 있습니다. 아래 목록에서 검색해 보세요.';
        setState(() => _domainWarning = dupMsg);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(dupMsg)),
        );
        return;
      }

      if (result.wasSkipped) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('추가된 항목 없음')),
        );
      }
    } finally {
      if (mounted) setState(() => _addingRule = false);
    }
  }

  Future<void> _reloadBlockRules() async {
    _domains = await _db.domainsForSchedule(_id);
    _keywords = await _db.keywordsForSchedule(_id);
    _searchQueries = await _db.searchQueryBlocksForSchedule(_id);
    _appliedPresetIds = await _db.appliedPresetIds(_id);
  }

  Future<void> _deleteSearchQuery(String id, String term) async {
    if (_blockListRemovals) return;
    await _db.deleteSearchQueryBlock(id);
    _pushUndo(_UndoAction(
      label: '검색어 차단 삭제 "$term"',
      undo: () async {
        await _db.insertSearchQueryBlock(
          id: id,
          term: term,
          scheduleId: _id,
        );
      },
    ));
    _searchQueries = await _db.searchQueryBlocksForSchedule(_id);
    if (mounted) setState(() {});
  }

  // ─────────────────── blocked applications ───────────────────
  /// Curated quick-pick list. Tapping a chip inserts the display name
  /// directly — same name pattern that `NSRunningApplication.localizedName`
  /// reports for the bundled / first-party Mac versions of each app.
  static const List<String> _appPresets = <String>[
    'Discord', 'Slack', 'Telegram', 'WhatsApp', 'Messenger',
    'Twitter', 'X', 'Instagram', 'TikTok', 'Reddit',
    'Steam', 'Epic Games Launcher', 'Battle.net', 'StarCraft II',
    'YouTube', 'Spotify', 'Music', 'TV',
    'Chrome', 'Firefox', 'Edge', 'Brave Browser', 'Arc',
  ];

  /// `bundle_id` format from running-app picker: `win|<exe>|<chromeAppId>`.
  static String _winBundlePayload(BlockApp app) =>
      'win|${app.exeName}|${app.chromeAppId ?? ''}';

  static String? _pickerKeyFromBlockedRow(Map<String, Object?> row) {
    final String? b = row['bundle_id'] as String?;
    if (b == null || !b.startsWith('win|')) return null;
    final List<String> parts = b.split('|');
    if (parts.length < 3) return null;
    final String exe = BlockApp.normalizeExeName(parts[1]);
    final String cid = parts.sublist(2).join('|');
    if (BlockApp.browserExes.contains(exe)) {
      if (cid.isNotEmpty && cid != BlockApp.mainBrowserKey) {
        return '$exe?app-id=$cid';
      }
      return exe;
    }
    return exe;
  }

  static String _pickerKeyForBlockApp(BlockApp a) {
    if (a.isPwa) {
      return '${a.exeName}?app-id=${a.chromeAppId}';
    }
    if (a.isChromiumBrowser) {
      return a.exeName;
    }
    return a.exeName;
  }

  Set<String> _blockedPickerKeySet() {
    final Set<String> keys = <String>{};
    for (final Map<String, Object?> r in _blockedApps) {
      final String? k = _pickerKeyFromBlockedRow(r);
      if (k != null) keys.add(k);
      keys.add((r['name'] as String).toLowerCase());
    }
    return keys;
  }

  Future<void> _pickRunningWindowsApps() async {
    // Adding apps to the blocklist strictly expands coverage — allowed
    // during lock. Removal is still blocked by `_blockListRemovals` in
    // `_deleteBlockedApp` / the per-row delete buttons.
    if (!Platform.isWindows) return;
    if (_isNew) await _save();
    if (!mounted) return;
    final List<BlockApp>? picked =
        await Navigator.of(context).push<List<BlockApp>>(
      MaterialPageRoute<List<BlockApp>>(
        builder: (BuildContext ctx) => RunningAppsPickerScreen(
          alreadyChosenKeys: _blockedPickerKeySet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;

    final Set<String> keyScratch = _blockedPickerKeySet();
    int added = 0;
    int skipped = 0;
    for (final BlockApp app in picked) {
      final String key = _pickerKeyForBlockApp(app);
      if (keyScratch.contains(key)) {
        skipped++;
        continue;
      }
      final String? err = _validateAppName(app.displayName);
      if (err != null) {
        skipped++;
        if (mounted) setState(() => _appWarning = err);
        continue;
      }
      final String newId = _newId();
      await _db.insertBlockedApp(
        id: newId,
        name: app.displayName,
        scheduleId: _id,
        bundleId: _winBundlePayload(app),
      );
      _pushUndo(_UndoAction(
        label: '앱 추가 "${app.displayName}"',
        undo: () => _db.hardDeleteBlockedApp(newId),
      ));
      keyScratch.add(key);
      keyScratch.add(app.displayName.toLowerCase());
      added++;
    }
    _blockedApps = await _db.appsForSchedule(_id);
    if (!mounted) return;
    setState(() {
      if (skipped == 0 || added > 0) _appWarning = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0 && skipped > 0
              ? '추가할 새 앱이 없었어요.'
              : '실행 중 목록에서 $added개 추가 (관련 exe 포함)${skipped > 0 ? ' · 중복·제한 $skipped건 건너뜀' : ''}',
        ),
      ),
    );
  }

  String? _validateAppName(String raw) {
    if (raw.isEmpty) return '앱 이름을 입력하세요.';
    final String n = raw.trim().toLowerCase();
    if (Platform.isWindows) {
      const Set<String> winBanned = <String>{
        'explorer',
        'windows explorer',
        'file explorer',
        'task manager',
        '작업 관리자',
        'settings',
        '설정',
        'search',
        '6 vpn blocker',
        'cursor',
        'powershell',
        'windows terminal',
        'devenv',
        'visual studio',
      };
      if (winBanned.contains(n)) {
        return '"$raw" 는 Windows에서 차단하면 작업 환경이 망가질 수 있어요. 다른 앱을 고르세요.';
      }
    } else {
      const Set<String> banned = <String>{
        'finder', 'system', 'system preferences', 'system settings',
        'loginwindow', 'window server', 'controlcenter', 'dock',
        '6 vpn blocker', 'cursor', 'xcode', 'terminal',
      };
      if (banned.contains(n)) {
        return '"$raw" 는 차단하면 Mac이 정상적으로 동작하지 않을 수 있어요. 다른 이름을 사용하세요.';
      }
    }
    return null;
  }

  Future<void> _addBlockedApp({String? presetName, String? bundleId}) async {
    final String raw = (presetName ?? _appCtrl.text).trim();
    final String? err = _validateAppName(raw);
    if (err != null) {
      setState(() => _appWarning = err);
      return;
    }
    if (_isNew) await _save();
    final Set<String> existing = _blockedApps
        .map((Map<String, Object?> r) => (r['name']! as String).toLowerCase())
        .toSet();
    if (existing.contains(raw.toLowerCase())) {
      setState(() => _appWarning = '이미 목록에 있어요.');
      return;
    }
    final String newId = _newId();
    await _db.insertBlockedApp(
      id: newId,
      name: raw,
      scheduleId: _id,
      bundleId: bundleId,
    );
    _pushUndo(_UndoAction(
      label: '앱 추가 "$raw"',
      undo: () => _db.hardDeleteBlockedApp(newId),
    ));
    _appCtrl.clear();
    _blockedApps = await _db.appsForSchedule(_id);
    if (mounted) setState(() => _appWarning = null);
  }

  Future<void> _deleteBlockedApp(Map<String, Object?> row) async {
    final String id = row['id']! as String;
    final String name = (row['name'] as String?) ?? '앱';
    await _confirmDelete(name, () async {
      await _db.deleteBlockedApp(id);
      _blockedApps = await _db.appsForSchedule(_id);
      if (mounted) setState(() {});
    });
  }

  /// Opens a dialog where the user can paste many domains at once
  /// (one per line) or pick a hosts/.txt file from disk. Each parsed
  /// host is inserted under the current schedule, skipping duplicates
  /// and lines that fail [_validateHost].
  Future<void> _bulkImportDomains() async {
    final _BulkResult? result = await showDialog<_BulkResult>(
      context: context,
      builder: (BuildContext ctx) => const _BulkAddDomainsDialog(),
    );
    if (result == null || result.lines.isEmpty) return;
    if (_isNew) await _save();

    final Set<String> existingDomains = _domains
        .map((Map<String, Object?> r) =>
            (r['host']! as String).toLowerCase())
        .toSet();
    final Set<String> existingKeywords = _keywords
        .map((Map<String, Object?> r) =>
            (r['pattern']! as String).toLowerCase())
        .toSet();
    final Set<String> existingSearchQueries = _searchQueries
        .map((Map<String, Object?> r) =>
            (r['term']! as String).toLowerCase())
        .toSet();

    int domainsAdded = 0;
    int keywordsAdded = 0;
    int searchQueriesAdded = 0;
    int skipped = 0;
    int rejected = 0;
    final List<String> coldTurkeyFallback = <String>[];

    for (final String line in result.lines) {
      if (!context.mounted) break;
      final SmartRuleApplyResult smart =
          await SmartRuleApplyService.instance.applyLine(
        context: context,
        rawLine: line,
        scheduleId: _id,
        domainAsStem: result.asStem,
        existingDomains: existingDomains,
        existingKeywords: existingKeywords,
        existingSearchQueries: existingSearchQueries,
        newId: _newId,
      );
      if (smart.cancelled) break;
      if (smart.error != null) {
        rejected++;
        continue;
      }
      domainsAdded += smart.domainsAdded;
      keywordsAdded += smart.keywordsAdded;
      searchQueriesAdded += smart.searchQueriesAdded;
      skipped += smart.duplicates + smart.skippedDuplicates;
      if (smart.domainsAdded == 0 &&
          smart.keywordsAdded == 0 &&
          smart.searchQueriesAdded == 0 &&
          !smart.lineIgnored) {
        coldTurkeyFallback.add(line);
      }
    }

    final ColdTurkeyImportBatch batch = parseColdTurkeyLines(coldTurkeyFallback);

    for (final ColdTurkeyParsedRule rule in batch.rules) {
      switch (rule.kind) {
        case ColdTurkeyRuleKind.domain:
          final String host = rule.domainHost!;
          if (existingDomains.contains(host)) {
            skipped++;
            continue;
          }
          if (_validateHost(host) != null) {
            rejected++;
            continue;
          }
          await _db.insertDomain(
            id: _newId(),
            host: host,
            scheduleId: _id,
            isStem: result.asStem,
          );
          existingDomains.add(host);
          domainsAdded++;
          final String? extra = rule.keywordPattern;
          if (extra != null &&
              extra != host &&
              !existingKeywords.contains(extra)) {
            await _db.insertKeyword(
              id: _newId(),
              pattern: extra,
              scheduleId: _id,
            );
            existingKeywords.add(extra);
            keywordsAdded++;
          }
          break;
        case ColdTurkeyRuleKind.path:
        case ColdTurkeyRuleKind.urlPattern:
          final String pat = rule.keywordPattern!;
          if (existingKeywords.contains(pat)) {
            skipped++;
            continue;
          }
          await _db.insertKeyword(
            id: _newId(),
            pattern: pat,
            scheduleId: _id,
          );
          existingKeywords.add(pat);
          keywordsAdded++;
          break;
      }
    }

    await _reloadBlockRules();
    AppLogger.instance.info(
        'bulk add → schedule=$_id domains=$domainsAdded keywords=$keywordsAdded '
        'searchQueries=$searchQueriesAdded skipped=$skipped rejected=$rejected');
    if (!mounted) return;
    setState(() {});
    final StringBuffer sb = StringBuffer();
    if (domainsAdded > 0) sb.write('사이트 $domainsAdded');
    if (keywordsAdded > 0) {
      if (sb.isNotEmpty) sb.write(' · ');
      sb.write('키워드·채널 $keywordsAdded');
    }
    if (searchQueriesAdded > 0) {
      if (sb.isNotEmpty) sb.write(' · ');
      sb.write('검색어 $searchQueriesAdded');
    }
    if (sb.isEmpty) {
      sb.write('추가된 항목 없음');
    } else {
      sb.write('개 추가');
    }
    if (skipped > 0) sb.write(' · 중복 $skipped');
    if (rejected > 0) sb.write(' · 제한 $rejected');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sb.toString())),
    );
  }

  /// Applies [bundle] as **one managed unit**: every row it creates is
  /// tagged `preset_id: bundle.id`, and the bundle is recorded in
  /// `schedule_applied_presets`. Re-tapping an already-applied bundle only
  /// tops up anything missing (idempotent) — it never creates a second,
  /// untracked copy. Removal is a single action: [_removePresetBundle].
  Future<void> _applyPreset(ScheduleDomainPreset bundle) async {
    if (_isNew) await _save();
    final Set<String> existing = _domains
        .map((Map<String, Object?> r) => (r['host']! as String).toLowerCase())
        .toSet();
    final Set<String> existingKw = _keywords
        .map((Map<String, Object?> r) => (r['pattern']! as String))
        .toSet();
    int added = 0;
    int skipped = 0;
    for (final String host in bundle.domains) {
      final String h = host.toLowerCase();
      if (existing.contains(h)) {
        skipped++;
        continue;
      }
      if (_validateHost(h) != null) continue;
      await _db.insertDomain(
        id: _newId(),
        host: h,
        scheduleId: _id,
        presetId: bundle.id,
      );
      existing.add(h);
      added++;
    }
    for (final String stem in bundle.numericStems) {
      final String s = stem.trim().toLowerCase();
      if (s.isEmpty) continue;
      if (existing.contains(s)) {
        skipped++;
        continue;
      }
      await _db.insertDomain(
        id: _newId(),
        host: s,
        scheduleId: _id,
        isStem: true,
        presetId: bundle.id,
      );
      existing.add(s);
      added++;
    }
    for (final String kw in bundle.keywords) {
      final String k = kw.trim();
      if (k.isEmpty) continue;
      if (existingKw.contains(k)) {
        skipped++;
        continue;
      }
      await _db.insertKeyword(
        id: _newId(),
        pattern: k,
        scheduleId: _id,
        presetId: bundle.id,
      );
      existingKw.add(k);
      added++;
    }
    await _db.recordAppliedPreset(_id, bundle.id);
    await _reloadBlockRules();
    if (Platform.isWindows || Platform.isMacOS) {
      BlockSyncService.instance.requestApply();
    }
    if (!mounted) return;
    setState(() {});
    final StringBuffer msg = StringBuffer('"${bundle.name}" 묶음에서 $added개 추가됨');
    if (skipped > 0) msg.write(' · 중복 $skipped');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg.toString()),
        duration: Duration(seconds: added > 50 ? 6 : 4),
      ),
    );
  }

  /// Removes an already-applied preset bundle **as one unit** — every
  /// domain/keyword row tagged `preset_id: bundle.id` goes to Trash, in one
  /// tap, instead of the user hunting down scattered rows by hand. Rows the
  /// user added manually (no preset tag) are never touched.
  Future<void> _removePresetBundle(ScheduleDomainPreset bundle) async {
    if (_blockListRemovals) {
      _applyTimeLockPenaltyOnBypass();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('스케줄 잠금 중에는 묶음을 제거할 수 없습니다. 잠금 해제 후 다시 시도하세요.'),
        ),
      );
      return;
    }
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('"${bundle.name}" 묶음 전체 제거'),
        content: Text(
          '이 묶음에서 추가된 사이트·검색어를 모두 휴지통으로 보냅니다 '
          '(30일간 복구 가능). 직접 추가한 항목은 그대로 남습니다.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('제거'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _db.removePresetBundle(_id, bundle.id);
    await _reloadBlockRules();
    if (Platform.isWindows || Platform.isMacOS) {
      BlockSyncService.instance.requestApply();
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${bundle.name}" 묶음을 제거했습니다.')),
    );
  }

  /// [forWholeSchedule] uses [_scheduleMetaHardLocked]; else [_blockListRemovals].
  Future<void> _confirmDelete(
    String what,
    VoidCallback onConfirm, {
    bool forWholeSchedule = false,
  }) async {
    final bool locked =
        forWholeSchedule ? _scheduleMetaHardLocked : _blockListRemovals;
    if (locked) {
      _applyTimeLockPenaltyOnBypass();
      final String text;
      if (forWholeSchedule) {
        text = '세션 잠금 중: 스케줄을 삭제할 수 없습니다. 잠금 해제 후 다시 시도하세요.';
      } else {
        text = _globalWriteLocked
            ? '세션 잠금 중: 삭제할 수 없습니다. 상단의 "잠금 해제"를 눌러 대기 후 편집하세요.'
            : '스케줄 잠금 중에는 이미 등록한 사이트·키워드·앱은 지울 수 없습니다. '
                '새로 추가만 가능해요. 지우려면 잠금 카드에서 해제를 완료하세요.';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(text),
          action: _globalWriteLocked
              ? SnackBarAction(
                  label: '잠금 해제',
                  onPressed: _startUnlockCountdown,
                )
              : null,
        ),
      );
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('정말 삭제하시겠어요?'),
        content: Text('"$what" 항목을 삭제합니다. 이 동작은 되돌릴 수 없습니다.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) onConfirm();
  }

  Future<void> _deleteDomain(String id, String host) async {
    await _confirmDelete(host, () async {
      await _db.deleteDomain(id);
      _pushUndo(_UndoAction(
        label: '사이트 삭제 "$host"',
        undo: () => _db.restoreDomain(id),
      ));
      _domains = await _db.domainsForSchedule(_id);
      if (mounted) setState(() {});
    });
  }

  Future<void> _deleteKeyword(String id, String pattern) async {
    await _confirmDelete(pattern, () async {
      await _db.deleteKeyword(id);
      _pushUndo(_UndoAction(
        label: '키워드 삭제 "$pattern"',
        undo: () => _db.restoreKeyword(id),
      ));
      _keywords = await _db.keywordsForSchedule(_id);
      if (mounted) setState(() {});
    });
  }

  Future<void> _deleteSchedule() async {
    await _confirmDelete(
      _name,
      () async {
        await _db.deleteSchedule(_id);
        if (mounted) Navigator.of(context).pop<String>(null);
      },
      forWholeSchedule: true,
    );
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  String _newSlotId(int day, int startMinute) =>
      'slot_${DateTime.now().microsecondsSinceEpoch}_${day}_${startMinute}_${identityHashCode(Object())}';

  /// Same calendar day: [startMin, endMin). Overnight: endMin < startMin →
  /// evening on [day] + morning on [(day+1)%7] (e.g. 21:40–07:00).
  List<_Slot> _slotsFromDayRange(int day, int startMin, int endMin) {
    if (endMin > startMin) {
      return <_Slot>[
        _Slot(
          id: _newSlotId(day, startMin),
          day: day,
          startMinute: startMin,
          endMinute: endMin,
        ),
      ];
    }
    if (endMin < startMin) {
      final int next = (day + 1) % 7;
      return <_Slot>[
        _Slot(
          id: _newSlotId(day, startMin),
          day: day,
          startMinute: startMin,
          endMinute: 1440,
        ),
        _Slot(
          id: _newSlotId(next, 0),
          day: next,
          startMinute: 0,
          endMinute: endMin,
        ),
      ];
    }
    return <_Slot>[];
  }

  Future<void> _addAllDayEveryDay() async {
    final String? mode = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('매일 · 온종일'),
        content: const Text(
          '기존에 만든 시간 슬롯을 어떻게 할까요?\n\n'
          '• 추가: 아직 슬롯이 없는 요일에만 온종일을 넣습니다 (다른 요일·슬롯은 유지).\n'
          '• 전체 교체: 지금 시간표를 모두 지우고 7일 온종일만 남깁니다.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('취소'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop('merge'),
            child: const Text('추가'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('replace'),
            child: const Text('전체 교체'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    // "전체 교체" wipes existing slots — that's a REMOVAL. Lock policy is
    // "additions OK, removals blocked", so we gate replace here; merge
    // (add-only) is always allowed.
    if (mode == 'replace' && _globalWriteLocked) {
      _applyTimeLockPenaltyOnBypass();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '잠금 중: 「전체 교체」는 기존 시간을 삭제합니다 — 잠금 해제 후에만 가능합니다. '
            '「추가」는 잠금 중에도 사용할 수 있습니다.',
          ),
          action: SnackBarAction(label: '잠금 해제', onPressed: _startUnlockCountdown),
        ),
      );
      return;
    }
    setState(() {
      if (mode == 'replace') {
        final List<_Slot> previous = List<_Slot>.from(_slots);
        _slots = <_Slot>[];
        for (int d = 0; d < 7; d++) {
          final _Slot candidate = _Slot(
            id: _newSlotId(d, 0),
            day: d,
            startMinute: 0,
            endMinute: 1440,
          );
          if (_slotUrgeWriteLocked(candidate)) {
            _slots.addAll(previous.where((_Slot s) => s.day == d));
          } else {
            _slots.add(candidate);
          }
        }
      } else {
        for (int d = 0; d < 7; d++) {
          final bool hasAny = _slots.any((_Slot s) => s.day == d);
          if (!hasAny) {
            final _Slot candidate = _Slot(
              id: _newSlotId(d, 0),
              day: d,
              startMinute: 0,
              endMinute: 1440,
            );
            if (!_slotUrgeWriteLocked(candidate)) {
              _slots.add(candidate);
            }
          }
        }
      }
      _markDirty();
    });
  }

  void _addWeekdayPreset(int startMin, int endMin, {bool weekend = false}) {
    // Add-only preset — strictly expands coverage. Lock policy is
    // "block removals, allow additions" so we do not gate on
    // _globalWriteLocked here. _slotUrgeWriteLocked below still guards the
    // urge buffer per-slot.
    setState(() {
      final List<int> days = weekend ? <int>[5, 6] : <int>[0, 1, 2, 3, 4];
      for (final int d in days) {
        for (final _Slot s in _slotsFromDayRange(d, startMin, endMin)) {
          if (!_slotUrgeWriteLocked(s)) {
            _slots.add(s);
          }
        }
      }
      _markDirty();
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('프리셋 시간을 기존 표에 추가했습니다. 겹치면 막대가 겹쳐 보일 수 있어요.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _bulkAddSlotsForSelectedDays() async {
    final _BulkDaysSlotResult? r = await showDialog<_BulkDaysSlotResult>(
      context: context,
      builder: (BuildContext ctx) => _BulkDaysSlotDialog(dayShort: _dayShort),
    );
    if (r == null || r.selectedDays.isEmpty) return;
    // Same policy: pure add allowed during lock; "replaceExisting" wipes
    // existing slots which is a REMOVAL — gate that mode behind the lock.
    if (r.replaceExisting && _globalWriteLocked) {
      _applyTimeLockPenaltyOnBypass();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '잠금 중: 「기존 슬롯 교체」는 삭제를 포함합니다 — 잠금 해제 후에만 가능. '
            '「기존에 추가」만 잠금 중에도 사용할 수 있습니다.',
          ),
          action: SnackBarAction(label: '잠금 해제', onPressed: _startUnlockCountdown),
        ),
      );
      return;
    }
    setState(() {
      for (final int d in r.selectedDays) {
        if (r.replaceExisting) {
          _slots.removeWhere(
            (_Slot s) => s.day == d && !_slotUrgeWriteLocked(s),
          );
        }
        for (final _Slot s in _slotsFromDayRange(d, r.startMinute, r.endMinute)) {
          if (!_slotUrgeWriteLocked(s)) {
            _slots.add(s);
          }
        }
      }
      _markDirty();
    });
    if (mounted) {
      final bool overnight = r.endMinute < r.startMinute;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            r.replaceExisting
                ? '선택한 요일의 기존 슬롯을 지우고 '
                    '${r.selectedDays.length}개 요일에 적용했습니다.'
                    '${overnight ? ' (자정 넘김 → 다음 요일 아침까지 이어짐)' : ''}'
                : '선택한 ${r.selectedDays.length}개 요일에 시간을 추가했습니다. '
                    '(기존 슬롯은 유지됩니다.)'
                    '${overnight ? ' 자정 넘김은 이어지는 요일에 아침 구간이 생깁니다.' : ''}',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _addSlotForDay(int day) async {
    // Policy: lock blocks REMOVING block coverage, not ADDING. A brand-new
    // slot can only *expand* the user's block coverage — never shrink it —
    // so the session/PIN lock should not stand in the way. The per-slot
    // urge buffer check below still applies (it guards the few hours around
    // "now" from sneaky narrowing-via-replacement).
    final _SlotPickerResult? r = await showDialog<_SlotPickerResult>(
      context: context,
      builder: (BuildContext ctx) => const _SlotPickerDialog(
        initialStartHour: 9,
        initialEndHour: 18,
      ),
    );
    if (r == null) return;
    final List<_Slot> toAdd =
        _slotsFromDayRange(day, r.startMinute, r.endMinute);
    if (toAdd.any(_slotUrgeWriteLocked)) {
      _showUrgeSlotLockedSnack();
      return;
    }
    setState(() {
      for (final _Slot s in toAdd) {
        _slots.add(s);
      }
      _markDirty();
    });
  }

  Future<void> _editSlot(_Slot slot) async {
    // Lock policy: removals blocked, additions allowed. An "edit" can do
    // either, depending on what the user picks. Show the picker first, then
    // gate per-outcome (delete + narrow → blocked while locked; expand →
    // allowed). The early `_globalWriteLocked` return that used to live here
    // also blocked pure expansions — that was the bug.
    final _SlotPickerResult? r = await showDialog<_SlotPickerResult>(
      context: context,
      builder: (BuildContext ctx) => _SlotPickerDialog(
        initialStartHour: slot.startMinute ~/ 60,
        initialStartMinute: slot.startMinute % 60,
        initialEndHour: slot.endMinute >= 1440 ? 24 : slot.endMinute ~/ 60,
        initialEndMinute: slot.endMinute >= 1440 ? 0 : slot.endMinute % 60,
        allowDelete: true,
      ),
    );
    if (r == null) return;
    final DateTime now = DateTime.now();
    // Classify the edit. Cross-midnight (`end < start`) wraps into a
    // separate day, so we conservatively treat it as a narrowing of the
    // current slot.
    final bool isDelete = r.delete;
    final bool isShrink = !isDelete &&
        r.endMinute > r.startMinute &&
        (r.startMinute > slot.startMinute || r.endMinute < slot.endMinute);
    final bool isCrossMidnight =
        !isDelete && r.endMinute < r.startMinute;
    final bool isNarrowingChange = isDelete || isShrink || isCrossMidnight;
    if (isNarrowingChange && _globalWriteLocked) {
      _applyTimeLockPenaltyOnBypass();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '잠금 중: 시간대 축소·삭제는 불가합니다. '
            '확장·신규 추가는 잠금 중에도 가능합니다.',
          ),
          action: SnackBarAction(
            label: '잠금 해제',
            onPressed: _startUnlockCountdown,
          ),
        ),
      );
      return;
    }
    if (r.delete) {
      if (_urgeTimeClampActive &&
          scheduleSlotTouchesUrgeWindow(
            slot.day,
            slot.startMinute,
            slot.endMinute,
            now,
          )) {
        _showUrgeSlotLockedSnack();
        return;
      }
    } else {
      if (r.endMinute > r.startMinute) {
        if (_urgeTimeClampActive &&
            urgeSlotTighteningBlocked(
              day: slot.day,
              oldStart: slot.startMinute,
              oldEnd: slot.endMinute,
              newStart: r.startMinute,
              newEnd: r.endMinute,
              now: now,
            )) {
          _showUrgeSlotLockedSnack();
          return;
        }
      } else if (r.endMinute < r.startMinute) {
        if (_urgeTimeClampActive &&
            scheduleSlotTouchesUrgeWindow(
              slot.day,
              slot.startMinute,
              slot.endMinute,
              now,
            )) {
          _showUrgeSlotLockedSnack();
          return;
        }
      }
    }
    setState(() {
      if (r.delete) {
        _slots.removeWhere((_Slot s) => s.id == slot.id);
      } else {
        final int idx = _slots.indexWhere((_Slot s) => s.id == slot.id);
        if (idx >= 0) {
          if (r.endMinute > r.startMinute) {
            _slots[idx] = _Slot(
              id: slot.id,
              day: slot.day,
              startMinute: r.startMinute,
              endMinute: r.endMinute,
            );
          } else if (r.endMinute < r.startMinute) {
            _slots.removeAt(idx);
            _slots.addAll(_slotsFromDayRange(slot.day, r.startMinute, r.endMinute));
          }
        }
      }
      _markDirty();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialised) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('스케줄')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Icon(Icons.error_outline, size: 48, color: AppColors.danger),
              const SizedBox(height: 16),
              Text(
                '불러오기 실패',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    _loadError!,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _loadError!));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('오류 내용을 복사했어요')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('오류 복사'),
                  ),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _loadError = null;
                        _initialised = false;
                      });
                      _load();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('다시 시도'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        if (await _confirmBackIfDirty()) {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? '새 스케줄' : _name),
          actions: <Widget>[
            IconButton(
              onPressed: (_undo.isEmpty || _scheduleMetaHardLocked) ? null : _doUndo,
              icon: const Icon(Icons.undo),
              tooltip: _scheduleMetaHardLocked
                  ? '잠금 중에는 되돌리기 불가'
                  : '되돌리기 (⌘Z, 최근 ${_undo.length}/10)',
            ),
            if (!_isNew)
              IconButton(
                onPressed: _scheduleMetaHardLocked ? null : _deleteSchedule,
                icon: const Icon(Icons.delete_outline),
                tooltip: _scheduleMetaHardLocked ? '잠금 중' : '스케줄 삭제',
              ),
          ],
        ),
        body: Shortcuts(
          shortcuts: <ShortcutActivator, Intent>{
            LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyZ):
                const _UndoIntent(),
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ):
                const _UndoIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _UndoIntent: CallbackAction<_UndoIntent>(
                onInvoke: (_) {
                  _doUndo();
                  return null;
                },
              ),
            },
            child: Focus(
              focusNode: _shortcutsFocus,
              autofocus: true,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: <Widget>[
                  _buildScheduleLockCard(),
                  const SizedBox(height: 14),
                  if (_lock.isLockedByPolicy(_meta)) _buildSessionLockBanner(),
                  if (_lock.isLockedByPolicy(_meta)) const SizedBox(height: 12),
                  _buildNameAndEnabled(),
                  const SizedBox(height: 14),
                  _buildTimeAndDays(),
                  const SizedBox(height: 14),
                  _buildSearchBar(),
                  const SizedBox(height: 14),
                  _buildUnifiedBlockRulesCard(),
                  const SizedBox(height: 14),
                  _buildPresetsCard(),
                  const SizedBox(height: 14),
                  _buildBlockedAppsCard(),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _dirty ? _save : null,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(_dirty ? '변경 사항 저장' : '저장됨'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            border: InputBorder.none,
            hintText: '추가한 규칙 검색 (사이트·키워드·검색어)',
            suffixIcon: _searchTerm.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _searchTerm = '');
                    },
                  ),
          ),
          onChanged: (String v) => setState(() {
            _searchTerm = v.trim().toLowerCase();
            _unifiedPage = 0;
          }),
        ),
      ),
    );
  }

  Widget _buildNameAndEnabled() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                readOnly: _globalWriteLocked,
                decoration: InputDecoration(
                  labelText: '스케줄 이름',
                  hintText: '예) 공부 시간',
                  helperText: _globalWriteLocked ? '세션 잠금 중 — 이름 변경은 잠금 해제 후' : null,
                ),
                onChanged: (_) => _markDirty(),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: <Widget>[
                const Text('사용', style: TextStyle(fontSize: 11)),
                Switch(
                  value: _enabled,
                  onChanged: (bool v) {
                    if (!v && _scheduleDisableBlocked) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text(
                              '지금 막을 수 있는 시간대가 있거나 세션이 잠겨 있어요. '
                              '끄려면 먼저 잠금을 풀거나(또는 해당 시간이 지난 뒤) 다시 시도하세요.'),
                          action: SnackBarAction(
                              label: '잠금 해제', onPressed: _startUnlockCountdown),
                        ),
                      );
                      return;
                    }
                    setState(() {
                      _enabled = v;
                      _markDirty();
                    });
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeAndDays() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('주간 시간표',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                Text(
                  '${_slots.length}개 시간 슬롯',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.muted,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '요일 행의 빈 곳을 탭하면 그 요일에 슬롯을 추가합니다. '
              '색 막대(청크)를 탭하면 그 구간만 수정·삭제합니다. '
              '프리셋·「시간+요일」은 기본으로 덮어쓰지 않고 이어 붙입니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 10),
            _WeekTimetable(
              slots: _slots,
              dayNames: _dayShort,
              onTapDay: _addSlotForDay,
              onTapSlot: _editSlot,
              sessionLocked: _globalWriteLocked,
              isUrgeHighlightSlot: (s) => _slotUrgeWriteLocked(s),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                // These four are pure-add presets — _addWeekdayPreset /
                // _addAllDayEveryDay / _bulkAddSlotsForSelectedDays already
                // gate their own removal-shaped sub-paths (전체 교체 /
                // replaceExisting) on _globalWriteLocked internally. Do NOT
                // disable the chip itself here — that blocked the add path
                // too and contradicted the "잠금 중에도 추가는 가능" policy.
                ActionChip(
                  avatar: const Icon(Icons.all_inclusive, size: 16),
                  label: const Text('매일 · 온종일'),
                  onPressed: () {
                    unawaited(_addAllDayEveryDay());
                  },
                ),
                ActionChip(
                  avatar: const Icon(Icons.work_outline, size: 16),
                  label: const Text('평일 09–18'),
                  onPressed: () => _addWeekdayPreset(9 * 60, 18 * 60),
                ),
                ActionChip(
                  avatar: const Icon(Icons.school_outlined, size: 16),
                  label: const Text('평일 19–22'),
                  onPressed: () => _addWeekdayPreset(19 * 60, 22 * 60),
                ),
                ActionChip(
                  avatar: const Icon(Icons.weekend_outlined, size: 16),
                  label: const Text('주말 10–22'),
                  onPressed: () =>
                      _addWeekdayPreset(10 * 60, 22 * 60, weekend: true),
                ),
                ActionChip(
                  avatar: const Icon(Icons.touch_app_outlined, size: 16),
                  label: const Text('시간 + 요일 한 번에'),
                  onPressed: _bulkAddSlotsForSelectedDays,
                ),
                ActionChip(
                  avatar: const Icon(Icons.delete_sweep_outlined, size: 16),
                  label: const Text('전부 지우기'),
                  onPressed: _globalWriteLocked
                      ? null
                      : () {
                          setState(() {
                            _slots.removeWhere(
                              (_Slot s) => !_slotUrgeWriteLocked(s),
                            );
                            _markDirty();
                          });
                        },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '※ 빈 요일을 탭하면 시간 슬롯을 추가하고, 색칠된 슬롯을 탭하면 그 청크만 수정·삭제합니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  int get _unifiedRuleCount =>
      _domains.length + _keywords.length + _searchQueries.length;

  List<ScheduleUnifiedRuleEntry> _allUnifiedRules() =>
      ScheduleUnifiedRuleEntry.merge(
        domains: _domains,
        keywords: _keywords,
        searchQueries: _searchQueries,
      );

  List<ScheduleUnifiedRuleEntry> _filteredUnifiedRules() {
    final List<ScheduleUnifiedRuleEntry> all = _allUnifiedRules();
    if (_searchTerm.isEmpty) return all;
    return all
        .where(
          (ScheduleUnifiedRuleEntry e) =>
              e.display.toLowerCase().contains(_searchTerm),
        )
        .toList();
  }

  List<ScheduleUnifiedRuleEntry> _pagedUnifiedRules() {
    final List<ScheduleUnifiedRuleEntry> all = _filteredUnifiedRules();
    final int start = _unifiedPage * _kPageSize;
    if (start >= all.length) return all.take(_kPageSize).toList();
    return all.skip(start).take(_kPageSize).toList();
  }

  Widget _buildUnifiedBlockRulesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '차단 규칙 ($_unifiedRuleCount)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.help_outline, size: 18),
                  tooltip: '차단 방식 설명',
                  onPressed: () => _showBlockingHelp(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
            const SizedBox(height: 2),
            if (_committedBlocklistsLocked)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '스케줄 잠금 중 — 이미 넣은 규칙은 지울 수 없고, 아래에서 추가만 가능합니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.warning,
                        height: 1.35,
                      ),
                ),
              ),
            Text(
              'URL / 도메인 / 채널 / 영상 / 키워드 / 검색어 — 한 칸에 넣으면 자동 분류됩니다.\n'
              '· 한 단어 → 🔑 키워드(결과 숨김) · 두 단어 이상 → 🔍 검색어 차단\n'
              '· 강제: kw:단어 · q:게임 실황 · @채널 · youtube.com/@채널',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 6),
            _buildBlockingExplanationChips(),
            const SizedBox(height: 10),
            SmartRuleInputBar(
              controller: _domainCtrl,
              enabled: !_addingRule,
              hintText: _addAsStem
                  ? '예: porn (회전 도메인 패턴)'
                  : 'example.com · 포르노 · 게임 실황 · @채널',
              onAdd: () {
                if (_domainWarning != null) {
                  setState(() => _domainWarning = null);
                }
                _addDomain();
              },
            ),
            Row(
              children: <Widget>[
                const Spacer(),
                const SizedBox(width: 6),
                Tooltip(
                  message: '여러 줄 붙여넣기 / 파일에서 가져오기',
                  child: OutlinedButton.icon(
                    onPressed: _bulkImportDomains,
                    icon: const Icon(Icons.playlist_add, size: 16),
                    label: const Text('대량'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Switch(
                  value: _addAsStem,
                  onChanged: (bool v) => setState(() => _addAsStem = v),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _addAsStem
                        ? '패턴 모드 — 회전 도메인(.com/.xyz 변형) 차단용'
                        : '패턴 모드 (도메인만) — 위 스위치로 켜기',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _addAsStem ? AppColors.warning : AppColors.muted,
                          height: 1.35,
                        ),
                  ),
                ),
              ],
            ),
            if (_domainWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _InlineWarning(text: _domainWarning!),
              ),
            const SizedBox(height: 8),
            ..._pagedUnifiedRules().map(_unifiedRuleTile),
            if (_searchTerm.isNotEmpty && _filteredUnifiedRules().isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('검색 결과 없음'),
              ),
            _buildPaginator(
              total: _filteredUnifiedRules().length,
              page: _unifiedPage,
              onPageChanged: (int p) => setState(() { _unifiedPage = p; }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaginator({
    required int total,
    required int page,
    required ValueChanged<int> onPageChanged,
  }) {
    if (total <= _kPageSize) return const SizedBox.shrink();
    final int totalPages = ((total - 1) ~/ _kPageSize) + 1;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: page > 0 ? () => onPageChanged(page - 1) : null,
          ),
          Text('${page + 1} / $totalPages',
              style: Theme.of(context).textTheme.bodySmall),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: page < totalPages - 1 ? () => onPageChanged(page + 1) : null,
          ),
        ],
      ),
    );
  }

  /// Top-of-screen, **always-visible** lock control for *this* schedule.
  ///
  /// Pre-commitment design:
  ///   * Cooldown picker (minutes-to-wait) is visible only when **unlocked**.
  ///     Once you lock, the cooldown is frozen — future-self can't shorten it.
  ///   * "Start unlock" runs the pre-committed cooldown as a single fixed
  ///     timer. There is no per-tap duration choice.
  ///   * After the cooldown elapses, a 5-minute edit window opens.
  ///   * Cancelling the timer re-locks immediately. No bypass possible.
  Widget _buildScheduleLockCard() {
    final bool mac = Platform.isMacOS;
    final ScheduleLockPhase phase = _schedulePhase;
    final DateTime? transitionAt = _schedulePhaseTransitionAt;

    final Color tone = switch (phase) {
      ScheduleLockPhase.unlocked => mac ? MacColors.mutedInk : AppColors.muted,
      ScheduleLockPhase.locked => mac ? MacColors.warning : AppColors.warning,
      ScheduleLockPhase.countdown => mac ? MacColors.warning : AppColors.warning,
      ScheduleLockPhase.editWindow => mac ? MacColors.success : AppColors.success,
    };
    final IconData icon = switch (phase) {
      ScheduleLockPhase.unlocked => Icons.lock_outline,
      ScheduleLockPhase.locked => Icons.lock,
      ScheduleLockPhase.countdown => Icons.hourglass_top,
      ScheduleLockPhase.editWindow => Icons.lock_open,
    };

    String statusTitle;
    String statusBody;
    final int cd = _lockCooldownMinutes;
    switch (phase) {
      case ScheduleLockPhase.unlocked:
        statusTitle = '잠금 꺼짐';
        statusBody = '잠그면, 미래의 본인은 "수정 시작" 을 눌러야 하고 '
            '미리 정해 둔 $cd분 을 무조건 기다려야 풀립니다. '
            '"개에게 고기를 보여주고 안 먹게 하는" 충동은 통하지 않게 만드세요.';
        break;
      case ScheduleLockPhase.locked:
        statusTitle = '잠금 ON · 대기 $cd분';
        statusBody = '수정/삭제하려면 아래 "수정 시작" 을 누르고 $cd분 을 그대로 기다리세요. '
            '시간은 단축 불가, 줄일 수도 없습니다. (잠금 중에는 대기시간도 못 바꿉니다.)';
        break;
      case ScheduleLockPhase.countdown:
        final Duration r = transitionAt!.difference(DateTime.now());
        statusTitle = '대기 중 · ${_fmtRemaining(r)} 남음';
        statusBody = '시간이 모두 지나면 5분짜리 편집창이 자동으로 열립니다. '
            '미리 정해 둔 $cd분 은 단축 불가 — 충동이 식길 기다리는 시간입니다.';
        break;
      case ScheduleLockPhase.editWindow:
        final Duration r = transitionAt!.difference(DateTime.now());
        statusTitle = '편집창 · ${_fmtRemaining(r)} 남음';
        statusBody =
            '지금 사이트·키워드·앱을 자유롭게 삭제·수정하세요. 끝나면 자동으로 다시 잠기고 다음에도 $cd분 대기가 필요합니다.';
        break;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: tone, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      statusTitle,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: tone,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      statusBody,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: mac ? MacColors.ink : AppColors.muted,
                            height: 1.4,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (phase == ScheduleLockPhase.countdown)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _countdownProgress(),
                  minHeight: 6,
                  backgroundColor: tone.withValues(alpha: 0.18),
                  valueColor: AlwaysStoppedAnimation<Color>(tone),
                ),
              ),
            ),
          const SizedBox(height: 12),
          _buildLockCooldownPicker(phase: phase),
          const SizedBox(height: 10),
          _buildScheduleLockActions(phase: phase),
        ],
      ),
    );
  }

  /// Tally bar of mandatory wait time. **Disabled** when locked / counting
  /// down / in edit window — the commitment is frozen at lock time.
  Widget _buildLockCooldownPicker({required ScheduleLockPhase phase}) {
    final bool editable = phase == ScheduleLockPhase.unlocked;
    final List<int> options = const <int>[5, 15, 30, 60, 120, 240, 720, 1440];
    Color frame = Platform.isMacOS ? MacColors.hairline : Colors.black12;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: (Platform.isMacOS ? MacColors.surfaceAlt : Colors.black)
            .withValues(alpha: Platform.isMacOS ? 0.5 : 0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: frame),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.timer_outlined, size: 16),
              const SizedBox(width: 6),
              Text(
                editable
                    ? '미리 박을 대기시간 — 잠그면 이 숫자는 동결됩니다'
                    : '대기시간 · 잠금 중에는 변경 불가',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: options
                .map((int m) => _CooldownChip(
                      label: _cooldownLabel(m),
                      selected: _lockCooldownMinutes == m,
                      enabled: editable,
                      onTap: () => _setCooldown(m),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  static String _cooldownLabel(int minutes) {
    if (minutes < 60) return '$minutes분';
    if (minutes == 60) return '1시간';
    if (minutes % 60 == 0 && minutes < 1440) return '${minutes ~/ 60}시간';
    if (minutes == 1440) return '24시간';
    return '$minutes분';
  }

  Widget _buildScheduleLockActions({required ScheduleLockPhase phase}) {
    if (_isNew) {
      return Text(
        '※ 새 스케줄을 먼저 저장하면 잠금을 켤 수 있어요. 대기시간(위)을 미리 정해두세요.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Platform.isMacOS ? MacColors.mutedInk : AppColors.muted,
              fontSize: 11,
            ),
      );
    }
    switch (phase) {
      case ScheduleLockPhase.unlocked:
        return Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: _enableScheduleLock,
              icon: const Icon(Icons.lock, size: 16),
              label: Text('이 스케줄 잠그기 (대기 $_lockCooldownMinutes분)'),
              style: FilledButton.styleFrom(
                backgroundColor: Platform.isMacOS
                    ? MacColors.warning
                    : AppColors.warning,
                foregroundColor: Platform.isMacOS
                    ? MacColors.secondaryInk
                    : Colors.white,
              ),
            ),
          ],
        );
      case ScheduleLockPhase.locked:
        return Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: _startScheduleUnlockCountdown,
              icon: const Icon(Icons.hourglass_top, size: 16),
              label: Text('수정 시작 ($_lockCooldownMinutes분 대기)'),
            ),
          ],
        );
      case ScheduleLockPhase.countdown:
        return Row(
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _cancelScheduleUnlock,
              icon: const Icon(Icons.cancel_outlined, size: 16),
              label: const Text('취소하고 다시 잠그기'),
            ),
            const SizedBox(width: 8),
            Text(
              '※ 취소해도 단축은 안 됩니다 — 다시 시작하면 $_lockCooldownMinutes분 부터 다시.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color:
                        Platform.isMacOS ? MacColors.mutedInk : AppColors.muted,
                    fontSize: 11,
                  ),
            ),
          ],
        );
      case ScheduleLockPhase.editWindow:
        return Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: _cancelScheduleUnlock,
              icon: const Icon(Icons.lock, size: 16),
              label: const Text('지금 다시 잠그기'),
              style: FilledButton.styleFrom(
                backgroundColor: Platform.isMacOS
                    ? MacColors.warning
                    : AppColors.warning,
                foregroundColor: Platform.isMacOS
                    ? MacColors.secondaryInk
                    : Colors.white,
              ),
            ),
          ],
        );
    }
  }

  Future<void> _enableScheduleLock() async {
    if (_isNew) await _save();
    await _db.setScheduleLocked(_id, true);
    await _refreshScheduleLock();
  }

  Future<void> _setCooldown(int minutes) async {
    if (_isNew) await _save();
    final bool ok = await _db.setScheduleCooldownMinutes(_id, minutes);
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              '잠금 중에는 대기시간을 바꿀 수 없어요. 미래의 본인을 위한 의도된 제약입니다.'),
        ),
      );
      return;
    }
    setState(() => _lockCooldownMinutes = minutes);
  }

  Future<void> _startScheduleUnlockCountdown() async {
    await _db.startScheduleUnlockCountdown(_id);
    await _refreshScheduleLock();
  }

  Future<void> _cancelScheduleUnlock() async {
    await _db.cancelScheduleUnlock(_id);
    await _refreshScheduleLock();
  }

  String _fmtRemaining(Duration r) {
    if (r.isNegative) return '0:00';
    final int totalSec = r.inSeconds;
    final int h = totalSec ~/ 3600;
    final int m = (totalSec % 3600) ~/ 60;
    final int s = totalSec % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  double _countdownProgress() {
    if (_scheduleUnlockUntil == null) return 0;
    final int totalMs = _lockCooldownMinutes * 60 * 1000;
    if (totalMs <= 0) return 0;
    final int endOfCooldownMs = _scheduleUnlockUntil!.millisecondsSinceEpoch -
        LocalDatabase.kScheduleEditWindow.inMilliseconds;
    final int remainingMs = endOfCooldownMs - DateTime.now().millisecondsSinceEpoch;
    if (remainingMs <= 0) return 1;
    return ((totalMs - remainingMs) / totalMs).clamp(0.0, 1.0);
  }

  Future<void> _refreshScheduleLock() async {
    final Map<String, Object?>? row = await _db.scheduleById(_id);
    if (!mounted || row == null) return;
    final int until = (row['unlock_until'] as int?) ?? 0;
    final ({ScheduleLockPhase phase, DateTime? transitionAt}) p =
        await _db.scheduleLockPhase(_id);
    setState(() {
      _scheduleLocked = ((row['locked'] as int?) ?? 0) == 1;
      _lockCooldownMinutes = (row['lock_cooldown_minutes'] as int?) ?? 30;
      _scheduleUnlockUntil = until > DateTime.now().millisecondsSinceEpoch
          ? DateTime.fromMillisecondsSinceEpoch(until)
          : null;
      _schedulePhase = p.phase;
      _schedulePhaseTransitionAt = p.transitionAt;
    });
    // Re-poll once per second while a timer is running so the UI ticks.
    if (p.phase == ScheduleLockPhase.countdown ||
        p.phase == ScheduleLockPhase.editWindow) {
      Future<void>.delayed(const Duration(seconds: 1), _refreshScheduleLock);
    }
  }

  Widget _buildSessionLockBanner() {
    // Phase 2: grace is active — show remaining time.
    if (_inGrace && _graceExpiresAt != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.lock_open, color: AppColors.success, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '편집 가능 — ${_graceRemaining()} 남음. 사이트·키워드·시간대를 자유롭게 수정하세요.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.success,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      );
    }

    // Phase 1: countdown is running.
    if (_countdownActive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 38,
              height: 38,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  CircularProgressIndicator(
                    value: _meta.unlockCooldownSeconds > 0
                        ? _unlockCountdown / _meta.unlockCooldownSeconds
                        : 0,
                    strokeWidth: 3,
                    color: AppColors.warning,
                  ),
                  Text(
                    '$_unlockCountdown',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppColors.warning,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '잠깐, 생각해 보세요…',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.warning,
                        ),
                  ),
                  Text(
                    '$_unlockCountdown초 후 5분 편집 창이 열립니다. 취소하면 잠금이 유지됩니다.',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.muted, height: 1.3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _cancelUnlockCountdown,
              child: const Text('취소'),
            ),
          ],
        ),
      );
    }

    // Phase 0: fully locked — show unlock button.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.lock, color: AppColors.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '잠금 중 — 추가만 가능',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppColors.warning,
                      ),
                ),
                Text(
                  '기존 항목 삭제·수정·시간대 변경은 잠금 해제 후 5분간 가능합니다.',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.muted, height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _startUnlockCountdown,
            icon: const Icon(Icons.timer_outlined, size: 16),
            label: Text('잠금 해제 (${_meta.unlockCooldownSeconds}초 대기)'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockingExplanationChips() {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        _ExplainChip(
          icon: Icons.public,
          label: '🌐 도메인',
          color: AppColors.danger,
          tooltip: 'hosts/DNS — 사이트 전체 접속 차단',
        ),
        _ExplainChip(
          icon: Icons.tag,
          label: '🔑 키워드',
          color: AppColors.accent,
          tooltip: '브라우저 확장 — 검색·피드 결과에서 숨김',
        ),
        _ExplainChip(
          icon: Icons.search_off,
          label: '🔍 검색어',
          color: AppColors.warning,
          tooltip: 'Google q= · YouTube search_query= 검색 자체 차단',
        ),
        _ExplainChip(
          icon: Icons.ondemand_video,
          label: '📺 채널 · 🎬 영상',
          color: AppColors.accent,
          tooltip: '@핸들 · watch?v= URL — 확장으로 채널/영상 차단',
        ),
      ],
    );
  }

  void _showBlockingHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('통합 입력 — 무엇이 막히나요?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _HelpSection(
                icon: Icons.block,
                title: '✅ 막히는 것',
                items: <String>[
                  '해당 도메인 직접 방문 (주소창에 입력)',
                  '링크 클릭으로 해당 사이트 이동',
                  if (Platform.isWindows)
                    '모든 주요 브라우저에서 차단 (Chrome, Edge, Firefox)'
                  else
                    '모든 브라우저에서 차단 (Chrome, Safari, Firefox)',
                  '앱을 종료해도 계속 차단 유지',
                ],
                color: AppColors.success,
              ),
              const SizedBox(height: 12),
              _HelpSection(
                icon: Icons.check_circle_outline,
                title: '입력 예시',
                items: const <String>[
                  'youtube.com → 🌐 유튜브 전체 (DNS)',
                  '@WinterStarcraft → 📺 채널 영상 전부',
                  '포르노 → 🔑 검색 결과 숨김',
                  '게임 실황 (두 단어) → 🔍 검색어 차단',
                  'kw:연예 gossip → 🔑 강제 키워드',
                  'q:19금 영상 → 🔍 강제 검색어',
                ],
                color: AppColors.accent,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '💡 유튜브 채널·영상: 스케줄 ON + 앱 실행. '
                  'Chrome은 작업 표시줄·바탕화면 아이콘으로 열면 자동으로 차단이 적용됩니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('이해했습니다'),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '빠른 추가',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '버튼 하나로 사이트 여러 개를 묶음으로 이 스케줄에 넣습니다. '
              '✓ 표시된 묶음은 다시 눌러 통째로 제거할 수 있어요.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presets.map((ScheduleDomainPreset b) {
                final bool applied = _appliedPresetIds.contains(b.id);
                return Tooltip(
                  message: applied
                      ? '${b.hint}\n(적용됨 — 다시 누르면 묶음 전체 제거)'
                      : b.hint,
                  child: ActionChip(
                    avatar: Icon(
                      applied ? Icons.check_circle : b.icon,
                      size: 16,
                      color: applied ? AppColors.accent : null,
                    ),
                    label: Text('${b.name} · ${b.itemCount}'),
                    onPressed: () => applied
                        ? unawaited(_removePresetBundle(b))
                        : unawaited(_applyPreset(b)),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// Per-schedule blocked applications. On macOS this list is enforced by
  /// the native [AppBlockBridge] — any running process whose display name
  /// matches is terminated within ~2 s while the schedule is active.
  /// iOS does not allow third-party apps to terminate other apps, so on
  /// iOS the list is informational + used for the iOS Screen Time export.
  Widget _buildBlockedAppsCard() {
    final bool mac = Platform.isMacOS;
    final bool win = Platform.isWindows;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.apps,
                  size: 18,
                  color: mac ? MacColors.primary : AppColors.accent,
                ),
                const SizedBox(width: 8),
                Text(
                  '차단할 앱 (${_blockedApps.length})',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                if (mac)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: MacColors.primaryDim,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Mac · 자동 종료',
                      style: TextStyle(
                        color: MacColors.secondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else if (win)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE3F2FD),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Windows · 자동 종료',
                      style: TextStyle(
                        color: Color(0xFF0D47A1),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'iOS · 확장 전용',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (_committedBlocklistsLocked)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '스케줄 잠금 중 — 이미 넣은 앱 항목은 지울 수 없고, 추가만 가능합니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.warning,
                        height: 1.35,
                      ),
                ),
              ),
            Text(
              mac
                  ? '이 스케줄이 활성일 때 아래 앱이 켜져 있으면 2초 안에 자동으로 종료됩니다. (앱 이름은 메뉴바·Dock에 보이는 그대로)'
                  : win
                      ? '스케줄이 활성일 때, 아래 이름이 창 제목·프로세스 이름과 맞으면 주기적으로 종료를 시도합니다. '
                          '「실행 중인 앱에서 추가」를 쓰면 지금 떠 있는 창 목록에서 고를 수 있어요.'
                      : 'iOS는 시스템 정책상 앱 자동 종료가 불가능합니다. 이 목록은 Screen Time / 스크린타임 가족 공유 설정 화면에서 같이 입력해주세요.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: mac ? MacColors.mutedInk : AppColors.muted,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _appCtrl,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: '예: Discord',
                      prefixIcon: Icon(Icons.add_circle_outline, size: 18),
                    ),
                    onChanged: (_) {
                      if (_appWarning != null) {
                        setState(() => _appWarning = null);
                      }
                    },
                    onSubmitted: (_) => _addBlockedApp(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _addBlockedApp(),
                  child: const Text('추가'),
                ),
              ],
            ),
            if (win) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _globalWriteLocked
                      ? null
                      : () {
                          unawaited(_pickRunningWindowsApps());
                        },
                  icon: const Icon(Icons.playlist_add_check_outlined, size: 20),
                  label: const Text('실행 중인 앱에서 추가'),
                ),
              ),
            ],
            if (_appWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _InlineWarning(text: _appWarning!),
              ),
            const SizedBox(height: 12),
            Text(
              '빠른 추가',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: mac ? MacColors.mutedInk : AppColors.muted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _appPresets
                  .map(
                    (String n) => ActionChip(
                      avatar: const Icon(Icons.add, size: 14),
                      label: Text(n),
                      onPressed: () => _addBlockedApp(presetName: n),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            ..._blockedApps.map(_blockedAppTile),
            if (_blockedApps.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '아직 추가된 앱이 없어요.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: mac ? MacColors.mutedInk : AppColors.muted,
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _blockedAppTile(Map<String, Object?> row) {
    final String name = (row['name']! as String);
    final int createdAt = row['created_at']! as int;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.apps_outage),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _ageLabel(createdAt),
        style: TextStyle(
          color: Platform.isMacOS ? MacColors.mutedInk : AppColors.muted,
          fontSize: 11,
        ),
      ),
      trailing: IconButton(
        icon: Icon(Icons.delete_outline,
            color: _blockListRemovals ? AppColors.muted : AppColors.danger),
        tooltip: _blockListRemovals ? '잠금 중 (추가만 가능)' : '삭제 (휴지통, 30일 보관)',
        onPressed: _blockListRemovals ? null : () => _deleteBlockedApp(row),
      ),
    );
  }

  IconData _iconForUnifiedKind(UnifiedRuleKind kind, {bool isStem = false}) {
    if (isStem) return Icons.expand;
    switch (kind) {
      case UnifiedRuleKind.host:
      case UnifiedRuleKind.wildcard:
        return Icons.public;
      case UnifiedRuleKind.searchQuery:
        return Icons.search_off;
      case UnifiedRuleKind.channelURL:
        return Icons.ondemand_video;
      case UnifiedRuleKind.videoURL:
        return Icons.movie;
      case UnifiedRuleKind.keyword:
        return Icons.tag;
    }
  }

  Widget _unifiedRuleTile(ScheduleUnifiedRuleEntry entry) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_iconForUnifiedKind(entry.kind, isStem: entry.isStem)),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(entry.display, overflow: TextOverflow.ellipsis),
          ),
          UnifiedRuleKindChip(
            value: entry.display,
            isDomainRow: entry.storage == ScheduleRuleStorage.domain,
            kind: entry.kind,
          ),
          if (entry.isStem)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '패턴',
                style: TextStyle(
                  color: AppColors.warning,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        _ageLabel(entry.createdAt),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
            ),
      ),
      trailing: IconButton(
        icon: Icon(
          Icons.delete_outline,
          color: _blockListRemovals ? AppColors.muted : AppColors.danger,
        ),
        onPressed: _blockListRemovals
            ? null
            : () => _deleteUnifiedRule(entry),
        tooltip: _blockListRemovals ? '잠금 중 (추가만 가능)' : '삭제 (휴지통, 30일 보관)',
      ),
    );
  }

  Future<void> _deleteUnifiedRule(ScheduleUnifiedRuleEntry entry) async {
    switch (entry.storage) {
      case ScheduleRuleStorage.domain:
        await _deleteDomain(entry.id, entry.display);
      case ScheduleRuleStorage.keyword:
        await _deleteKeyword(entry.id, entry.display);
      case ScheduleRuleStorage.searchQuery:
        await _deleteSearchQuery(entry.id, entry.display);
    }
  }

  static String _ageLabel(int millis) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(millis);
    final Duration ago = DateTime.now().difference(t);
    if (ago.inMinutes < 1) return '방금 추가';
    if (ago.inHours < 1) return '${ago.inMinutes}분 전 추가';
    if (ago.inDays < 1) return '${ago.inHours}시간 전 추가';
    if (ago.inDays < 30) return '${ago.inDays}일 전 추가';
    return '${t.year}-${t.month.toString().padLeft(2, "0")}-${t.day.toString().padLeft(2, "0")} 추가';
  }

}

class _InlineWarning extends StatelessWidget {
  const _InlineWarning({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.40),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: AppColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.warning,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UndoAction {
  _UndoAction({required this.label, required this.undo});
  final String label;
  final Future<void> Function() undo;
}

class _UndoIntent extends Intent {
  const _UndoIntent();
}

/// One time window inside a schedule, pinned to a single weekday.
class _Slot {
  _Slot({
    required this.id,
    required this.day,
    required this.startMinute,
    required this.endMinute,
  });
  final String id;
  final int day; // 0=Mon..6=Sun
  final int startMinute; // 0..1440
  final int endMinute; // 0..1440 (1440 = end of day)

  bool get isAllDay => startMinute == 0 && endMinute >= 1440;
  int get duration => endMinute - startMinute;
}

class _BulkDaysSlotResult {
  const _BulkDaysSlotResult({
    required this.selectedDays,
    required this.startMinute,
    required this.endMinute,
    this.replaceExisting = false,
  });
  final List<int> selectedDays;
  final int startMinute;
  final int endMinute;
  final bool replaceExisting;
}

/// Pick a time range and any subset of weekdays; used to avoid repeating
/// Mon→Sat setup manually.
class _BulkDaysSlotDialog extends StatefulWidget {
  const _BulkDaysSlotDialog({required this.dayShort});
  final List<String> dayShort;

  @override
  State<_BulkDaysSlotDialog> createState() => _BulkDaysSlotDialogState();
}

class _BulkDaysSlotDialogState extends State<_BulkDaysSlotDialog> {
  Set<int> _days = <int>{0, 1, 2, 3, 4, 5};
  TimeOfDay _start = const TimeOfDay(hour: 0, minute: 0);
  int _endHour = 9;
  int _endMinute = 0;
  bool _replaceExisting = false;

  @override
  void initState() {
    super.initState();
    final ({int hour, int minute}) a =
        snapTimeOfDayToStep(_start.hour, _start.minute);
    _start = TimeOfDay(hour: a.hour, minute: a.minute);
    if (_endHour == 24 && _endMinute == 0) {
      return;
    }
    final ({int hour, int minute}) b =
        snapTimeOfDayToStep(_endHour == 24 ? 23 : _endHour, _endMinute);
    if (b.hour >= 24 || b.hour * 60 + b.minute >= 1440) {
      _endHour = 24;
      _endMinute = 0;
    } else {
      _endHour = b.hour;
      _endMinute = b.minute;
    }
  }

  Future<void> _pickStart() async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: _start,
      builder: (BuildContext ctx, Widget? child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (t != null) {
      final ({int hour, int minute}) s = snapTimeOfDayToStep(t.hour, t.minute);
      setState(() => _start = TimeOfDay(hour: s.hour, minute: s.minute));
    }
  }

  Future<void> _pickEnd() async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _endHour == 24 ? 23 : _endHour, minute: _endMinute),
      builder: (BuildContext ctx, Widget? child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (t != null) {
      setState(() {
        final ({int hour, int minute}) s =
            snapTimeOfDayToStep(t.hour, t.minute);
        if (s.hour >= 24 || s.hour * 60 + s.minute >= 1440) {
          _endHour = 24;
          _endMinute = 0;
        } else {
          _endHour = s.hour;
          _endMinute = s.minute;
        }
      });
    }
  }

  String _fmt(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final int startMin = _start.hour * 60 + _start.minute;
    final int endMin = _endHour * 60 + _endMinute;
    final bool overnight = endMin < startMin;
    final bool sameDay = endMin > startMin;
    final bool valid = _days.isNotEmpty && (sameDay || overnight);
    return AlertDialog(
      title: const Text('시간 + 요일 한 번에'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '같은 시간대를 여러 요일에 한 번에 넣습니다. '
              '기본은 기존 슬롯을 유지하고 추가만 합니다. '
              '종료 시각이 시작보다 이르면 자정 넘김(밤→다음날 아침)으로 해석합니다.',
              style: TextStyle(height: 1.35),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('선택 요일만 덮어쓰기'),
              subtitle: const Text(
                '켜면 각 선택 요일의 기존 슬롯을 지운 뒤, 이 시간만 넣습니다.',
              ),
              value: _replaceExisting,
              onChanged: (bool v) => setState(() => _replaceExisting = v),
            ),
            OutlinedButton.icon(
              onPressed: _pickStart,
              icon: const Icon(Icons.schedule),
              label: Text('시작 ${_fmt(_start.hour, _start.minute)}'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickEnd,
              icon: const Icon(Icons.timer_off_outlined),
              label: Text('종료 ${_fmt(_endHour, _endMinute)}'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List<Widget>.generate(7, (int d) {
                final bool on = _days.contains(d);
                return FilterChip(
                  label: Text(widget.dayShort[d]),
                  selected: on,
                  onSelected: (bool v) {
                    setState(() {
                      if (v) {
                        _days.add(d);
                      } else {
                        _days.remove(d);
                      }
                    });
                  },
                );
              }),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _days = <int>{0, 1, 2, 3, 4, 5, 6}),
                child: const Text('전체 요일'),
              ),
            ),
            if (!valid)
              Text(
                _days.isEmpty
                    ? '요일을 하나 이상 고르세요.'
                    : '시작과 종료가 같으면 안 됩니다. 자정 넘김은 종료를 시작보다 작게(예: 21:40→07:00) 설정하세요.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.warning),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: valid
              ? () {
                  final int startMin =
                      snapMinuteOfDayToStep(_start.hour * 60 + _start.minute);
                  final int endMin = _endHour == 24
                      ? 1440
                      : snapMinuteOfDayToStep(_endHour * 60 + _endMinute);
                  Navigator.of(context).pop(
                    _BulkDaysSlotResult(
                      selectedDays: _days.toList()..sort(),
                      startMinute: startMin,
                      endMinute: endMin,
                      replaceExisting: _replaceExisting,
                    ),
                  );
                }
              : null,
          child: const Text('적용'),
        ),
      ],
    );
  }
}

class _SlotPickerResult {
  const _SlotPickerResult({
    required this.startMinute,
    required this.endMinute,
    this.delete = false,
  });
  final int startMinute;
  final int endMinute;
  final bool delete;
}

class _SlotPickerDialog extends StatefulWidget {
  const _SlotPickerDialog({
    this.initialStartHour = 9,
    this.initialStartMinute = 0,
    this.initialEndHour = 18,
    this.initialEndMinute = 0,
    this.allowDelete = false,
  });
  final int initialStartHour;
  final int initialStartMinute;
  final int initialEndHour;
  final int initialEndMinute;
  final bool allowDelete;

  @override
  State<_SlotPickerDialog> createState() => _SlotPickerDialogState();
}

class _SlotPickerDialogState extends State<_SlotPickerDialog> {
  late TimeOfDay _start;
  late int _endHour;
  late int _endMinute;

  @override
  void initState() {
    super.initState();
    final ({int hour, int minute}) ss = snapTimeOfDayToStep(
        widget.initialStartHour, widget.initialStartMinute);
    _start = TimeOfDay(hour: ss.hour, minute: ss.minute);
    if (widget.initialEndHour == 24 && widget.initialEndMinute == 0) {
      _endHour = 24;
      _endMinute = 0;
    } else {
      final ({int hour, int minute}) se = snapTimeOfDayToStep(
        widget.initialEndHour >= 24 ? 23 : widget.initialEndHour,
        widget.initialEndMinute,
      );
      if (se.hour >= 24 || se.hour * 60 + se.minute >= 1440) {
        _endHour = 24;
        _endMinute = 0;
      } else {
        _endHour = se.hour;
        _endMinute = se.minute;
      }
    }
  }

  Future<void> _pickStart() async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: _start,
      builder: (BuildContext ctx, Widget? child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (t == null) return;
    final ({int hour, int minute}) s = snapTimeOfDayToStep(t.hour, t.minute);
    setState(() => _start = TimeOfDay(hour: s.hour, minute: s.minute));
  }

  Future<void> _pickEnd() async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _endHour == 24 ? 23 : _endHour, minute: _endMinute),
      builder: (BuildContext ctx, Widget? child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (t == null) return;
    setState(() {
      final ({int hour, int minute}) s =
          snapTimeOfDayToStep(t.hour, t.minute);
      if (s.hour >= 24 || s.hour * 60 + s.minute >= 1440) {
        _endHour = 24;
        _endMinute = 0;
      } else {
        _endHour = s.hour;
        _endMinute = s.minute;
      }
    });
  }

  void _setAllDay() {
    setState(() {
      _start = const TimeOfDay(hour: 0, minute: 0);
      _endHour = 24;
      _endMinute = 0;
    });
  }

  String _fmt(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final int startMin = _start.hour * 60 + _start.minute;
    final int endMin = _endHour * 60 + _endMinute;
    final bool overnight = endMin < startMin;
    final bool sameDay = endMin > startMin;
    final bool valid = sameDay || overnight;
    return AlertDialog(
      title: const Text('시간 슬롯'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '시작·종료는 15분 단위(…:00, …:15, …:30, …:45)로 맞춰집니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _pickStart,
            icon: const Icon(Icons.schedule),
            label: Text('시작 ${_fmt(_start.hour, _start.minute)}'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickEnd,
            icon: const Icon(Icons.timer_off_outlined),
            label: Text('종료 ${_fmt(_endHour, _endMinute)}'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: <Widget>[
              ActionChip(
                  label: const Text('온종일'), onPressed: _setAllDay),
              ActionChip(
                  label: const Text('06–09'),
                  onPressed: () => setState(() {
                        _start = const TimeOfDay(hour: 6, minute: 0);
                        _endHour = 9;
                        _endMinute = 0;
                      })),
              ActionChip(
                  label: const Text('09–18'),
                  onPressed: () => setState(() {
                        _start = const TimeOfDay(hour: 9, minute: 0);
                        _endHour = 18;
                        _endMinute = 0;
                      })),
              ActionChip(
                  label: const Text('19–22'),
                  onPressed: () => setState(() {
                        _start = const TimeOfDay(hour: 19, minute: 0);
                        _endHour = 22;
                        _endMinute = 0;
                      })),
              ActionChip(
                  label: const Text('22–24'),
                  onPressed: () => setState(() {
                        _start = const TimeOfDay(hour: 22, minute: 0);
                        _endHour = 24;
                        _endMinute = 0;
                      })),
            ],
          ),
          if (!valid)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '시작·종료가 같으면 안 됩니다. '
                '자정 넘김(예: 21:40→07:00)은 종료를 시작보다 작게 잡으면 한 번에 추가됩니다.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.warning,
                    ),
              ),
            ),
          if (valid && overnight)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '자정 넘김: 이 요일 밤부터 다음 요일 아침까지 두 구간으로 저장됩니다.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      height: 1.35,
                    ),
              ),
            ),
        ],
      ),
      actions: <Widget>[
        if (widget.allowDelete)
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              const _SlotPickerResult(
                  startMinute: 0, endMinute: 0, delete: true),
            ),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('삭제'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton.tonal(
          onPressed: valid
              ? () {
                  final int startMin = snapMinuteOfDayToStep(
                      _start.hour * 60 + _start.minute);
                  final int endMin = _endHour == 24
                      ? 1440
                      : snapMinuteOfDayToStep(_endHour * 60 + _endMinute);
                  Navigator.of(context).pop(_SlotPickerResult(
                    startMinute: startMin,
                    endMinute: endMin,
                  ));
                }
              : null,
          child: const Text('저장'),
        ),
      ],
    );
  }
}

/// Read-only(ish) weekly grid that draws the schedule's slots as horizontal
/// colored bars across 24h, one row per weekday. Tapping a row's empty space
/// adds a slot for that day; tapping an existing slot opens its editor.
///
/// [isUrgeHighlightSlot] tints slots that overlap the rolling urge buffer — tap
/// still opens the editor so the user can **expand** coverage; narrowing is
/// enforced on save in [_editSlot].
class _WeekTimetable extends StatelessWidget {
  const _WeekTimetable({
    required this.slots,
    required this.dayNames,
    required this.onTapDay,
    required this.onTapSlot,
    required this.sessionLocked,
    required this.isUrgeHighlightSlot,
  });

  final List<_Slot> slots;
  final List<String> dayNames;
  final void Function(int day) onTapDay;
  final void Function(_Slot slot) onTapSlot;
  final bool sessionLocked;
  final bool Function(_Slot slot) isUrgeHighlightSlot;

  static const double _kRowHeight = 32;
  static const double _kLabelWidth = 32;

  @override
  Widget build(BuildContext context) {
    final int nowDay = DateTime.now().weekday - 1;
    final int nowMinute =
        DateTime.now().hour * 60 + DateTime.now().minute;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double trackWidth =
            (constraints.maxWidth - _kLabelWidth - 4).clamp(120.0, 9999.0);
        return Column(
          children: <Widget>[
            // Hour axis labels (0, 6, 12, 18, 24)
            SizedBox(
              height: 14,
              child: Row(
                children: <Widget>[
                  const SizedBox(width: _kLabelWidth + 4),
                  Expanded(
                    child: Stack(
                      children: <Widget>[
                        for (int h in <int>[0, 6, 12, 18, 24])
                          Positioned(
                            left: (h / 24.0) * trackWidth - (h == 24 ? 16 : (h == 0 ? 0 : 8)),
                            top: 0,
                            child: Text(
                              h.toString().padLeft(2, '0'),
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: AppColors.muted,
                                    fontSize: 10,
                                  ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            for (int d = 0; d < 7; d++)
              _buildDayRow(
                context,
                d,
                trackWidth,
                isToday: d == nowDay,
                nowMinute: nowMinute,
              ),
          ],
        );
      },
    );
  }

  Widget _buildDayRow(
    BuildContext context,
    int day,
    double trackWidth, {
    required bool isToday,
    required int nowMinute,
  }) {
    final List<_Slot> daySlots =
        slots.where((_Slot s) => s.day == day).toList()
          ..sort((_Slot a, _Slot b) => a.startMinute.compareTo(b.startMinute));
    final bool isWeekend = day >= 5;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SizedBox(
        height: _kRowHeight,
        child: Row(
          children: <Widget>[
            SizedBox(
              width: _kLabelWidth,
              child: Text(
                dayNames[day],
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: isToday
                          ? AppColors.accent
                          : (isWeekend ? AppColors.danger : AppColors.ink),
                    ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (TapUpDetails details) {
                  if (sessionLocked) return;
                  // Only fire add when the user taps empty track space, not a slot.
                  final double x = details.localPosition.dx;
                  for (final _Slot s in daySlots) {
                    final double sx = (s.startMinute / 1440.0) * trackWidth;
                    final double ex = (s.endMinute / 1440.0) * trackWidth;
                    if (x >= sx && x <= ex) return;
                  }
                  onTapDay(day);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: isToday
                        ? AppColors.accent.withValues(alpha: 0.07)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Stack(
                    children: <Widget>[
                      // Hour grid lines
                      for (int h = 6; h <= 18; h += 6)
                        Positioned(
                          left: (h / 24.0) * trackWidth,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: 1,
                            color: Colors.black.withValues(alpha: 0.06),
                          ),
                        ),
                      // Slot bars
                      for (final _Slot s in daySlots)
                        Positioned(
                          left: (s.startMinute / 1440.0) * trackWidth,
                          top: 3,
                          bottom: 3,
                          width: ((s.endMinute - s.startMinute) / 1440.0) *
                              trackWidth,
                          child: GestureDetector(
                            onTap: sessionLocked
                                ? null
                                : () => onTapSlot(s),
                            child: Container(
                              decoration: BoxDecoration(
                                color: isUrgeHighlightSlot(s)
                                    ? AppColors.warning.withValues(alpha: 0.55)
                                    : AppColors.accent.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: isUrgeHighlightSlot(s)
                                      ? AppColors.warning
                                      : AppColors.accent,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: ((s.endMinute - s.startMinute) /
                                          1440.0) *
                                      trackWidth >
                                  46
                                  ? Text(
                                      _slotLabel(s),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      // "Now" indicator line on today's row
                      if (isToday)
                        Positioned(
                          left: (nowMinute / 1440.0) * trackWidth,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: 2,
                            color: AppColors.danger.withValues(alpha: 0.85),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _slotLabel(_Slot s) {
    if (s.isAllDay) return '온종일';
    String fmt(int m) {
      if (m >= 1440) return '24:00';
      final int h = m ~/ 60;
      final int mm = m % 60;
      return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
    }
    return '${fmt(s.startMinute)}–${fmt(s.endMinute)}';
  }
}

/// Result of [_BulkAddDomainsDialog]: list of raw host strings and whether
/// they should be treated as stem patterns (rotating-domain mode).
class _BulkResult {
  const _BulkResult(this.lines, {required this.asStem});
  final List<String> lines;
  final bool asStem;
}

/// Paste-many-or-pick-file dialog. Keeps the user inside the schedule edit
/// surface — no need to leave to the global Import/Export dialog.
class _BulkAddDomainsDialog extends StatefulWidget {
  const _BulkAddDomainsDialog();

  @override
  State<_BulkAddDomainsDialog> createState() => _BulkAddDomainsDialogState();
}

class _BulkAddDomainsDialogState extends State<_BulkAddDomainsDialog> {
  final TextEditingController _ctrl = TextEditingController();
  bool _asStem = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final FilePickerResult? r = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (r == null) return;
      final batch =
          await ImportService.instance.parseColdTurkeyFile(r.files.single.path!);
      if (!mounted) return;
      final List<String> lines =
          batch.rules.map((ColdTurkeyParsedRule r) => r.raw).toList();
      setState(() {
        final String existing = _ctrl.text.trim();
        _ctrl.text =
            existing.isEmpty ? lines.join('\n') : '$existing\n${lines.join('\n')}';
        _error = lines.isEmpty ? '파일에서 규칙을 찾지 못했습니다.' : null;
      });
    } catch (e) {
      AppLogger.instance.error('bulk file pick failed', error: e);
      if (!mounted) return;
      setState(() => _error = '파일 가져오기 실패: $e');
    }
  }

  void _submit() {
    final List<String> lines = _ctrl.text
        .split(RegExp(r'[\r\n,;]+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty && !s.startsWith('#'))
        .toList();
    Navigator.of(context).pop(_BulkResult(lines, asStem: _asStem));
  }

  @override
  Widget build(BuildContext context) {
    final Color muted =
        Platform.isMacOS ? MacColors.mutedInk : AppColors.muted;
    return AlertDialog(
      title: const Text('여러 사이트 한 번에 추가'),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '한 줄에 도메인·경로·URL 패턴을 붙여넣거나 파일을 가져오세요. '
              '(예: chess.com, duolingo.com/chess, *.*/*q=*체스*) '
              '도메인은 DNS, 경로·패턴은 브라우저 확장에서 막습니다.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                minLines: 6,
                autocorrect: false,
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'example.com\nads.example.com\nbadsite.net',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Switch(
                  value: _asStem,
                  onChanged: (bool v) => setState(() => _asStem = v),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _asStem
                        ? '패턴 모드 — 각 항목을 .com/.net/.xyz 등으로 확장 (회전 도메인 차단용)'
                        : '패턴 모드 끄기 — 입력 그대로 한 줄당 한 도메인',
                    style: TextStyle(
                      color: _asStem
                          ? (Platform.isMacOS
                              ? MacColors.warning
                              : AppColors.warning)
                          : muted,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  color: Platform.isMacOS
                      ? MacColors.danger
                      : AppColors.danger,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton.icon(
          onPressed: _pickFile,
          icon: const Icon(Icons.upload_file, size: 16),
          label: const Text('파일에서 가져오기'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.playlist_add_check, size: 16),
          label: const Text('전부 추가'),
        ),
      ],
    );
  }
}

class _ExplainChip extends StatelessWidget {
  const _ExplainChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.tooltip,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({
    required this.icon,
    required this.title,
    required this.items,
    required this.color,
  });

  final IconData icon;
  final String title;
  final List<String> items;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
        const SizedBox(height: 6),
        ...items.map(
          (String s) => Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('• ', style: Theme.of(context).textTheme.bodySmall),
                Expanded(
                  child: Text(s,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(height: 1.35)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One option in the pre-commit cooldown picker.
///
/// `enabled = false` means the schedule is currently locked / counting down /
/// in its edit window — the user pre-committed a number and is not allowed
/// to mutate it on impulse. The chip still renders so the user can SEE the
/// committed value, but it can't be tapped.
class _CooldownChip extends StatelessWidget {
  const _CooldownChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool mac = Platform.isMacOS;
    final Color accent = mac ? MacColors.primary : AppColors.accent;
    final Color ink = mac ? MacColors.secondary : AppColors.accent;
    final Color disabledFg =
        mac ? MacColors.mutedInk : AppColors.muted.withValues(alpha: 0.7);
    final Color fg = !enabled
        ? (selected ? accent : disabledFg)
        : (selected ? Colors.white : ink);
    final Color bg = selected
        ? accent
        : (mac
            ? MacColors.primaryDim
            : AppColors.accent.withValues(alpha: 0.12));
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  selected
                      ? Icons.check_circle
                      : (enabled ? Icons.timer_outlined : Icons.lock),
                  size: 14,
                  color: fg,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
