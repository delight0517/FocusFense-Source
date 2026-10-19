import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_stats.dart';
import '../services/local_database.dart';
import '../services/rules_export_service.dart';
import '../services/rules_host_resolver.dart';
import '../theme/app_colors.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, this.initialQuery, this.autoRunOnOpen = false});

  final String? initialQuery;
  final bool autoRunOnOpen;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  final RulesExportService _export = RulesExportService();
  final RulesHostResolver _resolver = RulesHostResolver.instance;
  StatsOverview? _overview;
  RuleCounts? _counts;
  bool _focusOn = false;
  bool _simulationOn = true;
  bool _loading = true;
  final TextEditingController _testQueryCtrl = TextEditingController(text: 'example keyword');

  @override
  void initState() {
    super.initState();
    final String q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _testQueryCtrl.text = q;
    }
    if (widget.autoRunOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await _applyAndTestNow();
      });
    }
    _load();
  }

  @override
  void dispose() {
    _testQueryCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final StatsOverview o = await AppStats.loadOverview(LocalDatabase.instance);
    final RuleCounts c = await _db.ruleCounts();
    final meta = await _db.rulesMeta();
    final bool sim = await _resolver.useLocalSimulation();
    if (!mounted) return;
    setState(() {
      _overview = o;
      _counts = c;
      _focusOn = meta.focusEnabled;
      _simulationOn = sim;
      _loading = false;
    });
  }

  String _fmtTime(int? epochMs) {
    if (epochMs == null) return '—';
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${t.year}.${t.month.toString().padLeft(2, '0')}.${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _openSafariTest() async {
    final String query = _testQueryCtrl.text.trim().isEmpty ? 'test image' : _testQueryCtrl.text.trim();
    final Uri url = Uri.parse('https://www.google.com/search?tbm=isch&q=${Uri.encodeComponent(query)}');
    // Use in-app Safari view on iOS so we don't jump to Google app.
    await launchUrl(url, mode: LaunchMode.inAppBrowserView);
  }

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(Object())}';

  Future<void> _addApplyAndTest() async {
    final String q = _testQueryCtrl.text.trim();
    if (q.isEmpty) return;
    await _db.insertKeyword(id: _newId(), pattern: q);
    await _export.exportCurrentRules();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('차단 단어로 추가 + 적용 완료: $q')),
    );
    await _load();
    await _openSafariTest();
  }

  Future<void> _applyAndTestNow() async {
    final String q = _testQueryCtrl.text.trim();
    if (q.isEmpty) return;
    await _export.exportCurrentRules();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('규칙 적용 후 테스트 시작: $q')),
    );
    await _load();
    await _openSafariTest();
  }

  Widget _statusChip(BuildContext context, String label, bool ok) {
    return Chip(
      label: Text(label),
      avatar: Icon(ok ? Icons.check_circle : Icons.warning_amber_rounded, size: 16, color: ok ? Colors.green : AppColors.danger),
      backgroundColor: ok ? const Color(0xFFE9F9F3) : const Color(0xFFFFEEF0),
      side: BorderSide.none,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: <Widget>[
            Text(
              Platform.isWindows ? '브라우저 테스트' : 'Safari 테스트',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '이 화면은 "지금 내 규칙이 어떤 상태인지"를 바로 보여주고, 즉시 테스트까지 실행합니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
            ),
            const SizedBox(height: 16),
            const _ScopeBadgeBanner(),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('왜 안 막히는지 3초 점검', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        _statusChip(context, '차단 단어 ${_counts?.keywordsEnabled ?? 0}개', (_counts?.keywordsEnabled ?? 0) > 0),
                        _statusChip(context, '잠금 모드 ${_focusOn ? "ON" : "OFF"}', _focusOn),
                        _statusChip(
                          context,
                          _simulationOn
                              ? '시뮬 모드'
                              : (Platform.isWindows ? '확장·DNS·규칙 동기화' : '실기기 App Group'),
                          !_simulationOn,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '중요: "apple"을 넣으면 검색어 입력 자체를 막는 게 아니라,\n'
                      '페이지 안의 이미지/텍스트 요소가 규칙에 따라 후처리됩니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
                    ),
                    if (_simulationOn) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        Platform.isWindows
                            ? '현재는 시뮬 모드라 실제 차단이 바로 보이지 않을 수 있습니다.\n'
                                'Chrome·Edge·Firefox 확장을 로드했는지, Windows 시스템 DNS 차단이 켜져 있는지 확인하세요.'
                            : '현재는 시뮬 모드라 Safari 실차단이 바로 보이지 않을 수 있습니다.\n'
                                '실제 Safari 차단 테스트는 설정에서 "로컬 시뮬레이션 저장소"를 꺼야 합니다.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.danger,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => context.go('/settings'),
                        icon: const Icon(Icons.settings),
                        label: Text(Platform.isWindows ? '설정에서 시뮬 모드 끄기' : '설정에서 실기기 모드로 전환'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const _BeforeAfterMiniCard(),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('빠른 테스트', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _testQueryCtrl,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        hintText: '테스트할 검색어 (예: celebrity, game)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _addApplyAndTest,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('바로 적용 + 테스트'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _openSafariTest,
                      icon: const Icon(Icons.open_in_new),
                      label: Text(Platform.isWindows ? '브라우저에서 검색 열기' : '지금 규칙으로 테스트'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_overview != null) ...<Widget>[
              _metricCard(
                context,
                title: '현재 차단 목록',
                rows: <String>[
                  '단어 차단: ${_overview!.keywordsEnabled}개',
                  '사이트 차단: ${_overview!.domainsEnabled}개',
                  '고급 규칙: ${_overview!.serpFiltersEnabled + _overview!.searchBlocksEnabled}개',
                ],
              ),
              const SizedBox(height: 12),
              _barCard(context),
              const SizedBox(height: 12),
              _metricCard(
                context,
                title: '앱 활동',
                rows: <String>[
                  '공유로 새로 넣은 호스트(누적): ${_overview!.hostsIngestedLifetime}개',
                  '규칙 적용(누적): ${_overview!.rulesExportsLifetime}회',
                  '마지막 적용: ${_fmtTime(_overview!.lastExportEpochMs)}',
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _barCard(BuildContext context) {
    final StatsOverview o = _overview!;
    final int total = (o.keywordsTotal + o.domainsTotal + o.serpFiltersTotal + o.searchBlocksTotal).clamp(1, 999999);
    final int enabled = o.keywordsEnabled + o.domainsEnabled + o.serpFiltersEnabled + o.searchBlocksEnabled;
    final double ratio = (enabled / total).clamp(0, 1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('활성화 비율', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: ratio, minHeight: 10, borderRadius: BorderRadius.circular(8)),
            const SizedBox(height: 8),
            Text('활성 ${enabled} / 전체 ${total}', style: const TextStyle(color: AppColors.muted)),
          ],
        ),
      ),
    );
  }

  Widget _metricCard(BuildContext context, {required String title, required List<String> rows}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            ...rows.map(
              (String line) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(line, style: const TextStyle(color: AppColors.ink, height: 1.35)),
              ),
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
            Text('Before / After', style: Theme.of(context).textTheme.titleSmall),
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
                  blocked && (i == 1 || i == 3) ? Icons.close : Icons.image_outlined,
                  size: 14,
                  color: blocked && (i == 1 || i == 3) ? AppColors.danger : AppColors.ink,
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
            Chip(avatar: Icon(Icons.language, size: 16), label: Text('Safari + Chrome + Firefox')),
            Chip(avatar: Icon(Icons.dns_outlined, size: 16), label: Text('시스템 DNS')),
          ]
        : Platform.isWindows
            ? const <Widget>[
                Chip(avatar: Icon(Icons.desktop_windows, size: 16), label: Text('Windows')),
                Chip(avatar: Icon(Icons.language, size: 16), label: Text('Chrome · Edge · Firefox')),
                Chip(avatar: Icon(Icons.vpn_lock_outlined, size: 16), label: Text('VPN 앱 아님')),
              ]
            : const <Widget>[
                Chip(avatar: Icon(Icons.language, size: 16), label: Text('Safari 전용')),
                Chip(avatar: Icon(Icons.vpn_lock_outlined, size: 16), label: Text('VPN 앱 아님')),
                Chip(avatar: Icon(Icons.link_off, size: 16), label: Text('별도 연결 없음')),
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
