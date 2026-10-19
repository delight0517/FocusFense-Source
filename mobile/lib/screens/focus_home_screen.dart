import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/schedule_domain_presets.dart';
import '../localization/app_i18n.dart';
import '../models/rules_meta.dart';
import '../models/scheduled_rule_removal.dart';
import '../models/unified_rule_kind.dart';
import '../services/locale_controller.dart';
import '../services/local_database.dart';
import '../services/lock_policy_service.dart';
import '../services/mac_system_block_service.dart';
import '../services/quick_block_controller.dart';
import '../services/quick_block_service.dart';
import '../services/delayed_rule_removal_service.dart';
import '../services/smart_rule_apply_service.dart';
import '../services/universal_browser_block_service.dart';
import '../theme/app_colors.dart';
import '../widgets/smart_rule_input_bar.dart';
import '../widgets/unified_rule_kind_chip.dart';
import 'how_it_works_screen.dart';
import 'one_tap_block_screen.dart';
import 'simulation_lab_screen.dart';
import 'stats_screen.dart';
import '../widgets/blocking_ecosystem_status_screen.dart';
import '../widgets/blocking_ecosystem_status_strip.dart';
import '../widgets/browser_install_safety_banners.dart';

class FocusHomeScreen extends StatefulWidget {
  const FocusHomeScreen({super.key});

  @override
  State<FocusHomeScreen> createState() => _FocusHomeScreenState();
}

class _FocusHomeScreenState extends State<FocusHomeScreen> with SingleTickerProviderStateMixin {
  final LocalDatabase _db = LocalDatabase.instance;
  final LockPolicyService _lockPolicy = LockPolicyService.instance;
  final TextEditingController _quickBlockCtrl = TextEditingController();
  final PageController _guideController = PageController();
  RulesMeta _meta = RulesMeta.defaults;
  late final AnimationController _heroController;
  int _guidePage = 0;
  bool _macActive = false;
  bool _macBusy = false;
  List<Map<String, Object?>> _globalDomains = <Map<String, Object?>>[];
  List<Map<String, Object?>> _globalKeywords = <Map<String, Object?>>[];
  Map<String, ScheduledRuleRemoval> _pendingRemovals =
      <String, ScheduledRuleRemoval>{};
  bool _quickAddBusy = false;
  String _quickBlockQuery = '';
  static const int _kMaxDomainsShown = 14;
  static const int _kMaxKeywordsShown = 14;

  @override
  void initState() {
    super.initState();
    _quickBlockCtrl.addListener(_onQuickBlockQueryChanged);
    _heroController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2100),
    )..repeat(reverse: true);
    _refreshMeta();
    _refreshMacStatus();
    unawaited(_loadGlobalQuickBlocks());
    QuickBlockController.instance.addListener(_onQuickBlockChanged);
    DelayedRuleRemovalService.instance.addListener(_onPendingRemovalChanged);
  }

  void _onQuickBlockQueryChanged() {
    final String next = _quickBlockCtrl.text;
    if (next == _quickBlockQuery || !mounted) return;
    setState(() => _quickBlockQuery = next);
  }

  void _onQuickBlockChanged() {
    unawaited(_loadGlobalQuickBlocks());
  }

  void _onPendingRemovalChanged() {
    unawaited(_loadGlobalQuickBlocks());
  }

  Future<void> _loadGlobalQuickBlocks() async {
    final List<Map<String, Object?>> d = await _db.domainsForSchedule(null);
    final List<Map<String, Object?>> k = await _db.keywordsForSchedule(null);
    final List<ScheduledRuleRemoval> pending =
        await DelayedRuleRemovalService.instance.loadPending();
    if (!mounted) return;
    setState(() {
      _globalDomains = d;
      _globalKeywords = k;
      _pendingRemovals = <String, ScheduledRuleRemoval>{
        for (final ScheduledRuleRemoval item in pending) item.key: item,
      };
    });
  }

  bool get _policyLocked => _lockPolicy.isLockedByPolicy(_meta);

  Future<void> _removeGlobalDomain(String id, String host) async {
    final DelayedRuleRemovalService service =
        DelayedRuleRemovalService.instance;
    await service.loadPending();
    final ScheduledRuleRemoval? pending =
        service.pendingFor(ScheduledRuleKind.domain, id);
    if (pending != null) {
      await service.cancelRemoval(
        ruleKind: ScheduledRuleKind.domain,
        ruleId: id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“$host” 제거 예약을 취소했습니다.')),
      );
      return;
    }
    if (_policyLocked) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('잠금 모드에서는 삭제할 수 없습니다.')),
      );
      return;
    }
    await service.scheduleRemoval(
      ruleKind: ScheduledRuleKind.domain,
      ruleId: id,
      label: host,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('“$host” 차단을 3시간 뒤 제거하도록 예약했습니다.'),
        action: SnackBarAction(
          label: '취소',
          onPressed: () => unawaited(
            service.cancelRemoval(
              ruleKind: ScheduledRuleKind.domain,
              ruleId: id,
            ).then((_) => _loadGlobalQuickBlocks()),
          ),
        ),
      ),
    );
  }

  Future<void> _removeGlobalKeyword(String id, String pattern) async {
    final DelayedRuleRemovalService service =
        DelayedRuleRemovalService.instance;
    await service.loadPending();
    final ScheduledRuleRemoval? pending =
        service.pendingFor(ScheduledRuleKind.keyword, id);
    if (pending != null) {
      await service.cancelRemoval(
        ruleKind: ScheduledRuleKind.keyword,
        ruleId: id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“$pattern” 제거 예약을 취소했습니다.')),
      );
      return;
    }
    if (_policyLocked) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('잠금 모드에서는 삭제할 수 없습니다.')),
      );
      return;
    }
    await service.scheduleRemoval(
      ruleKind: ScheduledRuleKind.keyword,
      ruleId: id,
      label: pattern,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('“$pattern” 차단을 3시간 뒤 제거하도록 예약했습니다.'),
        action: SnackBarAction(
          label: '취소',
          onPressed: () => unawaited(
            service.cancelRemoval(
              ruleKind: ScheduledRuleKind.keyword,
              ruleId: id,
            ).then((_) => _loadGlobalQuickBlocks()),
          ),
        ),
      ),
    );
  }

  Future<void> _refreshMacStatus() async {
    if (!Platform.isMacOS) return;
    final bool active = await MacSystemBlockService.instance.isActive();
    if (mounted) setState(() => _macActive = active);
  }

  Future<void> _macToggle({required bool turnOn}) async {
    setState(() => _macBusy = true);
    final MacBlockResult r = turnOn
        ? await MacSystemBlockService.instance.activate()
        : await MacSystemBlockService.instance.deactivate();
    final bool active = await MacSystemBlockService.instance.isActive();
    if (!mounted) return;
    setState(() {
      _macBusy = false;
      _macActive = active;
    });
    final String msg;
    switch (r.status) {
      case MacBlockStatus.success:
        msg = turnOn
            ? 'Mac 시스템 차단 적용 — Safari·Chrome·Firefox·앱 전반에 반영됨'
            : 'Mac 시스템 차단 해제됨';
        break;
      case MacBlockStatus.cancelled:
        msg = '관리자 비밀번호 입력 취소';
        break;
      case MacBlockStatus.unsupported:
        msg = '이 기능은 macOS 전용입니다.';
        break;
      case MacBlockStatus.failure:
        msg = '실패: ${r.message ?? "원인 미상"}';
        break;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    QuickBlockController.instance.removeListener(_onQuickBlockChanged);
    DelayedRuleRemovalService.instance
        .removeListener(_onPendingRemovalChanged);
    _quickBlockCtrl.removeListener(_onQuickBlockQueryChanged);
    _quickBlockCtrl.dispose();
    _guideController.dispose();
    _heroController.dispose();
    super.dispose();
  }

  Future<void> _refreshMeta() async {
    final RulesMeta m = await _db.rulesMeta();
    if (mounted) setState(() => _meta = m);
  }

  Future<void> _setFocus(bool value) async {
    final bool lockedNow = _lockPolicy.isLockedByPolicy(_meta);
    if (lockedNow && !value) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('잠금 상태에서는 차단을 끌 수 없습니다.')),
      );
      return;
    }
    await _db.saveRulesMeta(_meta.copyWith(focusEnabled: value));
    setState(() => _meta = _meta.copyWith(focusEnabled: value));
  }

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(Object())}';
  static const List<String> _suggestedKeywords = <String>['apple', 'celebrity', 'casino', 'shopping'];

  Future<void> _quickAddBlock() async {
    final String raw = _quickBlockCtrl.text.trim();
    if (raw.isEmpty || _quickAddBusy) return;
    if (!mounted) return;

    final ScheduleDomainPreset? preset = exactQuickBlockPreset(raw);
    if (preset != null) {
      await _applyQuickPreset(preset);
      return;
    }

    setState(() => _quickAddBusy = true);

    final Set<String> existingDomains = _globalDomains
        .map((Map<String, Object?> r) => (r['host']! as String).toLowerCase())
        .toSet();
    final Set<String> existingKeywords = _globalKeywords
        .map((Map<String, Object?> r) =>
            (r['pattern']! as String).toLowerCase())
        .toSet();

    SmartRuleApplyResult result;
    try {
      result = await SmartRuleApplyService.instance.applyLine(
        context: context,
        rawLine: raw,
        existingDomains: existingDomains,
        existingKeywords: existingKeywords,
        newId: _newId,
      );
    } finally {
      if (mounted) setState(() => _quickAddBusy = false);
    }

    if (!mounted) return;
    if (result.cancelled) return;

    _quickBlockCtrl.clear();
    unawaited(_loadGlobalQuickBlocks());

    if (Platform.isWindows &&
        result.ok &&
        (result.kind == UnifiedRuleKind.videoURL ||
            result.kind == UnifiedRuleKind.channelURL) &&
        result.keywordsAdded > 0) {
      UniversalBrowserBlockService.instance.scheduleSync(
        reason: 'quick_block_youtube',
      );
    }

    final String msg = result.error ?? result.summaryMessage();
    final StringBuffer body = StringBuffer(msg);
    if (result.hostTruncationNote != null) {
      body.write('\n${result.hostTruncationNote}');
    }
    if (result.apexEnforceMessage != null &&
        result.apexEnforceMessage!.trim().isNotEmpty) {
      body.write('\n${result.apexEnforceMessage}');
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(body.toString()),
        duration: Duration(seconds: result.apexEnforceMessage != null ? 7 : 4),
      ),
    );
  }

  Future<void> _applyQuickPreset(ScheduleDomainPreset preset) async {
    if (_quickAddBusy) return;
    setState(() => _quickAddBusy = true);
    int added = 0;
    Object? error;
    try {
      added = await QuickBlockService.instance.applySchedulePreset(preset);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _quickAddBusy = false);
    }
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('프리셋 적용 실패: $error')),
      );
      return;
    }
    _quickBlockCtrl.clear();
    unawaited(_loadGlobalQuickBlocks());
    final int skipped = (preset.itemCount - added).clamp(0, preset.itemCount);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '“${preset.name}” 차단 추가 완료: $added개'
          '${skipped > 0 ? ' · 이미 추가된 항목 $skipped개 건너뜀' : ''}',
        ),
        duration: Duration(seconds: added > 50 ? 6 : 4),
      ),
    );
  }

  Widget _buildPresetSuggestions() {
    final List<ScheduleDomainPreset> matches =
        matchQuickBlockPresets(_quickBlockQuery);
    if (matches.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: matches.take(4).map((ScheduleDomainPreset preset) {
          return ActionChip(
            avatar: Icon(preset.icon, size: 17),
            label: Text('${preset.name} 프리셋 · ${preset.itemCount}개 추가'),
            onPressed: _quickAddBusy ? null : () => _applyQuickPreset(preset),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildWindowsHome(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: <Widget>[
        Text(
          '홈',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.ink,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          '이 앱이 하는 일: 브라우저 URL 차단 · 확장 설치 · 미보호 브라우저 종료 · 사이트/게임 퀵 블록',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
                height: 1.45,
                fontSize: 14,
              ),
        ),
        const SizedBox(height: 16),
        const BlockingEcosystemHomeCard(),
        const SizedBox(height: 12),
        const BrowserSafetyActionRow(),
        const SizedBox(height: 12),
        _WindowsActionCard(
          icon: Icons.bolt,
          title: '원탭 차단 적용',
          subtitle: 'Chrome · Edge · Firefox 정책·확장을 한 번에 맞춥니다.',
          onTap: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const OneTapBlockScreen(),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        _WindowsActionCard(
          icon: Icons.radar,
          title: '브라우저 차단 현황 보기',
          subtitle: '설치된 브라우저 · 플러그인 준비 여부 · kill guard 상태',
          onTap: () => openBlockingEcosystemStatusScreen(context),
        ),
        const SizedBox(height: 20),
        Text(
          '빠른 차단',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.ink,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'URL · 도메인 · YouTube 채널/영상 · 키워드를 한 칸에 넣으면 자동 분류됩니다.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.4,
              ),
        ),
        const SizedBox(height: 10),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _suggestedKeywords
                      .map(
                        (String word) => ActionChip(
                          label: Text(word),
                          avatar: const Icon(Icons.add, size: 16),
                          onPressed: _quickAddBusy
                              ? null
                              : () {
                                  _quickBlockCtrl.text = word;
                                  _quickAddBlock();
                                },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 10),
                SmartRuleInputBar(
                  controller: _quickBlockCtrl,
                  onAdd: _quickAddBlock,
                  enabled: !_quickAddBusy,
                  addLabel: _quickAddBusy ? '적용 중…' : '추가',
                ),
                _buildPresetSuggestions(),
                if (_globalDomains.isNotEmpty ||
                    _globalKeywords.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 14),
                  Divider(height: 1, color: Colors.grey.shade200),
                  const SizedBox(height: 10),
                  Text(
                    '항상 적용 중인 규칙',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  ..._globalDomains.take(_kMaxDomainsShown).map(
                        (Map<String, Object?> row) => _QuickBlockRow(
                          label: row['host'] as String? ?? '',
                          isDomainRow: true,
                          removalScheduled: _pendingRemovals.containsKey(
                            'domain:${row['id']}',
                          ),
                          locked: _policyLocked,
                          onRemove: () => _removeGlobalDomain(
                            row['id'] as String,
                            row['host'] as String? ?? '',
                          ),
                        ),
                      ),
                  ..._globalKeywords.take(_kMaxKeywordsShown).map(
                        (Map<String, Object?> row) => _QuickBlockRow(
                          label: row['pattern'] as String? ?? '',
                          isDomainRow: false,
                          removalScheduled: _pendingRemovals.containsKey(
                            'keyword:${row['id']}',
                          ),
                          locked: _policyLocked,
                          onRemove: () => _removeGlobalKeyword(
                            row['id'] as String,
                            row['pattern'] as String? ?? '',
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const HowItWorksScreen(),
              ),
            );
          },
          icon: const Icon(Icons.help_outline, size: 18),
          label: const Text('차단이 어떻게 동작하는지 보기'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return _buildWindowsHome(context);
    }
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        children: <Widget>[
          Text(
            '홈',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            Platform.isMacOS
                ? '이 Mac 전체를 시스템 DNS 단에서 차단합니다. Safari, Chrome, Firefox, 그리고 모든 앱에 동시에 적용됩니다.'
                : 'DNS·확장·앱 설정에 따라 도메인과 화면 요소를 줄입니다.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 8),
          Text(
            '화면 맨 아래(또는 왼쪽 사이드바)의 퀵 블록에서 게임·영상 묶음을 한 번에 켤 수 있어요. '
            '스케줄 목록과는 별개로 전역 사이트 규칙만 추가합니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 10),
          const _CoreScopeBanner(),
          if (Platform.isMacOS) ...<Widget>[
            const SizedBox(height: 12),
            const BlockingEcosystemHomeCard(),
            const SizedBox(height: 12),
            _buildMacHeroCard(context),
          ],
          const SizedBox(height: 16),
          _OnboardingSlides(
            controller: _guideController,
            page: _guidePage,
            onPageChanged: (int idx) => setState(() => _guidePage = idx),
            windowsUi: false,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => const HowItWorksScreen(),
                ),
              );
            },
            icon: const Icon(Icons.slideshow),
            label: const Text('Safari에서 차단 결과 바로 확인'),
          ),
          const SizedBox(height: 12),
          _VisualHeroCard(animation: _heroController),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _flowItem(
                          context,
                          Icons.language,
                          'Safari에서 보기',
                        ),
                      ),
                      const Icon(Icons.arrow_forward, color: AppColors.muted),
                      Expanded(child: _flowItem(context, Icons.block, '규칙으로 차단')),
                      const Icon(Icons.arrow_forward, color: AppColors.muted),
                      Expanded(child: _flowItem(context, Icons.check_circle, '깨끗한 화면')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      const Chip(
                          avatar: Icon(Icons.check_circle, size: 16),
                          label: Text('Safari에서 작동')),
                      const Chip(
                          avatar: Icon(Icons.cancel, size: 16),
                          label: Text('전체 VPN 제어 아님')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    Platform.isWindows ? '빠른 차단' : 'Safari 빠른 차단',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'URL / 도메인 / YouTube 채널·영상 / 키워드 — 한 칸에 넣으면 종류를 자동으로 고릅니다.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _suggestedKeywords
                        .map(
                          (String word) => ActionChip(
                            label: Text(word),
                            avatar: const Icon(Icons.add, size: 16),
                            onPressed: _quickAddBusy
                                ? null
                                : () {
                                    _quickBlockCtrl.text = word;
                                    _quickAddBlock();
                                  },
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 10),
                  SmartRuleInputBar(
                    controller: _quickBlockCtrl,
                    onAdd: _quickAddBlock,
                    enabled: !_quickAddBusy,
                    addLabel: _quickAddBusy ? '적용 중…' : '추가',
                  ),
                  _buildPresetSuggestions(),
                  if (_globalDomains.isNotEmpty || _globalKeywords.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    Divider(height: 1, color: AppColors.muted.withValues(alpha: 0.25)),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '여기서 추가한 차단 (항상 적용)',
                            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                  color: AppColors.ink,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                        if (_policyLocked)
                          Text(
                            '잠금 중 · 삭제 불가',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AppColors.muted),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '각 줄 오른쪽의 작은 버튼으로 목록에서 뺄 수 있어요. (스케줄에 묶인 규칙은 「스케줄 + 규칙」에서 지웁니다.)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
                    ),
                    const SizedBox(height: 8),
                    ..._globalDomains.take(_kMaxDomainsShown).map((Map<String, Object?> r) {
                      final String id = r['id']! as String;
                      final String host = r['host']! as String;
                      return _QuickBlockRow(
                        label: host,
                        isDomainRow: true,
                        removalScheduled: _pendingRemovals.containsKey(
                          'domain:$id',
                        ),
                        locked: _policyLocked,
                        onRemove: () => _removeGlobalDomain(id, host),
                      );
                    }),
                    ..._globalKeywords.take(_kMaxKeywordsShown).map((Map<String, Object?> r) {
                      final String id = r['id']! as String;
                      final String pat = r['pattern']! as String;
                      return _QuickBlockRow(
                        label: pat,
                        isDomainRow: false,
                        removalScheduled: _pendingRemovals.containsKey(
                          'keyword:$id',
                        ),
                        locked: _policyLocked,
                        onRemove: () => _removeGlobalKeyword(id, pat),
                      );
                    }),
                    if (_globalDomains.length > _kMaxDomainsShown ||
                        _globalKeywords.length > _kMaxKeywordsShown)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '긴 목록은 일부만 표시합니다. 전체는 「스케줄 + 규칙」 화면에서 확인하세요.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('잠금 모드 켜기'),
            subtitle: Text(
              '켜면 차단 강도가 높아집니다. 필수는 아니며, 필요할 때만 켜도 됩니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
            ),
            value: _meta.focusEnabled,
            onChanged: _setFocus,
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    Platform.isWindows ? 'Windows에서 시작 (3단계)' : 'Safari 3단계 시작',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    Platform.isWindows
                        ? '1) 차단 단어·사이트 추가\n'
                            '2) 잠금 모드 켜기 (선택)\n'
                            '3) 스케줄·DNS·앱 차단 테스트'
                        : '1) Safari 차단 단어 추가\n'
                            '2) 잠금 모드 켜기 (선택)\n'
                            '3) Safari 테스트 실행',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.tonal(
                        onPressed: () => context.go('/schedules'),
                        child: const Text('스케줄 + 규칙'),
                      ),
                      FilledButton.tonal(
                        onPressed: () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => const StatsScreen(),
                            ),
                          );
                        },
                        child: const Text('테스트 실행'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => const SimulationLabScreen(),
                ),
              );
            },
            icon: const Icon(Icons.science_outlined),
            label: const Text('연습장 열기 (시뮬레이션)'),
          ),
        ],
      ),
    );
  }

  Widget _flowItem(BuildContext context, IconData icon, String label) {
    return Column(
      children: <Widget>[
        CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.accent.withValues(alpha: 0.15),
          child: Icon(icon, size: 18, color: AppColors.ink),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AppColors.ink),
        ),
      ],
    );
  }

  Widget _buildMacHeroCard(BuildContext context) {
    final Locale locale = LocaleController.instance.locale;
    final ThemeData theme = Theme.of(context);
    final bool locked = _lockPolicy.isLockedByPolicy(_meta);
    final bool on = _macActive;

    final Color bg = on
        ? AppColors.success.withValues(alpha: 0.10)
        : AppColors.accent.withValues(alpha: 0.10);
    final Color stripe = on ? AppColors.success : AppColors.accent;
    final IconData icon = on ? Icons.verified_user : Icons.shield_outlined;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: stripe.withValues(alpha: 0.40), width: 1.2),
        borderRadius: BorderRadius.circular(14),
      ),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: stripe, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppI18n.t(locale, 'mac_hero_title'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: stripe.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    on ? 'ON' : 'OFF',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: stripe,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              on
                  ? AppI18n.t(locale, 'mac_hero_on')
                  : AppI18n.t(locale, 'mac_hero_off'),
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _macBusy ? null : () => _macToggle(turnOn: true),
                    icon: const Icon(Icons.shield_moon_outlined),
                    label: Text(on
                        ? AppI18n.t(locale, 'mac_hero_action_on')
                        : AppI18n.t(locale, 'mac_hero_action_off')),
                  ),
                ),
                if (on) ...<Widget>[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: (_macBusy || locked)
                          ? null
                          : () => _macToggle(turnOn: false),
                      icon: const Icon(Icons.lock_open_outlined),
                      label: Text(locked
                          ? AppI18n.t(locale, 'mac_hero_locked')
                          : AppI18n.t(locale, 'mac_hero_action_disable')),
                    ),
                  ),
                ],
              ],
            ),
            if (_macBusy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(minHeight: 3),
              ),
          ],
        ),
      ),
    );
  }
}

/// One row in the home "quick block" list — muted close icon, no red.
class _QuickBlockRow extends StatelessWidget {
  const _QuickBlockRow({
    required this.label,
    required this.isDomainRow,
    required this.removalScheduled,
    required this.locked,
    required this.onRemove,
  });

  final String label;
  final bool isDomainRow;
  final bool removalScheduled;
  final bool locked;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          UnifiedRuleKindChip(value: label, isDomainRow: isDomainRow),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.ink),
                  overflow: TextOverflow.ellipsis,
                ),
                if (removalScheduled)
                  Text(
                    '제거 예약됨 · 차단은 예약 시각까지 유지',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.orange.shade800,
                        ),
                  ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            tooltip: removalScheduled
                ? '제거 예약 취소'
                : locked
                    ? '잠금 중'
                    : '3시간 뒤 제거 예약',
            onPressed: locked && !removalScheduled ? null : onRemove,
            icon: Icon(
              removalScheduled ? Icons.undo : Icons.schedule,
              size: 17,
              color: removalScheduled
                  ? Colors.orange.shade800
                  : locked
                  ? AppColors.muted.withValues(alpha: 0.35)
                  : AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _VisualHeroCard extends StatelessWidget {
  const _VisualHeroCard({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('한눈에 보기', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '키워드를 넣으면, 원치 않는 이미지가 점점 X 처리되어 사라집니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
            ),
            const SizedBox(height: 10),
            AnimatedBuilder(
              animation: animation,
              builder: (BuildContext context, Widget? child) {
                final double t = animation.value;
                return Column(
                  children: <Widget>[
                    _searchBarPreview(context),
                    const SizedBox(height: 8),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: 9,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 1,
                      ),
                      itemBuilder: (BuildContext context, int index) {
                        final bool blocked = _isBlocked(index, t);
                        return _imageCell(blocked, t);
                      },
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  bool _isBlocked(int index, double t) {
    const List<int> wave1 = <int>[1, 4];
    const List<int> wave2 = <int>[0, 2, 5];
    const List<int> wave3 = <int>[3, 6, 7];
    if (t < 0.33) return wave1.contains(index);
    if (t < 0.66) return wave1.contains(index) || wave2.contains(index);
    return wave1.contains(index) || wave2.contains(index) || wave3.contains(index);
  }

  Widget _searchBarPreview(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F6FD),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.search, size: 18, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'keyword: apple',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ),
          const Icon(Icons.block, size: 17, color: AppColors.danger),
        ],
      ),
    );
  }

  Widget _imageCell(bool blocked, double t) {
    final double pulse = 0.7 + (math.sin(t * math.pi * 2) + 1) * 0.15;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: blocked ? const Color(0xFFFFEEF0) : const Color(0xFFDFF5F2),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          const Icon(Icons.image_outlined, color: AppColors.ink),
          if (blocked)
            Transform.scale(
              scale: pulse,
              child: Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 18, color: AppColors.danger),
              ),
            ),
        ],
      ),
    );
  }
}

class _WindowsActionCard extends StatelessWidget {
  const _WindowsActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.accent.withValues(alpha: 0.12),
                  child: Icon(icon, color: AppColors.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: AppColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.grey.shade500),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OnboardingSlides extends StatelessWidget {
  const _OnboardingSlides({
    required this.controller,
    required this.page,
    required this.onPageChanged,
    this.windowsUi = false,
  });

  final PageController controller;
  final int page;
  final ValueChanged<int> onPageChanged;
  final bool windowsUi;

  @override
  Widget build(BuildContext context) {
    final List<({IconData icon, String title, String desc})> items =
        <({IconData icon, String title, String desc})>[
      (icon: Icons.edit_note, title: '1. 싫은 단어 입력', desc: 'apple, celebrity처럼 안 보고 싶은 키워드를 넣어요.'),
      (icon: Icons.shield, title: '2. 잠금 모드 ON', desc: '필요할 때 잠금 모드를 켜서 차단 강도를 올려요.'),
      (
        icon: Icons.visibility_off,
        title: '3. 이미지 숨김',
        desc: windowsUi
            ? 'DNS·앱 차단으로 접속을 줄이고, Chrome·Edge·Firefox 확장을 켜면 검색·이미지 화면도 같이 정리할 수 있어요.'
            : 'Safari 결과 화면에서 해당 이미지/요소가 가려져요.',
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('3초 튜토리얼', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SizedBox(
              height: 120,
              child: PageView.builder(
                controller: controller,
                onPageChanged: onPageChanged,
                itemCount: items.length,
                itemBuilder: (BuildContext context, int index) {
                  final item = items[index];
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: const Color(0xFFF1F6FD),
                    ),
                    child: Row(
                      children: <Widget>[
                        CircleAvatar(
                          backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                          child: Icon(item.icon, color: AppColors.ink),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(item.title, style: Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 4),
                              Text(
                                item.desc,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List<Widget>.generate(items.length, (int index) {
                final bool active = index == page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: active ? AppColors.accent : const Color(0xFFC9D5E8),
                    borderRadius: BorderRadius.circular(8),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoreScopeBanner extends StatelessWidget {
  const _CoreScopeBanner();

  @override
  Widget build(BuildContext context) {
    final bool isMac = Platform.isMacOS;
    final bool isWin = Platform.isWindows;
    final List<Widget> chips;
    if (isMac) {
      chips = const <Widget>[
        Chip(avatar: Icon(Icons.public, size: 16), label: Text('Mac 전체')),
        Chip(avatar: Icon(Icons.language, size: 16), label: Text('Safari + Chrome + Firefox')),
        Chip(avatar: Icon(Icons.dns_outlined, size: 16), label: Text('시스템 DNS 차단')),
      ];
    } else if (isWin) {
      chips = const <Widget>[
        Chip(avatar: Icon(Icons.desktop_windows, size: 16), label: Text('Windows')),
        Chip(avatar: Icon(Icons.language, size: 16), label: Text('Chrome · Edge · Firefox')),
        Chip(avatar: Icon(Icons.dns_outlined, size: 16), label: Text('시스템 DNS · 앱 차단')),
      ];
    } else {
      chips = const <Widget>[
        Chip(avatar: Icon(Icons.language, size: 16), label: Text('Safari 전용')),
        Chip(avatar: Icon(Icons.vpn_lock_outlined, size: 16), label: Text('VPN 앱 아님')),
        Chip(avatar: Icon(Icons.link_off, size: 16), label: Text('별도 연결 없음')),
      ];
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: chips,
      ),
    );
  }
}
