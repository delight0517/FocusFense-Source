import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/block_sync_service.dart';
import '../services/browser_block_enforcement_health_service.dart';
import '../services/extension_guard_prefs.dart';
import '../services/protection_coverage_service.dart';
import '../services/protection_gap_actions.dart';
import '../services/in_app_rebuild_actions.dart';
import '../services/windows_extension_guard_service.dart';
import '../services/windows_extension_self_heal_service.dart';
import '../theme/app_colors.dart';

/// Desktop/mobile shell: shows gaps between configured rules and live enforcement.
class ProtectionGapsBanner extends StatefulWidget {
  const ProtectionGapsBanner({super.key, this.compact = false});

  final bool compact;

  @override
  State<ProtectionGapsBanner> createState() => _ProtectionGapsBannerState();
}

bool _hideGapForOneTapChrome(ProtectionGap g) {
  if (!Platform.isWindows) return false;
  // Firefox gaps must stay visible — extension/XPI missing = silent YouTube leaks.
  if (g.browsers.contains('firefox')) return false;
  return g.fix == ProtectionGapFix.easySetup ||
      g.fix == ProtectionGapFix.browserExtensions ||
      g.fix == ProtectionGapFix.connectBrowsers;
}

class _ProtectionGapsBannerState extends State<ProtectionGapsBanner>
    with WidgetsBindingObserver {
  ProtectionCoverageReport? _report;
  bool _loading = true;
  bool _expanded = false;
  bool _chromeUnprotected = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    BlockSyncService.instance.hostsApplyPending.addListener(_onHostsPending);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BlockSyncService.instance.hostsApplyPending.removeListener(_onHostsPending);
    _debounce?.cancel();
    super.dispose();
  }

  void _onHostsPending() => _scheduleRefresh();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ProtectionCoverageService.instance.invalidateCache();
      _refresh();
    }
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      _refresh(silent: true);
    });
  }

  Future<void> _refresh({bool force = false, bool silent = false}) async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!silent && _report == null) {
      setState(() => _loading = true);
    }
    try {
      final ProtectionCoverageReport r =
          await ProtectionCoverageService.instance.analyze(force: force);
      bool chromeUnprotected = false;
      if (Platform.isWindows) {
        final BrowserEnforcementHealth enforce =
            await BrowserBlockEnforcementHealthService.instance.analyze(
          force: force,
        );
        chromeUnprotected = enforce.chromeUnprotectedRunning;
      }
      if (mounted) {
        setState(() {
          _report = r;
          _chromeUnprotected = chromeUnprotected;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onFix(ProtectionGapFix fix) async {
    if (!mounted) return;
    await ProtectionGapActions.apply(context, fix);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return const SizedBox.shrink();
    }
    if (_loading && _report == null) {
      return const SizedBox.shrink();
    }
    final ProtectionCoverageReport? report = _report;
    if (report == null || report.allClear) {
      return const SizedBox.shrink();
    }
    if (_chromeUnprotected) return const SizedBox.shrink();

    final List<ProtectionGap> gaps = report.gaps
        .where((ProtectionGap g) => g.severity != ProtectionGapSeverity.info)
        .where((ProtectionGap g) => !_hideGapForOneTapChrome(g))
        .toList();
    if (gaps.isEmpty) return const SizedBox.shrink();

    final Color border = gaps.any(
          (ProtectionGap g) => g.severity == ProtectionGapSeverity.critical,
        )
        ? AppColors.danger
        : Colors.orange.shade800;

    final int showCount = widget.compact && !_expanded ? 1 : gaps.length;

    return Material(
      color: border.withValues(alpha: 0.08),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, color: border, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '일부 차단이 아직 작동하지 않습니다 (${gaps.length})',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: border,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: '다시 점검',
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: () => _refresh(force: true),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: border,
                  ),
                ],
              ),
              if (_expanded || !widget.compact) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  _summaryLine(report.inventory),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              ...gaps.take(showCount).map((ProtectionGap g) => _GapTile(
                    gap: g,
                    onFix: () => _onFix(g.fix),
                    onSettings: () => _onFix(ProtectionGapFix.settings),
                    onRebuild: Platform.isWindows ? _offerRebuild : null,
                  )),
              if (widget.compact && gaps.length > 1 && !_expanded)
                TextButton(
                  onPressed: () => setState(() => _expanded = true),
                  child: Text('${gaps.length - 1}개 더 보기'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _summaryLine(RuleInventory inv) {
    final List<String> parts = <String>[];
    if (inv.keywordCount > 0) parts.add('키워드 ${inv.keywordCount}');
    if (inv.youtubeChannelCount + inv.youtubeVideoCount > 0) {
      parts.add(
        '유튜브 ${inv.youtubeChannelCount + inv.youtubeVideoCount}',
      );
    }
    if (inv.searchQueryCount > 0) parts.add('검색어 ${inv.searchQueryCount}');
    if (inv.hostsRuleCount > 0) parts.add('도메인 ${inv.hostsRuleCount}');
    return parts.isEmpty ? '활성 규칙 있음' : '활성: ${parts.join(' · ')}';
  }

  Future<void> _offerRebuild() async {
    if (!mounted) return;
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Windows 앱 다시 빌드'),
        content: const Text(
          '확장·정책 설치 후에도 차단이 안 되면 최신 exe로 다시 빌드하세요.\n'
          '홈 상단 카드·모든 탭 상단 「최신 버전 빌드」 버튼을 사용할 수 있습니다.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('닫기'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx, false);
              _onFix(ProtectionGapFix.settings);
            },
            child: const Text('설정으로'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('지금 재빌드'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await InAppRebuildActions.startRebuild(context);
  }
}

class _GapTile extends StatelessWidget {
  const _GapTile({
    required this.gap,
    required this.onFix,
    required this.onSettings,
    this.onRebuild,
  });

  final ProtectionGap gap;
  final VoidCallback onFix;
  final VoidCallback onSettings;
  final VoidCallback? onRebuild;

  String get _fixLabel {
    switch (gap.fix) {
      case ProtectionGapFix.easySetup:
        return Platform.isWindows ? 'Chrome 열기' : '쉬운 설치';
      case ProtectionGapFix.browserExtensions:
        return Platform.isWindows ? 'Chrome 열기' : '브라우저 확장';
      case ProtectionGapFix.applyHosts:
        return '지금 적용';
      case ProtectionGapFix.settings:
        return '설정';
      case ProtectionGapFix.diagnostics:
        return '진단';
      case ProtectionGapFix.youtubeRules:
        return '유튜브 규칙';
      case ProtectionGapFix.connectBrowsers:
        return 'Chrome 열기';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            gap.title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(gap.detail, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              FilledButton.tonal(
                onPressed: onFix,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(_fixLabel),
              ),
              TextButton(
                onPressed: onSettings,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('설정'),
              ),
              if (onRebuild != null)
                TextButton(
                  onPressed: onRebuild,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('재빌드 안내'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Full-screen sheet listing every gap (settings entry).
Future<void> showProtectionCoverageSheet(BuildContext context) async {
  final ProtectionCoverageReport report =
      await ProtectionCoverageService.instance.analyze(force: true);
  ExtensionPolicyVerifyResult? verify;
  if (Platform.isWindows) {
    try {
      verify = await WindowsExtensionGuardService.verifyAllPolicies();
    } catch (_) {}
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, ScrollController scroll) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: ListView(
              controller: scroll,
              children: <Widget>[
                Text(
                  '보호 상태',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '각 차단 경로가 실제로 적용 중인지, 사용자 조작이 필요한지 한눈에 확인합니다.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                _ProtectionStatusList(report: report, verify: verify),
                if (Platform.isWindows && verify != null && !verify.chromeOk) ...<Widget>[
                  const SizedBox(height: 12),
                  _ForceRetryCard(onDone: () => Navigator.pop(ctx)),
                ],
                const SizedBox(height: 20),
                if (report.gaps.isNotEmpty) ...<Widget>[
                  Text(
                    '필요한 조치 ${report.gaps.length}',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...report.gaps.map(
                    (ProtectionGap g) => Card(
                      child: ListTile(
                        title: Text(g.title),
                        subtitle: Text(g.detail),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          Navigator.pop(ctx);
                          if (context.mounted) {
                            await ProtectionGapActions.apply(context, g.fix);
                          }
                        },
                      ),
                    ),
                  ),
                ] else
                  Card(
                    color: AppColors.success.withValues(alpha: 0.10),
                    child: ListTile(
                      leading: Icon(Icons.verified, color: AppColors.success),
                      title: const Text('모든 차단 경로 자동 적용 중'),
                      subtitle: const Text(
                        '추가 조작 없이도 설정한 규칙이 시스템·브라우저에 반영되어 있습니다.',
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// Reset-and-retry card surfaced when Chrome/Edge guard previously failed —
/// e.g. user cancelled UAC, IT policy blocked HKLM. Clears the "skip elevated"
/// pref + cooldown so the next self-heal can prompt UAC again. Without this
/// the app silently respects the prior decline and Chrome stays unprotected.
class _ForceRetryCard extends StatefulWidget {
  const _ForceRetryCard({required this.onDone});

  final VoidCallback onDone;

  @override
  State<_ForceRetryCard> createState() => _ForceRetryCardState();
}

class _ForceRetryCardState extends State<_ForceRetryCard> {
  bool _running = false;
  String? _status;

  Future<void> _retry() async {
    setState(() {
      _running = true;
      _status = '이전 거절 기록을 지우는 중…';
    });
    await ExtensionGuardPrefs.instance.setElevatedGuardSkipped(false);
    WindowsExtensionSelfHealService.instance.clearCooldown();
    if (!mounted) return;
    setState(() => _status = 'Chrome/Edge 자동 설치 재시도 중 — UAC 창이 뜨면 「예」를 선택하세요…');
    final ExtensionSelfHealResult result =
        await WindowsExtensionSelfHealService.instance.runSelfHeal(
      attemptElevated: true,
      onStatus: (String s) {
        if (mounted) setState(() => _status = s);
      },
    );
    if (!mounted) return;
    setState(() => _running = false);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.isAcceptable
            ? '재시도 완료 — Chrome/Edge 보호 다시 점검됨'
            : '재시도 결과: ${result.message}'),
        duration: const Duration(seconds: 5),
      ),
    );
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.danger.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.danger.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.warning_amber_rounded, color: AppColors.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Chrome/Edge 보호가 전혀 적용되지 않았습니다',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'UAC를 거절했거나 정책 쓰기가 막혀 자동 설치를 더 시도하지 않는 상태입니다. '
              '아래 버튼을 누르면 거절 기록을 지우고 모든 설치 경로(HKCU → HKLM)를 다시 시도합니다. '
              'UAC 창이 뜨면 「예」를 선택하세요.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_status != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _status!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _running ? null : _retry,
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(_running ? '재시도 중…' : '초기화 후 자동 재설치'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _LayerState { ok, attention, blocked, na }

class _LayerRow {
  const _LayerRow({
    required this.icon,
    required this.label,
    required this.state,
    required this.detail,
  });

  final IconData icon;
  final String label;
  final _LayerState state;
  final String detail;
}

class _ProtectionStatusList extends StatelessWidget {
  const _ProtectionStatusList({required this.report, required this.verify});

  final ProtectionCoverageReport report;
  final ExtensionPolicyVerifyResult? verify;

  @override
  Widget build(BuildContext context) {
    final List<_LayerRow> rows = _buildRows();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final _LayerRow r in rows) _statusTile(context, r),
      ],
    );
  }

  List<_LayerRow> _buildRows() {
    final List<_LayerRow> rows = <_LayerRow>[];

    // 1. System DNS / hosts
    rows.add(
      _LayerRow(
        icon: Icons.dns_outlined,
        label: Platform.isWindows
            ? 'Windows hosts (모든 프로그램·DNS)'
            : 'System hosts (모든 브라우저)',
        state: report.hostsActive
            ? _LayerState.ok
            : (report.inventory.needsHosts
                ? _LayerState.attention
                : _LayerState.na),
        detail: report.hostsActive
            ? '도메인 차단이 시스템 DNS에 적용 중. 앱·게임 등 모든 프로그램에서 작동합니다.'
            : (report.inventory.needsHosts
                ? '「지금 적용」을 누르면 UAC 창이 뜹니다 — 「예」를 선택하면 시스템 전체에 반영됩니다.'
                : '도메인 규칙이 없어 hosts 적용은 필요하지 않습니다.'),
      ),
    );

    // 2. Rules server (extension feeds from this)
    rows.add(
      _LayerRow(
        icon: Icons.api,
        label: '규칙 API 서버 (127.0.0.1:17361)',
        state: report.rulesApiRunning ? _LayerState.ok : _LayerState.blocked,
        detail: report.rulesApiRunning
            ? '브라우저 확장이 키워드·유튜브·검색어 규칙을 5초마다 자동으로 받아갑니다.'
            : '서버가 꺼져 있어 확장이 규칙을 받지 못합니다. 앱을 재실행하세요.',
      ),
    );

    if (!Platform.isWindows) return rows;
    final ExtensionPolicyVerifyResult? v = verify;

    // 3. Chrome — this Windows account (HKCU)
    rows.add(
      _LayerRow(
        icon: Icons.account_circle_outlined,
        label: 'Chrome — 이 Windows 계정',
        state: _chromeHkcuState(v),
        detail: _chromeHkcuDetail(v),
      ),
    );

    // 4. Chrome — all Windows accounts (HKLM)
    rows.add(
      _LayerRow(
        icon: Icons.groups_outlined,
        label: 'Chrome — 이 PC 모든 Windows 계정',
        state: _chromeHklmState(v),
        detail: _chromeHklmDetail(v),
      ),
    );

    // 5. Edge HKCU+HKLM merged status
    rows.add(
      _LayerRow(
        icon: Icons.web_asset_outlined,
        label: 'Microsoft Edge',
        state: report.edgeExtensionOk ? _LayerState.ok : _LayerState.attention,
        detail: _edgeDetail(v, report.edgeExtensionOk),
      ),
    );

    // 6. Firefox
    rows.add(
      _LayerRow(
        icon: Icons.local_fire_department_outlined,
        label: 'Firefox',
        state: report.firefoxExtensionOk
            ? _LayerState.ok
            : (report.inventory.needsExtension
                ? _LayerState.attention
                : _LayerState.na),
        detail: report.firefoxExtensionOk
            ? 'policies.json + XPI + 프로필 복사 완료 — 키워드·유튜브 차단 작동.'
            : (report.inventory.needsExtension
                ? '확장 미설치 — 설정 → 「쉬운 설치」를 실행하면 자동 적용됩니다.'
                : '확장 규칙이 없어 Firefox 설정은 필요하지 않습니다.'),
      ),
    );

    return rows;
  }

  _LayerState _chromeHkcuState(ExtensionPolicyVerifyResult? v) {
    if (v == null) return _LayerState.na;
    if (v.chromeHkcuOk || v.chromeUserInstallOk) return _LayerState.ok;
    if (!report.inventory.needsExtension) return _LayerState.na;
    return _LayerState.attention;
  }

  String _chromeHkcuDetail(ExtensionPolicyVerifyResult? v) {
    if (v == null) return 'Windows 외 플랫폼.';
    if (v.chromeHkcuOk) {
      return 'HKCU 정책으로 force-install + 핀 고정. 사용자가 확장을 끌 수 없습니다.';
    }
    if (v.chromeUserInstallOk) {
      return '사용자 영역(HKCU) 외부 확장으로 등록됨. Chrome 재시작 시 자동 설치됩니다.';
    }
    return 'Chrome에 확장이 등록 안 됨. 백그라운드 자가 복구가 곧 다시 시도합니다.';
  }

  _LayerState _chromeHklmState(ExtensionPolicyVerifyResult? v) {
    if (v == null) return _LayerState.na;
    if (v.chromeHklmOk) return _LayerState.ok;
    if (!report.inventory.needsExtension) return _LayerState.na;
    return _LayerState.attention;
  }

  String _chromeHklmDetail(ExtensionPolicyVerifyResult? v) {
    if (v == null) return 'Windows 외 플랫폼.';
    if (v.chromeHklmOk) {
      return '시스템 정책(HKLM)으로 등록 — 이 PC의 모든 Windows 사용자 Chrome에 자동 설치됩니다.';
    }
    return '관리자 권한이 필요해 다른 Windows 계정 Chrome은 아직 자동 설치 안 됨. '
        '앱 시작 시 한 번 UAC 창이 떴다면 「예」를 누르세요 — 거절했다면 '
        '설정 → 「쉬운 설치」에서 다시 시도할 수 있습니다.';
  }

  String _edgeDetail(ExtensionPolicyVerifyResult? v, bool edgeOk) {
    if (v == null) {
      return edgeOk ? 'Edge 정책 설치됨.' : 'Edge 정책 미설치.';
    }
    if (v.edgeHklmOk) {
      return '시스템 정책(HKLM)으로 모든 사용자 Edge에 자동 설치.';
    }
    if (v.edgeHkcuOk || v.edgeUserInstallOk) {
      return '이 Windows 계정 Edge에만 적용됨. 다른 계정 Edge는 「쉬운 설치」(UAC) 필요.';
    }
    return 'Edge에 확장 미설치 — 백그라운드 자가 복구가 다시 시도합니다.';
  }

  Widget _statusTile(BuildContext context, _LayerRow r) {
    final (IconData icon, Color color, String tag) = _statusVisual(r.state);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          border: Border.all(color: color.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(r.icon, size: 22, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          r.label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(icon, size: 12, color: color),
                            const SizedBox(width: 4),
                            Text(
                              tag,
                              style: TextStyle(
                                fontSize: 11,
                                color: color,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    r.detail,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  (IconData, Color, String) _statusVisual(_LayerState s) {
    switch (s) {
      case _LayerState.ok:
        return (Icons.check_circle, AppColors.success, '자동 적용');
      case _LayerState.attention:
        return (Icons.error_outline, Colors.orange.shade800, '조치 필요');
      case _LayerState.blocked:
        return (Icons.block, AppColors.danger, '작동 안 함');
      case _LayerState.na:
        return (Icons.remove_circle_outline, AppColors.muted, '해당 없음');
    }
  }
}
