import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../data/schedule_domain_presets.dart';
import '../models/rules_meta.dart';
import '../models/scheduled_rule_removal.dart';
import '../services/lock_policy_service.dart';
import '../services/lock_schedule_enforcement.dart';
import '../services/local_database.dart';
import '../theme/app_colors.dart';
import '../services/smart_rule_apply_service.dart';
import '../services/quick_block_service.dart';
import '../services/delayed_rule_removal_service.dart';
import '../widgets/smart_rule_input_bar.dart';
import '../widgets/unified_rule_kind_chip.dart';
import 'stats_screen.dart';

class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

String _newId() =>
    '${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(Object())}';

class _RulesScreenState extends State<RulesScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  final LockPolicyService _lockPolicy = LockPolicyService.instance;
  final TextEditingController _smartCtrl = TextEditingController();
  final TextEditingController _searchTermCtrl = TextEditingController();
  final TextEditingController _serpHostCtrl = TextEditingController(
    text: 'google.',
  );
  final TextEditingController _serpPathCtrl = TextEditingController(
    text: '/search',
  );
  final TextEditingController _serpSelectorsCtrl = TextEditingController(
    text: 'div#rso',
  );

  List<Map<String, Object?>> _keywords = <Map<String, Object?>>[];
  List<Map<String, Object?>> _domains = <Map<String, Object?>>[];
  List<Map<String, Object?>> _serp = <Map<String, Object?>>[];
  List<Map<String, Object?>> _searchBlocks = <Map<String, Object?>>[];
  RulesMeta _meta = RulesMeta.defaults;
  String _smartQuery = '';
  bool _applyingPreset = false;
  Map<String, ScheduledRuleRemoval> _pendingRemovals =
      <String, ScheduledRuleRemoval>{};

  static const List<({String label, List<String> words, String testQuery})>
  _quickPresets = <({String label, List<String> words, String testQuery})>[
    (
      label: '성인 콘텐츠',
      words: <String>['porn', 'adult', 'sex'],
      testQuery: 'adult',
    ),
    (
      label: '도박',
      words: <String>['casino', 'bet', 'gambling'],
      testQuery: 'casino',
    ),
    (
      label: '연예/자극',
      words: <String>['celebrity', 'gossip', 'leak'],
      testQuery: 'celebrity',
    ),
    (
      label: '쇼핑 충동',
      words: <String>['shopping', 'sale', 'deal'],
      testQuery: 'shopping deals',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _smartCtrl.addListener(_onSmartQueryChanged);
    DelayedRuleRemovalService.instance.addListener(_onPendingRemovalChanged);
    _reload();
  }

  void _onPendingRemovalChanged() {
    _reload();
  }

  void _onSmartQueryChanged() {
    final String next = _smartCtrl.text;
    if (next == _smartQuery || !mounted) return;
    setState(() => _smartQuery = next);
  }

  Future<void> _reload() async {
    await enforceLockScheduleIfNeeded();
    final List<Map<String, Object?>> k = await _db.keywords();
    final List<Map<String, Object?>> d = await _db.domains();
    final List<Map<String, Object?>> s = await _db.serpFilters();
    final List<Map<String, Object?>> q = await _db.searchQueryBlocks();
    final RulesMeta m = await _db.rulesMeta();
    final List<ScheduledRuleRemoval> pending = await DelayedRuleRemovalService
        .instance
        .loadPending();
    setState(() {
      _keywords = k;
      _domains = d;
      _serp = s;
      _searchBlocks = q;
      _meta = m;
      _pendingRemovals = <String, ScheduledRuleRemoval>{
        for (final ScheduledRuleRemoval item in pending) item.key: item,
      };
    });
  }

  bool get _locked => _lockPolicy.isLockedByPolicy(_meta);

  bool _allowDisable(bool nextValue) => !_locked || nextValue;

  void _showLockedSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('잠금 상태에서는 해제/삭제를 할 수 없습니다. 추가만 가능합니다.')),
    );
  }

  Future<void> _toggleScheduledRemoval({
    required ScheduledRuleKind ruleKind,
    required String id,
    required String label,
  }) async {
    final DelayedRuleRemovalService service =
        DelayedRuleRemovalService.instance;
    await service.loadPending();
    final ScheduledRuleRemoval? pending = service.pendingFor(ruleKind, id);
    if (pending != null) {
      await service.cancelRemoval(ruleKind: ruleKind, ruleId: id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('“$label” 제거 예약을 취소했습니다.')));
      return;
    }
    if (_locked) {
      _showLockedSnack();
      return;
    }
    await service.scheduleRemoval(ruleKind: ruleKind, ruleId: id, label: label);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('“$label” 차단을 3시간 뒤 제거하도록 예약했습니다.'),
        action: SnackBarAction(
          label: '취소',
          onPressed: () =>
              service.cancelRemoval(ruleKind: ruleKind, ruleId: id),
        ),
      ),
    );
  }

  @override
  void dispose() {
    DelayedRuleRemovalService.instance.removeListener(_onPendingRemovalChanged);
    _smartCtrl.removeListener(_onSmartQueryChanged);
    _smartCtrl.dispose();
    _searchTermCtrl.dispose();
    _serpHostCtrl.dispose();
    _serpPathCtrl.dispose();
    _serpSelectorsCtrl.dispose();
    super.dispose();
  }

  Future<void> _addSerp() async {
    final String host = _serpHostCtrl.text.trim();
    final String path = _serpPathCtrl.text.trim();
    if (host.isEmpty || path.isEmpty) return;
    final List<String> sels = _serpSelectorsCtrl.text
        .split(',')
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
    await _db.insertSerpFilter(
      id: _newId(),
      hostSuffix: host,
      pathPrefix: path.startsWith('/') ? path : '/$path',
      removeSelectors: sels,
      enabled: false,
    );
    await _reload();
  }

  Future<void> _addSearchBlock() async {
    final String term = _searchTermCtrl.text.trim();
    if (term.isEmpty) return;
    await _db.insertSearchQueryBlock(id: _newId(), term: term);
    _searchTermCtrl.clear();
    await _reload();
  }

  Future<void> _addKeywordPreset(List<String> words, String testQuery) async {
    for (final String word in words) {
      await _db.insertKeyword(id: _newId(), pattern: word);
    }
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('프리셋 추가 완료, 테스트로 이동: ${words.join(", ")}')),
    );
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            StatsScreen(initialQuery: testQuery, autoRunOnOpen: true),
      ),
    );
  }

  Future<void> _addSmartRule({String? rawInput}) async {
    final String raw = (rawInput ?? _smartCtrl.text).trim();
    if (raw.isEmpty) return;

    final ScheduleDomainPreset? preset = exactQuickBlockPreset(raw);
    if (preset != null) {
      await _applyQuickBlockPreset(preset);
      return;
    }

    final Set<String> existingDomains = _domains
        .map((Map<String, Object?> r) => (r['host']! as String).toLowerCase())
        .toSet();
    final Set<String> existingKeywords = _keywords
        .map(
          (Map<String, Object?> r) => (r['pattern']! as String).toLowerCase(),
        )
        .toSet();

    if (!context.mounted) return;
    final SmartRuleApplyResult result = await SmartRuleApplyService.instance
        .applyLine(
          context: context,
          rawLine: raw,
          existingDomains: existingDomains,
          existingKeywords: existingKeywords,
          newId: _newId,
        );

    if (!context.mounted) return;
    if (result.cancelled) return;

    if (rawInput == null) _smartCtrl.clear();
    await _reload();

    if (!mounted) return;
    final String msg = result.error ?? result.summaryMessage();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.hostTruncationNote != null
              ? '$msg\n${result.hostTruncationNote}'
              : msg,
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _applyQuickBlockPreset(ScheduleDomainPreset preset) async {
    if (_applyingPreset) return;
    setState(() => _applyingPreset = true);
    int added = 0;
    Object? error;
    try {
      added = await QuickBlockService.instance.applySchedulePreset(preset);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _applyingPreset = false);
    }
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('프리셋 적용 실패: $error')));
      return;
    }
    _smartCtrl.clear();
    await _reload();
    if (!mounted) return;
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

  Widget _buildQuickBlockPresetSuggestions() {
    final List<ScheduleDomainPreset> matches = matchQuickBlockPresets(
      _smartQuery,
    );
    if (matches.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.auto_awesome, size: 17, color: AppColors.accent),
                const SizedBox(width: 6),
                Text(
                  '일치하는 차단 프리셋',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...matches.take(4).map((ScheduleDomainPreset preset) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _applyingPreset
                        ? null
                        : () => _applyQuickBlockPreset(preset),
                    icon: Icon(preset.icon, size: 18),
                    label: Text(
                      '${preset.name} 프리셋 · ${preset.itemCount}개를 차단 목록에 추가',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              );
            }),
            Text(
              '버튼을 누르면 기존 프리셋 항목이 차단 목록에 추가됩니다.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: <Widget>[
            Text(
              Platform.isWindows ? '차단 규칙 (키워드·검색 후처리)' : '차단 규칙 (브라우저)',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '원치 않는 이미지를 안 보이게 만들 규칙을 고르는 화면입니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            const _ScopeBadgeBanner(),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '이렇게 이해하면 쉬워요',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: const <Widget>[
                        Chip(
                          avatar: Icon(Icons.visibility_off, size: 16),
                          label: Text('안 보고 싶은 것 입력'),
                        ),
                        Chip(
                          avatar: Icon(Icons.auto_fix_high, size: 16),
                          label: Text('앱이 자동으로 규칙 생성'),
                        ),
                        Chip(
                          avatar: Icon(Icons.block, size: 16),
                          label: Text('이미지/요소 X 처리'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '예시: apple 을 넣으면 apple 관련 이미지/텍스트 요소가 결과 화면에서 가려집니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const _BeforeAfterMiniCard(),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '이 차단은 이렇게 동작해요',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      Platform.isWindows
                          ? '1) 단어/사이트를 목록에 추가\n'
                                '2) 테스트 탭에서 "추가 + 적용 + 테스트 시작"\n'
                                '3) 브라우저(앱 내 테스트 또는 확장)에서 결과 확인'
                          : '1) 단어/사이트를 목록에 추가\n'
                                '2) 테스트 탭에서 "추가 + 적용 + 테스트 시작"\n'
                                '3) 브라우저 페이지에서 결과 확인',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '주의: 검색어 입력창 자체를 막는 기능이 아니라, 결과 페이지의 내용(이미지/텍스트)을 규칙으로 후처리합니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '통합 입력 (자동 감지)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'URL·도메인·YouTube 채널/영상·검색 키워드를 한 칸에 넣으면 종류를 자동으로 고릅니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            SmartRuleInputBar(
              controller: _smartCtrl,
              onAdd: _addSmartRule,
              enabled: !_applyingPreset,
              addLabel: _applyingPreset ? '적용 중…' : '추가',
            ),
            _buildQuickBlockPresetSuggestions(),
            const SizedBox(height: 10),
            Text(
              '원터치 프리셋',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _quickPresets
                  .map(
                    (preset) => FilledButton.tonalIcon(
                      onPressed: () =>
                          _addKeywordPreset(preset.words, preset.testQuery),
                      icon: const Icon(Icons.flash_on, size: 16),
                      label: Text(preset.label),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: _keywords.isNotEmpty || _domains.isNotEmpty,
              title: Text(
                '등록된 규칙 (${_keywords.length + _domains.length})',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: Text(
                '키워드 ${_keywords.length} · 사이트 ${_domains.length}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              children: <Widget>[
                if (_keywords.isEmpty && _domains.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '위 통합 입력으로 규칙을 추가하세요.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                    ),
                  ),
                ..._keywords.map(_keywordTile),
                ..._domains.map(_domainTile),
              ],
            ),
            const Divider(height: 36),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: false,
              childrenPadding: const EdgeInsets.only(top: 8),
              title: Text(
                '고급 규칙 (선택)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: Text(
                '초보자는 건너뛰어도 됩니다.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              children: <Widget>[
                Text('검색결과 필터', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(
                  '검색 결과 페이지의 특정 영역을 숨기는 기능입니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                ..._serp.map(_serpTile),
                const SizedBox(height: 12),
                TextField(
                  controller: _serpHostCtrl,
                  decoration: const InputDecoration(
                    labelText: '호스트 접미사',
                    hintText: 'google.',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _serpPathCtrl,
                  decoration: const InputDecoration(
                    labelText: '경로 접두',
                    hintText: '/search',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _serpSelectorsCtrl,
                  decoration: const InputDecoration(
                    labelText: '제거할 선택자',
                    hintText: '쉼표로 구분: div#rso, div#search',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: _addSerp,
                    child: const Text('검색결과 필터 추가'),
                  ),
                ),
                const Divider(height: 28),
                Text('검색어 차단', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(
                  '특정 검색어 자체를 제한할 때 사용합니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _searchTermCtrl,
                        decoration: const InputDecoration(hintText: '차단할 검색어'),
                        autocorrect: false,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _addSearchBlock,
                      child: const Text('추가'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ..._searchBlocks.map(_searchBlockTile),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const Set<String> _kMatchTypes = <String>{
    'contains',
    'exact',
    'starts_with',
  };
  static const Set<String> _kKeywordActions = <String>{'redact', 'remove', 'block_page'};

  String _keywordMatch(String raw) =>
      _kMatchTypes.contains(raw) ? raw : 'contains';

  String _keywordAction(String raw) =>
      _kKeywordActions.contains(raw) ? raw : 'redact';

  Widget _keywordTile(Map<String, Object?> row) {
    final String id = row['id']! as String;
    final String pattern = row['pattern']! as String;
    final bool removalScheduled = _pendingRemovals.containsKey('keyword:$id');
    final bool en = (row['enabled'] as int) == 1;
    final String match = _keywordMatch(row['match_type']! as String);
    final String action = _keywordAction(row['action']! as String);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          row['pattern']! as String,
                          style: const TextStyle(color: AppColors.ink),
                        ),
                      ),
                      UnifiedRuleKindChip(
                        value: row['pattern']! as String,
                        isDomainRow: false,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: removalScheduled
                      ? '제거 예약 취소'
                      : _locked
                      ? '잠금 중'
                      : '3시간 뒤 제거 예약',
                  onPressed: _locked && !removalScheduled
                      ? _showLockedSnack
                      : () => _toggleScheduledRemoval(
                          ruleKind: ScheduledRuleKind.keyword,
                          id: id,
                          label: pattern,
                        ),
                  icon: Icon(
                    removalScheduled ? Icons.undo : Icons.schedule,
                    color: removalScheduled
                        ? Colors.orange.shade800
                        : AppColors.muted,
                  ),
                ),
              ],
            ),
            if (removalScheduled)
              const Padding(
                padding: EdgeInsets.only(left: 8, bottom: 6),
                child: Text(
                  '제거 예약됨 · 차단은 예약 시각까지 유지',
                  style: TextStyle(color: Colors.deepOrange, fontSize: 12),
                ),
              ),
            Row(
              children: <Widget>[
                FilterChip(
                  label: const Text('사용'),
                  selected: en,
                  onSelected: (bool v) async {
                    if (!_allowDisable(v)) {
                      _showLockedSnack();
                      return;
                    }
                    await _db.setKeywordEnabled(id, v);
                    await _reload();
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '일치',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.muted,
                        ),
                      ),
                      DropdownButton<String>(
                        isExpanded: true,
                        value: match,
                        items: const <DropdownMenuItem<String>>[
                          DropdownMenuItem(
                            value: 'contains',
                            child: Text('포함'),
                          ),
                          DropdownMenuItem(
                            value: 'exact',
                            child: Text('완전 일치'),
                          ),
                          DropdownMenuItem(
                            value: 'starts_with',
                            child: Text('접두사'),
                          ),
                        ],
                        onChanged: (String? v) async {
                          if (v == null) return;
                          await _db.updateKeywordFields(id: id, matchType: v);
                          await _reload();
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '동작',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.muted,
                        ),
                      ),
                      DropdownButton<String>(
                        isExpanded: true,
                        value: action,
                        items: const <DropdownMenuItem<String>>[
                          DropdownMenuItem(value: 'redact', child: Text('가리기')),
                          DropdownMenuItem(value: 'block_page', child: Text('페이지 차단')),
                          DropdownMenuItem(
                            value: 'remove',
                            child: Text('노드 제거'),
                          ),
                        ],
                        onChanged: (String? v) async {
                          if (v == null) return;
                          await _db.updateKeywordFields(id: id, action: v);
                          await _reload();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _domainTile(Map<String, Object?> row) {
    final String id = row['id']! as String;
    final String host = row['host']! as String;
    final bool removalScheduled = _pendingRemovals.containsKey('domain:$id');
    final bool en = (row['enabled'] as int) == 1;
    final bool sub = (row['include_subdomains'] as int) == 1;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            host,
                            style: const TextStyle(color: AppColors.ink),
                          ),
                        ),
                        UnifiedRuleKindChip(value: host, isDomainRow: true),
                      ],
                    ),
                    subtitle: Text(
                      removalScheduled
                          ? '제거 예약됨 · 차단은 예약 시각까지 유지'
                          : '출처: ${row['source']}',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: removalScheduled
                      ? '제거 예약 취소'
                      : _locked
                      ? '잠금 중'
                      : '3시간 뒤 제거 예약',
                  onPressed: _locked && !removalScheduled
                      ? _showLockedSnack
                      : () => _toggleScheduledRemoval(
                          ruleKind: ScheduledRuleKind.domain,
                          id: id,
                          label: host,
                        ),
                  icon: Icon(
                    removalScheduled ? Icons.undo : Icons.schedule,
                    color: removalScheduled
                        ? Colors.orange.shade800
                        : AppColors.muted,
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: const Text('차단에 포함'),
              value: en,
              onChanged: (bool v) async {
                if (!_allowDisable(v)) {
                  _showLockedSnack();
                  return;
                }
                await _db.setDomainEnabled(id, v);
                await _reload();
              },
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              dense: true,
              title: const Text('하위 도메인 포함'),
              value: sub,
              onChanged: (bool v) async {
                await _db.setDomainIncludeSubdomains(id, v);
                await _reload();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _serpTile(Map<String, Object?> row) {
    final String id = row['id']! as String;
    final bool en = (row['enabled'] as int) == 1;
    final String host = row['host_suffix']! as String;
    final String path = row['path_prefix']! as String;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          '$host*$path',
          style: const TextStyle(color: AppColors.ink, fontSize: 14),
        ),
        subtitle: Text(
          row['remove_selectors_json'] as String? ?? '[]',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.muted, fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Switch(
              value: en,
              onChanged: (bool v) async {
                if (!_allowDisable(v)) {
                  _showLockedSnack();
                  return;
                }
                await _db.setSerpFilterEnabled(id, v);
                await _reload();
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _locked
                  ? () => _showLockedSnack()
                  : () async {
                      await _db.deleteSerpFilter(id);
                      await _reload();
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBlockTile(Map<String, Object?> row) {
    final String id = row['id']! as String;
    final bool en = (row['enabled'] as int) == 1;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(row['term']! as String),
        subtitle: Text(
          '${row['match']} · ${row['scope']}',
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Switch(
              value: en,
              onChanged: (bool v) async {
                if (!_allowDisable(v)) {
                  _showLockedSnack();
                  return;
                }
                await _db.setSearchBlockEnabled(id, v);
                await _reload();
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _locked
                  ? () => _showLockedSnack()
                  : () async {
                      await _db.deleteSearchQueryBlock(id);
                      await _reload();
                    },
            ),
          ],
        ),
      ),
    );
  }
}

class _BeforeAfterMiniCard extends StatelessWidget {
  const _BeforeAfterMiniCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Before / After',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(child: _panel(context, 'Before', false)),
                const SizedBox(width: 8),
                Expanded(child: _panel(context, 'After', true)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel(BuildContext context, String label, bool blocked) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: blocked ? const Color(0xFFFFEEF0) : const Color(0xFFE9F9F3),
      ),
      child: Column(
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: List<Widget>.generate(4, (int i) {
              return Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  blocked && (i == 1 || i == 3)
                      ? Icons.close
                      : Icons.image_outlined,
                  size: 14,
                  color: blocked && (i == 1 || i == 3)
                      ? AppColors.danger
                      : AppColors.ink,
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _ScopeBadgeBanner extends StatelessWidget {
  const _ScopeBadgeBanner();

  @override
  Widget build(BuildContext context) {
    final List<Widget> chips = Platform.isMacOS
        ? const <Widget>[
            Chip(avatar: Icon(Icons.public, size: 16), label: Text('Mac 전체')),
            Chip(
              avatar: Icon(Icons.language, size: 16),
              label: Text('Safari + Chrome + Firefox'),
            ),
            Chip(
              avatar: Icon(Icons.dns_outlined, size: 16),
              label: Text('시스템 DNS'),
            ),
          ]
        : Platform.isWindows
        ? const <Widget>[
            Chip(
              avatar: Icon(Icons.desktop_windows, size: 16),
              label: Text('Windows'),
            ),
            Chip(
              avatar: Icon(Icons.language, size: 16),
              label: Text('Chrome · Edge · Firefox'),
            ),
            Chip(
              avatar: Icon(Icons.vpn_lock_outlined, size: 16),
              label: Text('VPN 앱 아님'),
            ),
          ]
        : const <Widget>[
            Chip(
              avatar: Icon(Icons.language, size: 16),
              label: Text('브라우저 확장'),
            ),
            Chip(
              avatar: Icon(Icons.vpn_lock_outlined, size: 16),
              label: Text('VPN 앱 아님'),
            ),
            Chip(
              avatar: Icon(Icons.link_off, size: 16),
              label: Text('별도 연결 없음'),
            ),
          ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }
}
