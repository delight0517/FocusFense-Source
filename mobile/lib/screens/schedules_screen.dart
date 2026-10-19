import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/apply_activation_report.dart';
import '../models/rules_meta.dart';
import '../services/windows_apply_status_service.dart';
import '../services/local_database.dart';
import '../services/lock_policy_service.dart';
import '../services/mac_system_block_service.dart';
import '../services/windows_system_block_service.dart';
import '../theme/app_colors.dart';
import '../services/schedule_block_stats_service.dart';
import '../services/schedule_change_bus.dart';
import '../utils/schedule_urge_edit_guard.dart';
import '../widgets/apply_activation_dialog.dart';
import '../widgets/chat_schedule_panel.dart';
import '../widgets/import_export_dialog.dart';
import '../widgets/protection_info_card.dart';
import 'diagnostics_screen.dart';
import 'schedule_edit_screen.dart';

/// Schedule-first home: list of schedules, each one containing its own
/// keywords + domains. Active schedule rules are the ones enforced now.
class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({super.key, this.highlightScheduleName});

  /// When set (from the block-notice popup's "스케줄 설정 열기" button, via the
  /// `?highlight=` route query param), the matching schedule card is scrolled
  /// into view and briefly glows so the user sees exactly which schedule is
  /// responsible — no hunting through the list.
  final String? highlightScheduleName;

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  final LockPolicyService _lock = LockPolicyService.instance;

  List<Map<String, Object?>> _schedules = <Map<String, Object?>>[];
  final Map<String, List<Map<String, Object?>>> _slotsByScheduleId =
      <String, List<Map<String, Object?>>>{};
  RulesMeta _meta = RulesMeta.defaults;
  bool _inGrace = false;
  DateTime? _graceUntil;
  bool _macActive = false;
  bool _browserProtectionOk = false;
  bool _macBusy = false;
  int _activeSchedulesNowCount = 0;
  bool _scheduleOnButNoDomains = false;

  /// 1-second ticker so the per-schedule unlock countdown updates live without
  /// the user having to interact. Only re-renders if there's at least one
  /// schedule currently in a grace window.
  Timer? _tick;

  // Per-schedule card keys so `Scrollable.ensureVisible` can find the exact
  // card once data loads. Populated lazily as cards build.
  final Map<String, GlobalKey> _cardKeys = <String, GlobalKey>{};
  String? _pendingHighlightName;
  String? _highlightedScheduleId;
  Timer? _highlightClearTimer;

  @override
  void initState() {
    super.initState();
    _pendingHighlightName = widget.highlightScheduleName;
    _reload();
    // The standalone Chat tab lives in a different branch and is kept alive
    // by go_router's IndexedStack the same way this screen is — it can't
    // call this State's `_reload` directly, so it broadcasts here instead.
    ScheduleChangeBus.instance.addListener(_reload);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final bool anyGrace = _schedules.any((Map<String, Object?> r) {
        final int u = (r['unlock_until'] as int?) ?? 0;
        return u > DateTime.now().millisecondsSinceEpoch;
      });
      if (anyGrace || _inGrace) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant SchedulesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The shell route reuses this State when re-navigating to the same tab,
    // so a second "스케줄 설정 열기" click (different schedule) wouldn't
    // otherwise re-trigger initState's one-shot highlight.
    if (widget.highlightScheduleName != null &&
        widget.highlightScheduleName != oldWidget.highlightScheduleName) {
      _pendingHighlightName = widget.highlightScheduleName;
      _maybeApplyPendingHighlight();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _highlightClearTimer?.cancel();
    ScheduleChangeBus.instance.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final List<Map<String, Object?>> rows = await _db.schedules();
    final RulesMeta m = await _db.rulesMeta();
    final DateTime? grace = await _lock.graceExpiresAt();
    final bool macActive = Platform.isMacOS
        ? await MacSystemBlockService.instance.isActive()
        : Platform.isWindows
        ? await WindowsSystemBlockService.instance.isActive()
        : false;
    bool browserProtectionOk = false;
    if (Platform.isWindows) {
      browserProtectionOk =
          await WindowsApplyStatusService.isBrowserProtectionSufficient();
    }
    final Map<String, List<Map<String, Object?>>> slotMap =
        <String, List<Map<String, Object?>>>{};
    for (final Map<String, Object?> r in rows) {
      final String sid = r['id']! as String;
      slotMap[sid] = await _db.slotsForSchedule(sid);
    }
    final DateTime now = DateTime.now();
    final List<Map<String, Object?>> activeNow = await _db.schedulesActiveNow(
      now,
    );
    final List<Map<String, Object?>> domsNow = await _db.domainsActiveNow(now);
    if (!mounted) return;
    setState(() {
      _schedules = rows;
      _slotsByScheduleId
        ..clear()
        ..addAll(slotMap);
      _meta = m;
      _graceUntil = grace;
      _inGrace = grace != null && DateTime.now().isBefore(grace);
      _macActive = macActive;
      _browserProtectionOk = browserProtectionOk;
      _activeSchedulesNowCount = activeNow.length;
      _scheduleOnButNoDomains = activeNow.isNotEmpty && domsNow.isEmpty;
    });
    _maybeApplyPendingHighlight();
  }

  /// Finds the schedule named [_pendingHighlightName] (case/whitespace
  /// insensitive) among the just-loaded `_schedules`, scrolls its card into
  /// view, and glows it for a few seconds. One-shot per navigation — cleared
  /// immediately so a later manual `_reload()` doesn't re-trigger it.
  void _maybeApplyPendingHighlight() {
    final String? target = _pendingHighlightName;
    if (target == null || target.trim().isEmpty) return;
    _pendingHighlightName = null;
    final String needle = target.trim().toLowerCase();
    Map<String, Object?>? match;
    for (final Map<String, Object?> row in _schedules) {
      if ('${row['name']}'.trim().toLowerCase() == needle) {
        match = row;
        break;
      }
    }
    if (match == null) return;
    final String id = match['id']! as String;
    if (!mounted) return;
    setState(() => _highlightedScheduleId = id);
    _highlightClearTimer?.cancel();
    _highlightClearTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _highlightedScheduleId = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? cardCtx = _cardKeys[id]?.currentContext;
      if (cardCtx == null) return;
      unawaited(
        Scrollable.ensureVisible(
          cardCtx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          alignment: 0.1,
        ),
      );
    });
  }

  Widget _buildScheduleHintsBanner() {
    if (_activeSchedulesNowCount <= 1 && !_scheduleOnButNoDomains) {
      return const SizedBox.shrink();
    }
    return Card(
      color: AppColors.warning.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (_activeSchedulesNowCount > 1)
              Text(
                '지금 $_activeSchedulesNowCount개 스케줄 시간대가 겹칩니다. '
                '규칙은 합쳐져 적용되며, 정밀 타격(키워드)도 모두 활성화됩니다.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(height: 1.35),
              ),
            if (_activeSchedulesNowCount > 1 && _scheduleOnButNoDomains)
              const SizedBox(height: 8),
            if (_scheduleOnButNoDomains)
              Text(
                '스케줄 시간대는 켜져 있지만 막을 **사이트(도메인)** 가 없습니다. '
                '야간에도 차단이 안 되면 스케줄에 도메인을 추가하거나, '
                '「정밀 타격」 키워드 + 브라우저 확장을 확인하세요.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(height: 1.35),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _create() async {
    if (Platform.isMacOS) {
      await _openInModal(null);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const ScheduleEditScreen()),
      );
    }
    await _reload();
    // Auto-apply is wired through BlockSyncService on every DB write
    // (see LocalDatabase._kickBackup), so changes flow to /etc/hosts in
    // the background. No manual nag is needed here.
  }

  /// macOS-native edit affordance: a centered modal dialog over the list.
  /// Keeps the user anchored in the schedule list so context is never lost.
  Future<void> _openInModal(String? scheduleId) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (BuildContext ctx) {
        final Size screen = MediaQuery.of(ctx).size;
        final double w = screen.width.clamp(600, 880).toDouble();
        final double h = (screen.height * 0.88).clamp(520, 820).toDouble();
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: MacColors.hairline),
          ),
          child: SizedBox(
            width: w,
            height: h,
            child: ScheduleEditScreen(scheduleId: scheduleId),
          ),
        );
      },
    );
  }

  Future<void> _import() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) =>
          ImportExportDialog(onScheduleImported: _reload),
    );
  }

  Future<void> _open(String id) async {
    if (Platform.isMacOS) {
      await _openInModal(id);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ScheduleEditScreen(scheduleId: id),
        ),
      );
    }
    await _reload();
  }

  Future<void> _applyMacBlock() async {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    setState(() => _macBusy = true);
    ApplyActivationReport? report;
    try {
      if (Platform.isWindows) {
        await showApplyActivationDialog(
          context,
          runApply: (onPhase) async {
            report = await WindowsApplyStatusService.instance.applyAndVerify(
              onPhase: onPhase,
            );
            return report!;
          },
        );
      } else {
        await showApplyActivationDialog(
          context,
          runApply: (onPhase) async {
            onPhase?.call('macOS hosts 적용 중…');
            final MacBlockResult r = await MacSystemBlockService.instance
                .activate();
            return ApplyActivationReport(
              success: r.status == MacBlockStatus.success,
              steps: <ApplyActivationStep>[
                ApplyActivationStep(
                  id: 'hosts',
                  label: '/etc/hosts',
                  ok: r.status == MacBlockStatus.success,
                  detail: r.message ?? r.status.name,
                ),
              ],
              summary: r.status == MacBlockStatus.success
                  ? '시스템 차단이 활성화되었습니다.'
                  : '적용 실패 또는 취소',
            );
          },
        );
      }
    } finally {
      if (mounted) setState(() => _macBusy = false);
    }
    final bool active = Platform.isMacOS
        ? await MacSystemBlockService.instance.isActive()
        : await WindowsSystemBlockService.instance.isActive();
    if (!mounted) return;
    setState(() {
      _macActive = active;
    });
    if (Platform.isWindows && report != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            report!.success
                ? report!.summary.split('\n').first
                : report!.summary.split('\n').first,
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      await _reload();
    } else if (Platform.isMacOS) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            active ? '시스템 차단이 활성화되었습니다.' : 'hosts 블록이 보이지 않습니다 — 다시 적용하세요.',
          ),
        ),
      );
    }
  }

  void _openDiagnostics() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
    );
  }

  Future<void> _startGrace() async {
    await _lock.startGrace();
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('5분 동안 잠금 해제 — 이 시간 안에 수정/삭제 가능')),
    );
  }

  // Filter state for Mac dense list (CT-style top filter chips).
  _MacFilter _macFilter = _MacFilter.all;
  _MacSort _macSort = _MacSort.created;

  @override
  Widget build(BuildContext context) {
    final bool baseLocked = _lock.isLockedByPolicy(_meta);
    final bool effectivelyLocked = baseLocked && !_inGrace;
    if (Platform.isMacOS) {
      return _buildMacLayout(context, baseLocked, effectivelyLocked);
    }
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: <Widget>[
          Text(
            '스케줄',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '시간대마다 다른 차단 규칙을 만드세요. 각 스케줄 안에 사이트·키워드를 모아 넣으면, 그 시간 동안에만 막힙니다. 24시간 막고 싶다면 0–24시 한 개로 만들면 됩니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          if (baseLocked) _buildLockBanner(context, effectivelyLocked),
          if (Platform.isWindows) ...<Widget>[
            const SizedBox(height: 8),
            _buildApplyBanner(context),
          ],
          const SizedBox(height: 12),
          ChatScheduleEntryCard(onApplied: _reload),
          const SizedBox(height: 12),
          _buildScheduleHintsBanner(),
          if (_activeSchedulesNowCount > 1 || _scheduleOnButNoDomains)
            const SizedBox(height: 8),
          if (_schedules.isEmpty)
            _buildEmptyHero(context)
          else
            ..._schedules.map(_buildScheduleCard),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.add_alarm),
                  label: const Text('새 스케줄 만들기'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _import,
                icon: const Icon(Icons.upload_file),
                label: const Text('파일 임포트'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const ProtectionInfoCard(),
        ],
      ),
    );
  }

  Widget _buildApplyBanner(BuildContext context) {
    final bool fullyProtected =
        _macActive || (Platform.isWindows && _browserProtectionOk);
    final Color stripe = fullyProtected ? AppColors.success : AppColors.muted;
    return Card(
      elevation: 0,
      color: stripe.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: stripe.withValues(alpha: 0.40)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  fullyProtected ? Icons.verified_user : Icons.shield_outlined,
                  color: stripe,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        fullyProtected
                            ? (_macActive
                                  ? '시스템 차단 작동 중 (hosts + DNS)'
                                  : '브라우저 보호 작동 중 (확장 연결됨)')
                            : '차단 적용 필요',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        fullyProtected
                            ? (_macActive
                                  ? '스케줄·도메인 변경 후 자동 동기화를 시도합니다. Windows 승인 창이 뜨면 「예」를 눌러야 hosts/DNS까지 막힙니다.'
                                  : '키워드·유튜브·도메인은 Chrome·Edge·Firefox 확장으로 적용 중입니다. '
                                        '시스템 hosts는 선택 사항(UAC)입니다.')
                            : '「지금 적용」을 누른 뒤 Windows 승인 창에서 「예」를 눌러야 사이트 차단이 끝납니다. '
                                  '브라우저 보호가 먼저 필요하면 설정 → 쉬운 설치를 진행하세요.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _macBusy ? null : _applyMacBlock,
                  icon: _macBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(_macActive ? '다시 적용' : '지금 적용'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _openDiagnostics,
                icon: const Icon(Icons.medical_services_outlined, size: 16),
                label: const Text('차단 안 되면 진단 열기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLockBanner(BuildContext context, bool effectivelyLocked) {
    return Card(
      color: effectivelyLocked
          ? AppColors.warning.withValues(alpha: 0.10)
          : AppColors.success.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: (effectivelyLocked ? AppColors.warning : AppColors.success)
              .withValues(alpha: 0.40),
        ),
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              effectivelyLocked ? Icons.lock : Icons.lock_open,
              color: effectivelyLocked ? AppColors.warning : AppColors.success,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    effectivelyLocked ? '잠금 중' : '5분 잠금 해제 모드',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    effectivelyLocked
                        ? '추가는 가능합니다. 삭제·해제는 잠금 해제 후 5분 동안만 됩니다. 실수로 돌아가도 5분은 계속 흐릅니다.'
                        : '${_remainingGrace()} 남음. 이 동안 모든 수정·삭제 가능. 끝나면 자동으로 다시 잠깁니다.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (effectivelyLocked)
                    FilledButton.tonalIcon(
                      onPressed: _startGrace,
                      icon: const Icon(Icons.timer_outlined),
                      label: const Text('5분 동안 잠금 해제'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _remainingGrace() {
    if (_graceUntil == null) return '';
    final Duration r = _graceUntil!.difference(DateTime.now());
    if (r.isNegative) return '0:00';
    final int m = r.inMinutes;
    final int s = r.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildEmptyHero(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.schedule, color: AppColors.accent),
                const SizedBox(width: 8),
                Text(
                  '첫 스케줄을 만들어주세요',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '예) "공부 시간" — 09:00-12:00, 평일\n'
              '    그 안에 차단할 사이트와 키워드를 넣으면, 그 시간에만 막힙니다.\n'
              '예) "취침 전" — 22:00-07:00, 매일\n'
              '    SNS와 자극적 키워드 추가 → 그 시간만 막힘.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleCard(Map<String, Object?> row) {
    final String id = row['id']! as String;
    final String name = row['name']! as String;
    final bool enabled = (row['enabled'] as int) == 1;
    final List<Map<String, Object?>> slots =
        _slotsByScheduleId[id] ?? <Map<String, Object?>>[];

    final bool activeNow = _isActiveNowFromSlots(enabled, slots, row);
    final String summary = _summariseSlots(slots, row);
    final bool highlighted = id == _highlightedScheduleId;
    final GlobalKey cardKey = _cardKeys.putIfAbsent(id, () => GlobalKey());

    return Padding(
      key: cardKey,
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: highlighted
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.45),
                    blurRadius: 14,
                    spreadRadius: 2,
                  ),
                ],
              )
            : null,
        child: Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: highlighted
                  ? AppColors.accent
                  : activeNow
                  ? AppColors.success.withValues(alpha: 0.55)
                  : Colors.black.withValues(alpha: 0.06),
              width: highlighted ? 2.2 : 1,
            ),
          ),
          color: highlighted
              ? AppColors.accent.withValues(alpha: 0.08)
              : activeNow
              ? AppColors.success.withValues(alpha: 0.06)
              : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _open(id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        activeNow ? Icons.play_circle : Icons.schedule,
                        color: activeNow ? AppColors.success : AppColors.muted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      _buildIosLockPill(row),
                      const SizedBox(width: 6),
                      Switch(
                        value: enabled,
                        onChanged: (bool v) async {
                          if (!v && await _isRowLocked(row)) {
                            _showLockedToast(row);
                            return;
                          }
                          await _db.setScheduleEnabled(id, v);
                          await _reload();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    summary,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                  const SizedBox(height: 4),
                  if (activeNow)
                    Text(
                      '지금 활성 중 — 이 스케줄의 규칙이 시스템 차단에 반영됩니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  _ScheduleStatsBadge(scheduleId: id),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Compact lock pill used in the iOS-flavoured schedule card. Same tap target
  /// as on Mac — opens `_ScheduleLockSheet`.
  ///
  /// Pre-commitment model (v8): visual reflects the 4 phases —
  /// unlocked / locked / countdown (cooldown running) / editWindow.
  Widget _buildIosLockPill(Map<String, Object?> row) {
    final ({ScheduleLockPhase phase, Duration? remaining, int cooldownMin}) s =
        _phaseFor(row);
    late Color tone;
    late IconData icon;
    late String text;
    switch (s.phase) {
      case ScheduleLockPhase.editWindow:
        tone = AppColors.success;
        icon = Icons.lock_open;
        text = '편집 ${_mmss(s.remaining!)}';
        break;
      case ScheduleLockPhase.countdown:
        tone = AppColors.warning;
        icon = Icons.hourglass_top;
        text = '대기 ${_mmss(s.remaining!)}';
        break;
      case ScheduleLockPhase.locked:
        tone = AppColors.warning;
        icon = Icons.lock;
        text = '잠금 ${s.cooldownMin}분';
        break;
      case ScheduleLockPhase.unlocked:
        tone = AppColors.muted;
        icon = Icons.lock_open;
        text = '잠금 OFF';
        break;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showLockSheet(row),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tone.withValues(alpha: 0.40)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 12, color: tone),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                color: tone,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Derives the lock state of [row] purely from columns embedded in the
  /// schedules record. Used by both the iOS and Mac pills; [_isRowLocked]
  /// additionally checks the rolling urge buffer against loaded slot rows.
  /// Avoids extra DB roundtrips on the list path.
  ({ScheduleLockPhase phase, Duration? remaining, int cooldownMin}) _phaseFor(
    Map<String, Object?> row,
  ) {
    final int locked = (row['locked'] as int?) ?? 0;
    final int cooldownMin = (row['lock_cooldown_minutes'] as int?) ?? 30;
    final int started = (row['unlock_started_at'] as int?) ?? 0;
    if (locked != 1) {
      return (
        phase: ScheduleLockPhase.unlocked,
        remaining: null,
        cooldownMin: cooldownMin,
      );
    }
    if (started <= 0) {
      return (
        phase: ScheduleLockPhase.locked,
        remaining: null,
        cooldownMin: cooldownMin,
      );
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int endOfCooldown = started + cooldownMin * 60 * 1000;
    final int endOfEdit =
        endOfCooldown + LocalDatabase.kScheduleEditWindow.inMilliseconds;
    if (now < endOfCooldown) {
      return (
        phase: ScheduleLockPhase.countdown,
        remaining: Duration(milliseconds: endOfCooldown - now),
        cooldownMin: cooldownMin,
      );
    }
    if (now < endOfEdit) {
      return (
        phase: ScheduleLockPhase.editWindow,
        remaining: Duration(milliseconds: endOfEdit - now),
        cooldownMin: cooldownMin,
      );
    }
    return (
      phase: ScheduleLockPhase.locked,
      remaining: null,
      cooldownMin: cooldownMin,
    );
  }

  static String _cooldownLabel(int minutes) {
    if (minutes < 60) return '$minutes분';
    if (minutes == 60) return '1시간';
    if (minutes % 60 == 0 && minutes < 1440) return '${minutes ~/ 60}시간';
    if (minutes == 1440) return '24시간';
    return '$minutes분';
  }

  static String _mmss(Duration r) {
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

  static bool _isActiveNowFromSlots(
    bool enabled,
    List<Map<String, Object?>> slots,
    Map<String, Object?> legacyRow,
  ) {
    if (!enabled) return false;
    final DateTime now = DateTime.now();
    final int today = now.weekday - 1;
    final int minuteOfDay = now.hour * 60 + now.minute;
    if (slots.isNotEmpty) {
      return slots.any((Map<String, Object?> s) {
        if ((s['day']! as int) != today) return false;
        final int st = s['start_minute']! as int;
        final int en = s['end_minute']! as int;
        if (st == 0 && en >= 1440) return true;
        return minuteOfDay >= st && minuteOfDay < en;
      });
    }
    final int start = (legacyRow['start_minute'] as int?) ?? 0;
    final int end = (legacyRow['end_minute'] as int?) ?? 0;
    final int mask = (legacyRow['days_mask'] as int?) ?? 0;
    final int dayBit = 1 << today;
    if ((mask & dayBit) == 0) return false;
    if (start == end) return true;
    if (start < end) return minuteOfDay >= start && minuteOfDay < end;
    return minuteOfDay >= start || minuteOfDay < end;
  }

  static String _summariseSlots(
    List<Map<String, Object?>> slots,
    Map<String, Object?> legacyRow,
  ) {
    if (slots.isEmpty) {
      final int s = (legacyRow['start_minute'] as int?) ?? 0;
      final int e = (legacyRow['end_minute'] as int?) ?? 0;
      final int m = (legacyRow['days_mask'] as int?) ?? 0;
      if (m == 0) return '시간 슬롯 없음 — 탭해서 추가하세요';
      return '${_fmtMin(s)} – ${_fmtMin(e)} · ${_dayMaskLabel(m)}';
    }
    const List<String> names = <String>['월', '화', '수', '목', '금', '토', '일'];
    final Map<int, List<String>> byDay = <int, List<String>>{};
    for (final Map<String, Object?> s in slots) {
      final int d = s['day']! as int;
      final int st = s['start_minute']! as int;
      final int en = s['end_minute']! as int;
      final String label = (st == 0 && en >= 1440)
          ? '온종일'
          : '${_fmtMin(st)}–${_fmtMin(en)}';
      byDay.putIfAbsent(d, () => <String>[]).add(label);
    }
    final List<String> parts = <String>[];
    for (int d = 0; d < 7; d++) {
      final List<String>? v = byDay[d];
      if (v == null) continue;
      parts.add('${names[d]} ${v.join(", ")}');
    }
    return parts.join(' · ');
  }

  static String _fmtMin(int totalMin) {
    final int h = totalMin ~/ 60;
    final int m = totalMin % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  static String _dayMaskLabel(int mask) {
    const List<String> names = <String>['월', '화', '수', '목', '금', '토', '일'];
    if (mask == 127) return '매일';
    if (mask == 0x1F) return '평일';
    if (mask == 0x60) return '주말';
    final List<String> picked = <String>[];
    for (int i = 0; i < 7; i++) {
      if ((mask & (1 << i)) != 0) picked.add(names[i]);
    }
    return picked.isEmpty ? '비활성' : picked.join('·');
  }

  // ───────────────────────────── macOS layout ─────────────────────────────
  // Cold Turkey-inspired: header bar with title + action icons,
  // filter chips, dense list of rows. Each row: left stripe + name +
  // summary chip + time/lock badge + ON/OFF switch.

  Widget _buildMacLayout(
    BuildContext context,
    bool baseLocked,
    bool effectivelyLocked,
  ) {
    final List<Map<String, Object?>> visible = _macFilteredSchedules();
    return Container(
      color: MacColors.background,
      child: Column(
        children: <Widget>[
          _buildMacToolbar(context),
          if (baseLocked) _buildMacLockStrip(effectivelyLocked),
          if (Platform.isMacOS) _buildMacApplyStrip(),
          _buildMacFilterRow(),
          const Divider(height: 1, color: MacColors.hairline),
          Expanded(
            child: visible.isEmpty
                ? _buildMacEmpty()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: visible.length + 1,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int i) {
                      if (i == visible.length) return _buildMacHowItWorks();
                      return _buildMacRow(visible[i]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Twin explainer card placed at the bottom of the schedule list.
  /// Reinforces *why* the friction layer exists for the addicted-user
  /// persona who, under impulse, would otherwise just disable everything.
  Widget _buildMacHowItWorks() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: _macExplainerCard(
              icon: Icons.bolt,
              accent: MacColors.primary,
              title: '어떻게 차단되나요?',
              lines: const <String>[
                '1. 스케줄을 켜면, 그 시간대에 도메인이 /etc/hosts 에 들어갑니다.',
                '2. Safari·Chrome·Firefox 가 그 도메인을 IP로 바꾸지 못해 자동으로 막힙니다.',
                '3. Firefox 는 DoH 가 자동으로 꺼져, 이 시스템 차단을 우회하지 못합니다.',
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _macExplainerCard(
              icon: Icons.lock,
              accent: MacColors.warning,
              title: '왜 바로 끌 수 없죠?',
              lines: const <String>[
                '• 잠금이 켜져 있으면 추가만 가능, 삭제·해제는 불가능합니다.',
                '• 충동이 올 때 "잠금 해제 → 5분 카운트다운" 을 거쳐야 끌 수 있어요.',
                '• 5분 동안 마음이 식길 기다리는 게 이 앱의 핵심 작동 원리입니다.',
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _macExplainerCard({
    required IconData icon,
    required Color accent,
    required String title,
    required List<String> lines,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: MacColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MacColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: MacColors.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...lines.map(
            (String t) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                t,
                style: const TextStyle(
                  color: MacColors.mutedInk,
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMacToolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
      child: Row(
        children: <Widget>[
          const Text(
            'WEBSITE & APP BLOCKS',
            style: TextStyle(
              color: MacColors.ink,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: MacColors.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: MacColors.hairline),
            ),
            child: Text(
              '${_schedules.length}',
              style: const TextStyle(
                color: MacColors.mutedInk,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Spacer(),
          _MacToolbarButton(
            icon: Icons.add,
            tone: _MacBtnTone.primary,
            onTap: _create,
          ),
          const SizedBox(width: 6),
          _MacToolbarButton(
            icon: _macSort == _MacSort.created
                ? Icons.history
                : (_macSort == _MacSort.name
                      ? Icons.sort_by_alpha
                      : Icons.bolt),
            tone: _MacBtnTone.neutral,
            onTap: _toggleSort,
          ),
          const SizedBox(width: 6),
          _MacToolbarButton(
            icon: Icons.more_horiz,
            tone: _MacBtnTone.neutral,
            onTap: _showMacMenu,
          ),
        ],
      ),
    );
  }

  void _toggleSort() {
    setState(() {
      _macSort = _MacSort.values[(_macSort.index + 1) % _MacSort.values.length];
    });
  }

  Future<void> _showMacMenu() async {
    final RenderBox btn = context.findRenderObject()! as RenderBox;
    final Offset pos = btn.localToGlobal(Offset.zero);
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx + 200, 60, 24, 0),
      color: MacColors.surface,
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'import', child: Text('파일 임포트…')),
        PopupMenuItem<String>(value: 'diag', child: Text('차단 진단')),
      ],
    );
    if (choice == 'import') await _import();
    if (choice == 'diag') _openDiagnostics();
  }

  Widget _buildMacLockStrip(bool effectivelyLocked) {
    final Color tone = effectivelyLocked
        ? MacColors.warning
        : MacColors.success;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        border: const Border(bottom: BorderSide(color: MacColors.hairline)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            effectivelyLocked ? Icons.lock : Icons.lock_open,
            color: tone,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              effectivelyLocked
                  ? '잠금 중 — 추가만 가능, 삭제·해제는 잠금 해제 후 5분 동안만'
                  : '잠금 해제 중 (${_remainingGrace()}) — 곧 다시 잠깁니다',
              style: const TextStyle(color: MacColors.ink, fontSize: 12),
            ),
          ),
          if (effectivelyLocked)
            TextButton.icon(
              onPressed: _startGrace,
              icon: const Icon(Icons.timer_outlined, size: 14),
              label: const Text('5분 해제', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(foregroundColor: MacColors.secondary),
            ),
        ],
      ),
    );
  }

  Widget _buildMacApplyStrip() {
    final bool on = _macActive;
    final Color tone = on ? MacColors.success : MacColors.mutedInk;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        border: const Border(bottom: BorderSide(color: MacColors.hairline)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            on ? Icons.verified_user : Icons.shield_outlined,
            color: tone,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              on
                  ? '시스템 차단 작동 중 — Safari·Chrome·Firefox 자동 동기화'
                  : '시스템 차단 꺼짐 — 우측 버튼으로 활성화',
              style: const TextStyle(color: MacColors.ink, fontSize: 12),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _macBusy ? null : _applyMacBlock,
            icon: _macBusy
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(on ? Icons.sync : Icons.power_settings_new, size: 14),
            label: Text(
              on ? '재적용' : '활성화',
              style: const TextStyle(fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: on ? MacColors.secondary : MacColors.ink,
              backgroundColor: on
                  ? MacColors.primaryDim.withValues(alpha: 0.4)
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMacFilterRow() {
    Widget chip(_MacFilter f, String label) {
      final bool sel = _macFilter == f;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _macFilter = f),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: sel ? MacColors.primaryDim : MacColors.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: sel ? MacColors.primary : MacColors.hairline,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: sel ? MacColors.secondary : MacColors.ink,
                fontSize: 11,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: <Widget>[
          chip(_MacFilter.all, '전체'),
          chip(_MacFilter.active, '지금 활성'),
          chip(_MacFilter.inactive, '대기 중'),
          chip(_MacFilter.disabled, '꺼짐'),
        ],
      ),
    );
  }

  List<Map<String, Object?>> _macFilteredSchedules() {
    final List<Map<String, Object?>> list = <Map<String, Object?>>[
      ..._schedules,
    ];
    list.sort(_macComparator);
    return list.where((Map<String, Object?> r) {
      final bool enabled = (r['enabled'] as int) == 1;
      final String id = r['id']! as String;
      final List<Map<String, Object?>> slots =
          _slotsByScheduleId[id] ?? const <Map<String, Object?>>[];
      final bool active = _isActiveNowFromSlots(enabled, slots, r);
      switch (_macFilter) {
        case _MacFilter.all:
          return true;
        case _MacFilter.active:
          return active;
        case _MacFilter.inactive:
          return enabled && !active;
        case _MacFilter.disabled:
          return !enabled;
      }
    }).toList();
  }

  int _macComparator(Map<String, Object?> a, Map<String, Object?> b) {
    switch (_macSort) {
      case _MacSort.name:
        return ((a['name'] as String?) ?? '').toLowerCase().compareTo(
          ((b['name'] as String?) ?? '').toLowerCase(),
        );
      case _MacSort.activeFirst:
        final bool aEn = (a['enabled'] as int) == 1;
        final bool bEn = (b['enabled'] as int) == 1;
        if (aEn != bEn) return aEn ? -1 : 1;
        return 0;
      case _MacSort.created:
        final int aC = (a['created_at'] as int?) ?? 0;
        final int bC = (b['created_at'] as int?) ?? 0;
        return bC.compareTo(aC);
    }
  }

  Widget _buildMacEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.shield_outlined,
              size: 56,
              color: MacColors.mutedInk,
            ),
            const SizedBox(height: 12),
            const Text(
              '아직 차단 스케줄이 없습니다',
              style: TextStyle(
                color: MacColors.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '+ 버튼을 눌러 첫 스케줄을 만들거나, ⋯ 메뉴에서 hosts/Cold Turkey 파일을 임포트하세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MacColors.mutedInk, fontSize: 12),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('스케줄 만들기'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMacRow(Map<String, Object?> row) {
    final String id = row['id']! as String;
    final String name = row['name']! as String;
    final bool enabled = (row['enabled'] as int) == 1;
    final List<Map<String, Object?>> slots =
        _slotsByScheduleId[id] ?? <Map<String, Object?>>[];
    final bool activeNow = _isActiveNowFromSlots(enabled, slots, row);

    final String summary = _summariseSlots(slots, row);
    final String stateLabel = !enabled
        ? '꺼짐'
        : activeNow
        ? '지금 차단 중'
        : '대기 중';
    final Color stripe = !enabled
        ? MacColors.hairline
        : activeNow
        ? MacColors.success
        : MacColors.primary;

    return Material(
      color: MacColors.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(id),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: MacColors.hairline),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: stripe,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(8),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: MacColors.ink,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          stateLabel,
                          style: TextStyle(
                            color: !enabled
                                ? MacColors.mutedInk
                                : activeNow
                                ? MacColors.success
                                : MacColors.secondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: MacColors.mutedInk,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Center(child: _buildMacLockPill(row)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
                  child: Center(
                    child: Switch(
                      value: enabled,
                      onChanged: (bool v) async {
                        if (!v && await _isRowLocked(row)) {
                          _showLockedToast(row);
                          return;
                        }
                        await _db.setScheduleEnabled(id, v);
                        await _reload();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Reads the current lock state of [row] from the DB columns embedded in the
  /// schedule record. When the schedule is in `locked` / `countdown`, the row
  /// is only treated as “locked for toggling off” if some slot overlaps the
  /// rolling urge buffer (~2h from device local [DateTime.now]).
  Future<bool> _isRowLocked(Map<String, Object?> row) async {
    final ({ScheduleLockPhase phase, Duration? remaining, int cooldownMin}) s =
        _phaseFor(row);
    if (s.phase == ScheduleLockPhase.unlocked ||
        s.phase == ScheduleLockPhase.editWindow) {
      return false;
    }
    final String id = row['id']! as String;
    final List<Map<String, Object?>> slots =
        _slotsByScheduleId[id] ?? const <Map<String, Object?>>[];
    return scheduleDataTouchesUrgeWindow(
      slotRows: slots,
      legacyStart: (row['start_minute'] as int?) ?? 0,
      legacyEnd: (row['end_minute'] as int?) ?? 0,
      legacyDaysMask: (row['days_mask'] as int?) ?? 0,
      now: DateTime.now(),
    );
  }

  void _showLockedToast(Map<String, Object?> row) {
    final int penaltyMin = _meta.bypassTimeLockMinutes;
    if (penaltyMin >= 10) {
      final String id = row['id']! as String;
      unawaited(_db.applyBypassTimeLockPenalty(id, penaltyMin));
    }
    final String name = (row['name'] as String?) ?? '이 스케줄';
    final ({ScheduleLockPhase phase, Duration? remaining, int cooldownMin}) s =
        _phaseFor(row);
    final String baseMsg = switch (s.phase) {
      ScheduleLockPhase.countdown =>
        '"$name" 대기 중 — ${_mmss(s.remaining!)} 후 편집창이 열립니다. 단축은 불가합니다.',
      _ => '"$name" 잠금 중 — 끄려면 먼저 "수정 시작"을 누르고 ${s.cooldownMin}분 을 그대로 기다리세요.',
    };
    final String msg = penaltyMin >= 10
        ? '$baseMsg (Time Lock $penaltyMin분 적용)'
        : baseMsg;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        action: SnackBarAction(
          label: '잠금 관리',
          onPressed: () => _showLockSheet(row),
        ),
      ),
    );
  }

  /// Builds the visible lock pill on each schedule row.
  ///   * grey 🔓 unlocked
  ///   * amber 🔒 locked (no timer)
  ///   * amber ⏳ counting down (cooldown)
  ///   * green 🔓 editWindow (5-min write window)
  Widget _buildMacLockPill(Map<String, Object?> row) {
    final ({ScheduleLockPhase phase, Duration? remaining, int cooldownMin}) s =
        _phaseFor(row);
    late Color tone;
    late IconData icon;
    late String label;
    late String tooltip;
    switch (s.phase) {
      case ScheduleLockPhase.editWindow:
        tone = MacColors.success;
        icon = Icons.lock_open;
        label = '편집 ${_mmss(s.remaining!)}';
        tooltip = '편집창 열림 — 끝나면 자동 재잠금';
        break;
      case ScheduleLockPhase.countdown:
        tone = MacColors.warning;
        icon = Icons.hourglass_top;
        label = '대기 ${_mmss(s.remaining!)}';
        tooltip = '대기 중 — 단축 불가';
        break;
      case ScheduleLockPhase.locked:
        tone = MacColors.warning;
        icon = Icons.lock;
        label = '잠금 ${s.cooldownMin}분';
        tooltip = '잠금 — 풀려면 ${s.cooldownMin}분 을 기다려야 합니다';
        break;
      case ScheduleLockPhase.unlocked:
        tone = MacColors.mutedInk;
        icon = Icons.lock_open;
        label = '잠금 꺼짐';
        tooltip = '누르면 이 스케줄에 잠금 시간을 박을 수 있어요';
        break;
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _showLockSheet(row),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: tone.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 13, color: tone),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: tone,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Bottom-sheet-style dialog with three modes:
  ///   * Currently unlocked → "이 스케줄 잠그기" button.
  ///   * Locked, no grace → duration presets (1·5·15·30·60분) + 사용자 지정.
  ///   * In grace → live countdown + "지금 잠그기".
  Future<void> _showLockSheet(Map<String, Object?> row) async {
    final String id = row['id']! as String;
    final String name = (row['name'] as String?) ?? '스케줄';
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) =>
          _ScheduleLockSheet(scheduleId: id, scheduleName: name, db: _db),
    );
    await _reload();
  }
}

enum _MacFilter { all, active, inactive, disabled }

enum _MacSort { created, name, activeFirst }

enum _MacBtnTone { primary, neutral }

class _MacToolbarButton extends StatelessWidget {
  const _MacToolbarButton({
    required this.icon,
    required this.tone,
    required this.onTap,
  });
  final IconData icon;
  final _MacBtnTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool isPrimary = tone == _MacBtnTone.primary;
    return Material(
      color: isPrimary ? MacColors.primary : MacColors.surfaceAlt,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isPrimary ? MacColors.primary : MacColors.hairline,
            ),
          ),
          child: Icon(
            icon,
            size: 16,
            color: isPrimary ? MacColors.ink : MacColors.ink,
          ),
        ),
      ),
    );
  }
}

/// Per-schedule lock controller dialog. Pre-commitment design (v8).
///
/// Four phases share one surface:
///   * **Unlocked** — cooldown picker (the pre-commit) + "잠그기" button.
///     The cooldown is the only choice the user ever makes about timing —
///     and it is made *before* the lock activates, when the user is calm.
///   * **Locked, no countdown** — single "수정 시작 (N분 대기)" button.
///     No duration picker — the duration is locked in.
///   * **Countdown** — large progress bar + remaining time. Cancellable but
///     not shortenable.
///   * **Edit window** — 5-minute write window indicator + "다시 잠그기".
class _ScheduleLockSheet extends StatefulWidget {
  const _ScheduleLockSheet({
    required this.scheduleId,
    required this.scheduleName,
    required this.db,
  });
  final String scheduleId;
  final String scheduleName;
  final LocalDatabase db;

  @override
  State<_ScheduleLockSheet> createState() => _ScheduleLockSheetState();
}

class _ScheduleLockSheetState extends State<_ScheduleLockSheet> {
  ScheduleLockPhase _phase = ScheduleLockPhase.unlocked;
  DateTime? _transitionAt;
  int _cooldownMin = 30;
  bool _busy = false;
  Timer? _tick;

  /// Options for the cooldown — pre-commit. Minimum 30 minutes (no 5-min loophole).
  static const List<int> _cooldownOptions = <int>[30, 60, 120, 240, 720, 1440];

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_phase == ScheduleLockPhase.countdown ||
          _phase == ScheduleLockPhase.editWindow) {
        _load();
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final Map<String, Object?>? row = await widget.db.scheduleById(
      widget.scheduleId,
    );
    if (!mounted || row == null) return;
    final ({ScheduleLockPhase phase, DateTime? transitionAt}) p = await widget
        .db
        .scheduleLockPhase(widget.scheduleId);
    setState(() {
      _phase = p.phase;
      _transitionAt = p.transitionAt;
      _cooldownMin = (row['lock_cooldown_minutes'] as int?) ?? 30;
    });
  }

  Future<void> _enableLock() async {
    setState(() => _busy = true);
    await widget.db.setScheduleLocked(widget.scheduleId, true);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _setCooldown(int minutes) async {
    setState(() => _busy = true);
    final bool ok = await widget.db.setScheduleCooldownMinutes(
      widget.scheduleId,
      minutes,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('잠금 중에는 대기시간을 바꿀 수 없어요. 의도된 제약입니다.')),
      );
    }
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _startCountdown() async {
    setState(() => _busy = true);
    await widget.db.startScheduleUnlockCountdown(widget.scheduleId);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _cancel() async {
    setState(() => _busy = true);
    await widget.db.cancelScheduleUnlock(widget.scheduleId);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: <Widget>[
          Icon(_phaseIcon(), color: _phaseTone()),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '"${widget.scheduleName}" 잠금',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _statusLine(),
            const SizedBox(height: 14),
            _phaseBody(),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }

  IconData _phaseIcon() => switch (_phase) {
    ScheduleLockPhase.unlocked => Icons.lock_outline,
    ScheduleLockPhase.locked => Icons.lock,
    ScheduleLockPhase.countdown => Icons.hourglass_top,
    ScheduleLockPhase.editWindow => Icons.lock_open,
  };

  Color _phaseTone() => switch (_phase) {
    ScheduleLockPhase.unlocked => MacColors.mutedInk,
    ScheduleLockPhase.locked => MacColors.warning,
    ScheduleLockPhase.countdown => MacColors.warning,
    ScheduleLockPhase.editWindow => MacColors.success,
  };

  Widget _statusLine() {
    String text;
    final Color color = _phaseTone();
    switch (_phase) {
      case ScheduleLockPhase.unlocked:
        text =
            '잠금 OFF — 잠그면 미래의 본인은 미리 박은 $_cooldownMin분 을 그대로 기다려야 합니다. '
            '"개에게 고기를 보여주고 안 먹게 하는" 충동을 차단합니다.';
        break;
      case ScheduleLockPhase.locked:
        text =
            '잠금 ON · 대기 $_cooldownMin분 — 수정/삭제하려면 "수정 시작"을 누르고 그대로 기다리세요. '
            '대기시간은 이미 박혀 있어서 줄일 수 없습니다.';
        break;
      case ScheduleLockPhase.countdown:
        final Duration r = _transitionAt!.difference(DateTime.now());
        text =
            '대기 중 · ${_SchedulesScreenState._mmss(r)} 후 5분짜리 편집창이 열립니다. 단축은 불가합니다.';
        break;
      case ScheduleLockPhase.editWindow:
        final Duration r = _transitionAt!.difference(DateTime.now());
        text =
            '편집창 · ${_SchedulesScreenState._mmss(r)} 남음. '
            '지금 사이트·키워드·앱을 자유롭게 수정/삭제할 수 있어요. 끝나면 자동으로 다시 잠깁니다.';
        break;
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.40)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, height: 1.45),
      ),
    );
  }

  Widget _phaseBody() {
    switch (_phase) {
      case ScheduleLockPhase.unlocked:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '미리 박을 대기시간 (잠그면 이 숫자는 동결됩니다)',
              style: TextStyle(color: MacColors.ink, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _cooldownOptions
                  .map(
                    (int m) => _SheetCooldownChip(
                      label: _SchedulesScreenState._cooldownLabel(m),
                      selected: _cooldownMin == m,
                      enabled: !_busy,
                      onTap: () => _setCooldown(m),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _enableLock,
              icon: const Icon(Icons.lock),
              label: Text('이 스케줄 잠그기 (대기 $_cooldownMin분)'),
              style: FilledButton.styleFrom(
                backgroundColor: MacColors.warning,
                foregroundColor: MacColors.secondaryInk,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '※ 잠근 뒤에는 이 시간을 줄일 수 없습니다 — 의도된 마찰입니다.',
              style: TextStyle(
                color: MacColors.mutedInk,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        );
      case ScheduleLockPhase.locked:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _busy ? null : _startCountdown,
              icon: const Icon(Icons.hourglass_top),
              label: Text('수정 시작 ($_cooldownMin분 대기)'),
            ),
            const SizedBox(height: 6),
            Text(
              '시작하면 $_cooldownMin분 카운트다운이 시작됩니다. 시간이 흐르는 동안엔 수정/삭제 모두 막혀 있고, '
              '끝나면 5분짜리 편집창이 열립니다.',
              style: const TextStyle(
                color: MacColors.mutedInk,
                fontSize: 11,
                height: 1.4,
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: _LockedCooldownDisplay(),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _cooldownOptions
                    .map(
                      (int m) => _SheetCooldownChip(
                        label: _SchedulesScreenState._cooldownLabel(m),
                        selected: _cooldownMin == m,
                        enabled: false,
                        onTap: () {},
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        );
      case ScheduleLockPhase.countdown:
        final Duration r = _transitionAt!.difference(DateTime.now());
        final double progress =
            1 - (r.inMilliseconds / (_cooldownMin * 60 * 1000)).clamp(0.0, 1.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: MacColors.warning.withValues(alpha: 0.2),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  MacColors.warning,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '${_SchedulesScreenState._mmss(r)} 남음 · 단축 불가',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MacColors.warning,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _cancel,
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('취소하고 다시 잠그기'),
            ),
            const SizedBox(height: 6),
            Text(
              '※ 취소해도 시간은 단축되지 않습니다 — 다시 시작하면 $_cooldownMin분부터 다시.',
              style: const TextStyle(
                color: MacColors.mutedInk,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        );
      case ScheduleLockPhase.editWindow:
        final Duration r = _transitionAt!.difference(DateTime.now());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '편집창 ${_SchedulesScreenState._mmss(r)} 남음',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MacColors.success,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _cancel,
              icon: const Icon(Icons.lock),
              label: const Text('지금 다시 잠그기'),
              style: FilledButton.styleFrom(
                backgroundColor: MacColors.warning,
                foregroundColor: MacColors.secondaryInk,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '편집창이 끝나면 자동으로 다시 잠깁니다. 다음에도 같은 대기시간이 필요합니다.',
              style: TextStyle(
                color: MacColors.mutedInk,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        );
    }
  }
}

/// Helper widget shown in the locked-no-countdown phase to label the frozen
/// cooldown choices below it.
class _LockedCooldownDisplay extends StatelessWidget {
  const _LockedCooldownDisplay();
  @override
  Widget build(BuildContext context) {
    return Row(
      children: const <Widget>[
        Icon(Icons.lock, size: 14, color: MacColors.mutedInk),
        SizedBox(width: 6),
        Text(
          '대기시간 · 잠금 중에는 변경 불가',
          style: TextStyle(
            color: MacColors.mutedInk,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Sheet-flavoured cooldown chip. Mirrors the edit-screen `_CooldownChip`
/// but uses MacColors directly since the sheet is Mac-only chrome.
class _SheetCooldownChip extends StatelessWidget {
  const _SheetCooldownChip({
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
    final Color accent = MacColors.primary;
    final Color fg = !enabled
        ? (selected ? accent : MacColors.mutedInk)
        : (selected ? Colors.white : MacColors.secondary);
    final Color bg = selected ? accent : MacColors.primaryDim;
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

/// Small inline badge shown at the bottom of a schedule card.
/// Shows: trigger count, estimated saved time, and today's active foreground usage.
class _ScheduleStatsBadge extends StatefulWidget {
  const _ScheduleStatsBadge({required this.scheduleId});
  final String scheduleId;

  @override
  State<_ScheduleStatsBadge> createState() => _ScheduleStatsBadgeState();
}

class _ScheduleStatsBadgeState extends State<_ScheduleStatsBadge> {
  ScheduleBlockStats _stats = ScheduleBlockStats.empty;
  int _activeSeconds = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ScheduleBlockStats s = await ScheduleBlockStatsService.instance
        .statsFor(widget.scheduleId);
    final int active = await ScheduleBlockStatsService.instance
        .activeUsageSecondsToday(widget.scheduleId);
    if (!mounted) return;
    setState(() {
      _stats = s;
      _activeSeconds = active;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_stats.triggerCount == 0 && _activeSeconds == 0) {
      return const SizedBox.shrink();
    }
    final List<Widget> chips = <Widget>[];
    if (_stats.triggerCount > 0) {
      chips.add(
        _chip(Icons.block, '?? ${_stats.triggerCount}?', AppColors.warning),
      );
      chips.add(
        _chip(
          Icons.timer_outlined,
          '?? ${ScheduleBlockStatsService.formatDuration(_stats.estimatedSavedSeconds)}',
          AppColors.success,
        ),
      );
    }
    if (_activeSeconds > 0) {
      chips.add(
        _chip(
          Icons.visibility_outlined,
          '?? ??? ${ScheduleBlockStatsService.formatDuration(_activeSeconds)}',
          AppColors.accent,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 6, runSpacing: 4, children: chips),
    );
  }

  static Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
