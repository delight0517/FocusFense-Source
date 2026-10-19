import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../services/safe_external_link_service.dart';

import '../models/ecosystem_scan_models.dart';
import '../screens/one_tap_block_screen.dart';
import '../services/blocking_ecosystem_scan_service.dart';
import '../services/blocking_ecosystem_status_launcher_service.dart';
import '../services/windows_default_apps_launcher.dart';
import '../theme/app_colors.dart';
import 'browser_install_safety_banners.dart';

/// Opens browser status **inside** the 홈 shell branch — sidebar stays visible.
Future<void> openBlockingEcosystemStatusScreen(
  BuildContext context, {
  bool mandatoryIntro = false,
}) async {
  final GoRouter router = GoRouter.of(context);
  if (mandatoryIntro) {
    router.go('/focus');
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  final String path =
      mandatoryIntro ? '/focus/browser-status?intro=1' : '/focus/browser-status';
  await router.push(path);
}

/// 가장 중요한 브라우저별 URL 차단 현황 — 진단 탭 밖에서도 열 수 있는 전용 화면.
class BlockingEcosystemStatusScreen extends StatefulWidget {
  const BlockingEcosystemStatusScreen({
    super.key,
    this.mandatoryIntro = false,
  });

  /// 첫 실행 시 뒤로가기 없이 확인 버튼으로만 닫기.
  final bool mandatoryIntro;

  @override
  State<BlockingEcosystemStatusScreen> createState() =>
      _BlockingEcosystemStatusScreenState();
}

class _BlockingEcosystemStatusScreenState
    extends State<BlockingEcosystemStatusScreen> {
  BlockingEcosystemReport? _report;
  bool _scanning = true;
  bool _introAcknowledged = false;
  String? _scanError;

  List<EcosystemTargetRow> _sortedTargets(BlockingEcosystemReport r) {
    final List<EcosystemTargetRow> copy = List<EcosystemTargetRow>.from(r.targets);
    copy.sort((EcosystemTargetRow a, EcosystemTargetRow b) {
      if (a.installed != b.installed) {
        return a.installed ? -1 : 1;
      }
      return a.displayName.compareTo(b.displayName);
    });
    return copy;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan({bool force = false}) async {
    final BlockingEcosystemReport? cached =
        await BlockingEcosystemScanService.instance.readDiskCache();
    if (cached != null && mounted) {
      setState(() {
        _report = cached;
        _scanning = false;
        _scanError = null;
      });
    } else if (mounted) {
      setState(() => _scanning = true);
    }
    try {
      final BlockingEcosystemReport r =
          await BlockingEcosystemScanService.instance.scan(force: force);
      if (!mounted) return;
      setState(() {
        _report = r;
        _scanError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanError = '$e';
      });
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _leaveMandatoryIntro() async {
    await BlockingEcosystemStatusLauncherService.instance.markIntroDismissed();
    if (!mounted) return;
    setState(() => _introAcknowledged = true);
    _popToHome();
  }

  void _popToHome() {
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/focus');
  }

  EcosystemScanLevel _overallLevel(BlockingEcosystemReport r) {
    final List<EcosystemTargetRow> installed = r.targets
        .where((EcosystemTargetRow t) => t.installed)
        .toList();
    if (installed.isEmpty) return EcosystemScanLevel.unavailable;
    if (installed.any((EcosystemTargetRow t) => !t.urlBlockUsable)) {
      if (installed.every((EcosystemTargetRow t) => !t.urlBlockUsable)) {
        return EcosystemScanLevel.off;
      }
      return EcosystemScanLevel.partial;
    }
    return EcosystemScanLevel.ready;
  }

  String _overallTitle(EcosystemScanLevel level) {
    switch (level) {
      case EcosystemScanLevel.ready:
        return '차단이 켜져 있어요';
      case EcosystemScanLevel.partial:
        return '일부만 적용됐어요';
      case EcosystemScanLevel.off:
        return '지금은 막히지 않아요';
      case EcosystemScanLevel.unavailable:
        return '확인할 브라우저가 없어요';
    }
  }

  IconData _browserIcon(String id) {
    switch (id) {
      case 'chrome':
        return Icons.language;
      case 'edge':
        return Icons.explore_outlined;
      case 'firefox':
        return Icons.local_fire_department_outlined;
      case 'whale':
        return Icons.waves_outlined;
      case 'brave':
        return Icons.shield_outlined;
      case 'vivaldi':
        return Icons.palette_outlined;
      case 'opera':
        return Icons.circle_outlined;
      case 'safari':
      case 'safari_ios':
        return Icons.phone_iphone;
      default:
        return Icons.web;
    }
  }

  Future<void> _openUri(String uri) async {
    final Uri? parsed = Uri.tryParse(uri);
    if (parsed == null) return;
    final bool ok = await SafeExternalLinkService.instance
        .open(parsed, context: mounted ? context : null);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('열 수 없습니다: $uri')),
      );
    }
  }

  Future<void> _copyReport() async {
    final BlockingEcosystemReport? r = _report;
    if (r == null) return;
    final StringBuffer sb = StringBuffer();
    sb.writeln('Focus Fense — 브라우저 차단 현황 ${r.buildLabel}');
    sb.writeln(r.summaryKo);
    if (r.defaultBrowser != null) {
      sb.writeln();
      sb.writeln('기본 브라우저: ${r.defaultBrowser!.displayName}');
      sb.writeln(r.defaultBrowser!.messageKo.replaceAll('**', ''));
    }
    for (final EcosystemTargetRow t in r.targets) {
      sb.writeln('${t.displayName}: ${t.level.badgeKo} — ${t.headline}');
    }
    await Clipboard.setData(ClipboardData(text: sb.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('현황을 클립보드에 복사했습니다.')),
    );
  }

  void _openOneTap() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const OneTapBlockScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final BlockingEcosystemReport? r = _report;
    final EcosystemScanLevel overall =
        r == null ? EcosystemScanLevel.unavailable : _overallLevel(r);
    final Color accent = overall.color(context);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (widget.mandatoryIntro && !_introAcknowledged) {
          unawaited(_leaveMandatoryIntro());
        } else {
          _popToHome();
        }
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: const Color(0xFFF4F7FB),
        foregroundColor: AppColors.ink,
        leading: IconButton(
          tooltip: widget.mandatoryIntro ? '메인으로' : '뒤로',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: widget.mandatoryIntro
              ? _leaveMandatoryIntro
              : _popToHome,
        ),
        title: Text(
          widget.mandatoryIntro ? '브라우저 차단 현황 (안내)' : '브라우저 차단 현황',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: <Widget>[
          if (!widget.mandatoryIntro) ...<Widget>[
            IconButton(
              tooltip: '다시 스캔',
              onPressed: _scanning ? null : () => _scan(force: true),
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: '복사',
              onPressed: r == null ? null : _copyReport,
              icon: const Icon(Icons.copy_all_outlined),
            ),
          ],
        ],
      ),
      body: _scanning && r == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    '브라우저 상태 불러오는 중…',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (widget.mandatoryIntro) ...<Widget>[
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _leaveMandatoryIntro,
                      child: const Text('나중에 — 메인으로'),
                    ),
                  ],
                ],
              ),
            )
          : r == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Colors.red.shade700,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '브라우저 차단 현황 스캔 실패',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _scanError ??
                              '캐시도 없습니다. 아래에서 다시 스캔해 주세요.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => _scan(force: true),
                          icon: const Icon(Icons.refresh),
                          label: const Text('다시 스캔'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _scan(force: true),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                    children: <Widget>[
                      if (widget.mandatoryIntro)
                        _IntroBanner(),
                      if (_scanError != null) ...<Widget>[
                        _ScanErrorBanner(
                          message: _scanError!,
                          onRetry: () => _scan(force: true),
                        ),
                        const SizedBox(height: 12),
                      ],
                      _HeroStatusCard(
                        level: overall,
                        title: _overallTitle(overall),
                        summary: r.summaryKo,
                        buildLabel: r.buildLabel,
                        accent: accent,
                      ),
                      if (r.killGuardActive) ...<Widget>[
                        const SizedBox(height: 12),
                        const _KillGuardBanner(),
                      ],
                      const SizedBox(height: 16),
                      _StatRow(
                        installed: r.installedCount,
                        urlUsable: r.urlBlockUsableCount,
                        rules: r.activeRuleCount,
                        adult: r.builtinAdultCount,
                      ),
                      if (r.defaultBrowser != null) ...<Widget>[
                        const SizedBox(height: 16),
                        _DefaultBrowserCard(
                          advisory: r.defaultBrowser!,
                          onOpenSettings: () =>
                              WindowsDefaultAppsLauncher.openDefaultAppsSettings(),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const BrowserSafetyActionRow(),
                      const SizedBox(height: 20),
                      ..._browserSections(r, _sortedTargets(r)),
                      if (r.features.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 24),
                        const _SectionTitle(
                          icon: Icons.verified_user_outlined,
                          title: '앱이 함께 지키는 것',
                          subtitle: '확장 삭제 방지 · 미보호 브라우저 종료 등',
                        ),
                        const SizedBox(height: 10),
                        ...r.features.map(
                          (EcosystemFeatureRow f) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _FeatureCard(row: f),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
      bottomNavigationBar: widget.mandatoryIntro
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _leaveMandatoryIntro,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('나중에'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _leaveMandatoryIntro,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(
                          _scanning ? '스캔 중…' : '확인 — 메인으로',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : r == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: widget.mandatoryIntro
                    ? const SizedBox.shrink()
                    : Row(
                        children: <Widget>[
                          if (overall != EcosystemScanLevel.ready) ...<Widget>[
                            Expanded(
                              flex: 2,
                              child: FilledButton.icon(
                                onPressed: _openOneTap,
                                icon: const Icon(Icons.bolt),
                                label: const Text('원탭 차단 적용'),
                                style: FilledButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  backgroundColor: AppColors.warning,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed:
                                  _scanning ? null : () => _scan(force: true),
                              icon: const Icon(Icons.radar),
                              label: const Text('다시 스캔'),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
    ),
    );
  }

  List<Widget> _browserSections(
    BlockingEcosystemReport r,
    List<EcosystemTargetRow> sorted,
  ) {
    final List<EcosystemTargetRow> installed =
        sorted.where((EcosystemTargetRow t) => t.installed).toList();
    final List<EcosystemTargetRow> notInstalled =
        sorted.where((EcosystemTargetRow t) => !t.installed).toList();

    return <Widget>[
      _SectionTitle(
        icon: Icons.laptop_mac,
        title: '설치된 브라우저',
        subtitle: r.killGuardActive
            ? '빨간 「브라우저 차단」= URL이 안 막혀서 앱 자체를 강제 종료합니다.'
            : 'URL 차단이 꺼진 브라우저는 위험합니다. 설정→진단에서 kill guard를 켜세요.',
      ),
      const SizedBox(height: 10),
      _BrowserGrid(
        rows: installed,
        iconFor: _browserIcon,
        onOpenUri: _openUri,
        killGuardActive: r.killGuardActive,
      ),
      if (notInstalled.isNotEmpty) ...<Widget>[
        const SizedBox(height: 22),
        const _SectionTitle(
          icon: Icons.download_outlined,
          title: '아직 없는 브라우저',
          subtitle: '설치하면 앱이 자동으로 정책·확장을 줄 수 있는지 솔직히 표시합니다.',
        ),
        const SizedBox(height: 10),
        _BrowserGrid(
          rows: notInstalled,
          iconFor: _browserIcon,
          onOpenUri: _openUri,
          killGuardActive: r.killGuardActive,
        ),
      ],
    ];
  }
}

class _IntroBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.indigo.shade50,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.indigo.shade200),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.visibility, color: Colors.indigo.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Focus Fense를 처음 켰습니다.\n'
                '아래에서 어떤 브라우저가 막히고, 설치하면 무엇이 되는지 먼저 확인하세요.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: Colors.indigo.shade900,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanErrorBanner extends StatelessWidget {
  const _ScanErrorBanner({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade300),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade900),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '최신 스캔 실패 — 아래는 이전/부분 결과입니다',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Colors.orange.shade900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange.shade900,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('다시'),
          ),
        ],
      ),
    );
  }
}

class _KillGuardBanner extends StatelessWidget {
  const _KillGuardBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.shade300, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.block, color: Colors.red.shade800, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'URL 차단이 없으면 → 브라우저 자체 종료',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: Colors.red.shade900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Chrome·Edge·Firefox·Brave·Whale 등에서 정책이 꺼져 있으면 '
                  '열자마자 프로세스가 강제 종료됩니다. 사이트만 막는 게 아니라 앱 자체를 막습니다.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: Colors.red.shade800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowserGrid extends StatelessWidget {
  const _BrowserGrid({
    required this.rows,
    required this.iconFor,
    required this.onOpenUri,
    required this.killGuardActive,
  });

  final List<EcosystemTargetRow> rows;
  final IconData Function(String id) iconFor;
  final Future<void> Function(String uri) onOpenUri;
  final bool killGuardActive;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text(
        '해당 없음',
        style: TextStyle(color: Colors.grey.shade600),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= 720;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: rows
              .map(
                (EcosystemTargetRow t) => SizedBox(
                  width: wide ? (c.maxWidth - 12) / 2 : c.maxWidth,
                  child: _BrowserStatusCard(
                    row: t,
                    icon: iconFor(t.id),
                    onOpenUri: onOpenUri,
                    killGuardActive: killGuardActive,
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _HeroStatusCard extends StatelessWidget {
  const _HeroStatusCard({
    required this.level,
    required this.title,
    required this.summary,
    required this.buildLabel,
    required this.accent,
  });

  final EcosystemScanLevel level;
  final String title;
  final String summary;
  final String buildLabel;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            accent.withValues(alpha: 0.14),
            Colors.white,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: accent.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: accent.withValues(alpha: 0.2),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Icon(level.icon, color: accent, size: 32),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: AppColors.ink,
                      ),
                    ),
                    Text(
                      buildLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            summary,
            style: const TextStyle(
              fontSize: 15,
              height: 1.5,
              color: AppColors.ink,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.installed,
    required this.urlUsable,
    required this.rules,
    required this.adult,
  });

  final int installed;
  final int urlUsable;
  final int rules;
  final int adult;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(child: _StatPill(label: '설치됨', value: '$installed', icon: Icons.apps)),
        const SizedBox(width: 8),
        Expanded(child: _StatPill(label: '사용 가능', value: '$urlUsable', icon: Icons.check_circle_outline)),
        const SizedBox(width: 8),
        Expanded(child: _StatPill(label: '규칙', value: '$rules', icon: Icons.rule_folder_outlined)),
        const SizedBox(width: 8),
        Expanded(child: _StatPill(label: '음란물', value: '$adult', icon: Icons.block_flipped)),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 18, color: AppColors.accent),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: AppColors.ink,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, color: AppColors.accent, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.ink,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DefaultBrowserCard extends StatelessWidget {
  const _DefaultBrowserCard({
    required this.advisory,
    required this.onOpenSettings,
  });

  final DefaultBrowserAdvisory advisory;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final Color c = advisory.isProblem
        ? Colors.orange.shade800
        : (advisory.blockActive ? Colors.green.shade800 : Colors.blue.shade800);
    final Color bg = advisory.isProblem
        ? Colors.orange.shade50
        : (advisory.blockActive ? Colors.green.shade50 : Colors.blue.shade50);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                advisory.isProblem
                    ? Icons.warning_amber_rounded
                    : Icons.home_outlined,
                color: c,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'PC 기본 브라우저: ${advisory.displayName}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: c,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            advisory.messageKo.replaceAll('**', ''),
            style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey.shade800),
          ),
          if (advisory.suggestSwitchTo != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '권장: ${advisory.suggestSwitchTo}(으)로 기본 앱 변경',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: c,
              ),
            ),
          ],
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Windows 기본 브라우저 설정 열기'),
          ),
        ],
      ),
    );
  }
}

class _PluginReadinessChip extends StatelessWidget {
  const _PluginReadinessChip({
    required this.ready,
    required this.label,
  });

  final bool ready;
  final String label;

  @override
  Widget build(BuildContext context) {
    final Color c = ready ? Colors.green.shade800 : Colors.orange.shade900;
    final Color bg = ready ? Colors.green.shade50 : Colors.orange.shade50;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(ready ? Icons.extension : Icons.hourglass_empty, color: c, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: c,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KillRowBanner extends StatelessWidget {
  const _KillRowBanner({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 8 : 12,
      ),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        border: Border.all(color: Colors.red.shade400, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.block, color: Colors.red.shade800, size: compact ? 18 : 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              compact
                  ? '보호 없음 → 실행 시 앱이 종료'
                  : '차단·확장 보호가 없습니다.\n'
                      '이 브라우저를 열면 앱이 자동으로 종료합니다.',
              style: TextStyle(
                fontSize: compact ? 12 : 13,
                fontWeight: FontWeight.w800,
                height: 1.35,
                color: Colors.red.shade900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _shortKo(String text, {int max = 90}) {
  final String t = text.trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max - 1)}…';
}

class _BrowserStatusCard extends StatelessWidget {
  const _BrowserStatusCard({
    required this.row,
    required this.icon,
    required this.onOpenUri,
    required this.killGuardActive,
  });

  final EcosystemTargetRow row;
  final IconData icon;
  final Future<void> Function(String uri) onOpenUri;
  final bool killGuardActive;

  bool get _browserKillMode =>
      row.installed && killGuardActive && row.killOnNoBlock;

  Color _accent(BuildContext context) {
    if (_browserKillMode) return Colors.red.shade800;
    if (!row.installed) return Colors.blueGrey.shade700;
    return row.level.color(context);
  }

  String _badge() {
    if (!row.installed) return '미설치';
    if (_browserKillMode) return '실행 차단';
    if (row.urlBlockUsable) return '사용 가능';
    return '차단 미적용';
  }

  @override
  Widget build(BuildContext context) {
    final Color c = _accent(context);

    if (!row.installed) {
      return _buildUninstalledCard(c);
    }
    return _buildInstalledCard(context, c);
  }

  Widget _buildUninstalledCard(Color c) {
    final String? pluginLabel = row.pluginSupportLabel;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blueGrey.shade200, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _cardHeader(c),
          if (pluginLabel != null) ...<Widget>[
            const SizedBox(height: 12),
            _PluginReadinessChip(
              ready: row.pluginSupportReady,
              label: pluginLabel,
            ),
          ],
          const SizedBox(height: 10),
          Text(
            row.headline,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade800,
            ),
          ),
          if (row.detailLines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _shortKo(row.detailLines.first, max: 120),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: Colors.grey.shade600,
                ),
              ),
            ),
          if (row.installUrl != null) ...<Widget>[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => onOpenUri(row.installUrl!),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('브라우저 설치 페이지'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInstalledCard(BuildContext context, Color c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _browserKillMode
              ? Colors.red.shade400
              : c.withValues(alpha: 0.35),
          width: _browserKillMode ? 2 : 1.5,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: (_browserKillMode ? Colors.red : Colors.black)
                .withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _cardHeader(c),
          if (_browserKillMode) ...<Widget>[
            const SizedBox(height: 12),
            const _KillRowBanner(compact: true),
          ],
          const SizedBox(height: 10),
          Text(
            row.headline,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: _browserKillMode ? Colors.red.shade900 : AppColors.ink,
              height: 1.3,
            ),
          ),
          for (final String line in row.detailLines.take(2))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _shortKo(line),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cardHeader(Color c) {
    return Row(
      children: <Widget>[
        CircleAvatar(
          radius: 22,
          backgroundColor: c.withValues(alpha: 0.12),
          child: Icon(icon, color: c, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                row.displayName,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: AppColors.ink,
                ),
              ),
              if (row.running)
                Text(
                  '지금 실행 중',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _badge(),
            style: TextStyle(
              color: c,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.row});

  final EcosystemFeatureRow row;

  @override
  Widget build(BuildContext context) {
    final Color c = row.level.color(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: <Widget>[
          Icon(row.level.icon, color: c, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  row.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                Text(
                  row.summary,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            row.level.badgeKo,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}
