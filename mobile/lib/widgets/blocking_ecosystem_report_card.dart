import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/safe_external_link_service.dart';

import '../models/ecosystem_scan_models.dart';
import '../services/blocking_ecosystem_scan_service.dart';
import '../theme/app_colors.dart';
import 'blocking_ecosystem_status_screen.dart';

/// Settings → 진단: **친절한** 브라우저·기능별 차단 현황 (업데이트마다 자동 스캔).
class BlockingEcosystemReportCard extends StatefulWidget {
  const BlockingEcosystemReportCard({super.key});

  @override
  State<BlockingEcosystemReportCard> createState() =>
      _BlockingEcosystemReportCardState();
}

class _BlockingEcosystemReportCardState extends State<BlockingEcosystemReportCard> {
  BlockingEcosystemReport? _report;
  bool _scanning = false;
  bool _expanded = true;

  @override
  void initState() {
    super.initState();
    unawaited(_scan(postUpdate: true));
  }

  Future<void> _scan({bool force = false, bool postUpdate = false}) async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final BlockingEcosystemReport r =
          await BlockingEcosystemScanService.instance.scan(
        force: force,
        postUpdate: postUpdate,
      );
      if (!mounted) return;
      setState(() => _report = r);
    } finally {
      if (mounted) setState(() => _scanning = false);
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
    sb.writeln('Focus Fense — 차단 현황 ${r.buildLabel}');
    sb.writeln(r.summaryKo);
    if (r.defaultBrowser != null) {
      sb.writeln();
      sb.writeln('── PC 기본 브라우저 ──');
      sb.writeln(_plainKo(r.defaultBrowser!.messageKo));
    }
    sb.writeln();
    sb.writeln('── 브라우저 / 앱 ──');
    for (final EcosystemTargetRow t in r.targets) {
      sb.writeln('${t.displayName} → ${t.level.badgeKo}: ${t.headline}');
      for (final String line in t.detailLines) {
        sb.writeln('  · $line');
      }
    }
    sb.writeln();
    sb.writeln('── 보호 기능 ──');
    for (final EcosystemFeatureRow f in r.features) {
      sb.writeln('${f.title} → ${f.level.badgeKo}: ${f.summary}');
    }
    await Clipboard.setData(ClipboardData(text: sb.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('차단 현황을 클립보드에 복사했습니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final BlockingEcosystemReport? r = _report;
    final ThemeData theme = Theme.of(context);

    return Card(
      elevation: 3,
      color: AppColors.accent.withValues(alpha: 0.07),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.travel_explore, color: AppColors.accent, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        '차단 현황 스캔 (브라우저 · 기능 안내)',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      if (r != null)
                        Text(
                          '${r.buildLabel} · ${r.platformLabel}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'Menlo',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_scanning)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...<Widget>[
                  IconButton(
                    tooltip: '밝은 전체 화면',
                    onPressed: r == null
                        ? null
                        : () => openBlockingEcosystemStatusScreen(context),
                    icon: const Icon(Icons.open_in_full, size: 22),
                  ),
                  IconButton(
                    tooltip: '다시 스캔',
                    onPressed: () => _scan(force: true),
                    icon: const Icon(Icons.refresh, size: 22),
                  ),
                  IconButton(
                    tooltip: '복사',
                    onPressed: r == null ? null : _copyReport,
                    icon: const Icon(Icons.copy_all_outlined, size: 20),
                  ),
                ],
              ],
            ),
            if (r?.isPostUpdateScan == true && !_scanning) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Text(
                  '🆕 ${r!.buildLabel} 업데이트 후 자동 스캔 완료',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.blue.shade900,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (r != null) ...<Widget>[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => openBlockingEcosystemStatusScreen(context),
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  label: const Text('밝은 현황판 전체 화면으로 보기'),
                ),
              ),
              const SizedBox(height: 10),
              if (r.defaultBrowser != null) ...<Widget>[
                _defaultBrowserBanner(r.defaultBrowser!),
                const SizedBox(height: 10),
              ],
              Text(
                r.summaryKo,
                style: const TextStyle(fontSize: 13.5, height: 1.45),
              ),
              const SizedBox(height: 6),
              Text(
                '설치된 브라우저 ${r.installedCount}개 · URL 차단 OK ${r.readyCount}개 · '
                '내장 음란물 ${r.builtinAdultCount}개 · 활성 규칙 ${r.activeRuleCount}건',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                      ),
                      Text(
                        _expanded ? '목록 접기' : '브라우저 · 기능 목록 펼치기',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded) ...<Widget>[
                const SizedBox(height: 8),
                const Text(
                  '어디서 URL 차단이 되나요?',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const SizedBox(height: 6),
                ...r.targets.map(_targetTile),
                const SizedBox(height: 12),
                const Text(
                  '앱이 켜져 있는 동안 지키는 것',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const SizedBox(height: 6),
                ...r.features.map(_featureTile),
              ],
            ] else if (!_scanning)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('스캔 준비 중…'),
              ),
          ],
        ),
      ),
    );
  }

  String _plainKo(String text) => text.replaceAll('**', '');

  Widget _defaultBrowserBanner(DefaultBrowserAdvisory d) {
    final Color bg = d.isProblem
        ? Colors.orange.shade50
        : (d.blockActive ? Colors.green.shade50 : Colors.blue.shade50);
    final Color border = d.isProblem
        ? Colors.orange.shade300
        : (d.blockActive ? Colors.green.shade300 : Colors.blue.shade200);
    final Color fg = d.isProblem
        ? Colors.orange.shade900
        : (d.blockActive ? Colors.green.shade900 : Colors.blue.shade900);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                d.isProblem
                    ? Icons.warning_amber_rounded
                    : (d.blockActive
                        ? Icons.check_circle_outline
                        : Icons.language),
                color: fg,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'PC 기본 브라우저: ${d.displayName}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _plainKo(d.messageKo),
            style: TextStyle(fontSize: 12.5, height: 1.4, color: fg),
          ),
          if (d.suggestSwitchTo != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              '권장: 기본 앱을 ${d.suggestSwitchTo}(으)로 변경',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              if (d.settingsUri != null)
                TextButton.icon(
                  onPressed: () => _openUri(d.settingsUri!),
                  icon: const Icon(Icons.settings, size: 16),
                  label: const Text('기본 앱 설정 열기'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: fg,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _targetTile(EcosystemTargetRow t) {
    final Color c = t.level.color(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(t.level.icon, color: c, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      t.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        t.level.badgeKo,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: c,
                        ),
                      ),
                    ),
                    if (t.running) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        '실행 중',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  t.headline,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                for (final String line in t.detailLines)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '· $line',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    if (!t.installed && t.installUrl != null)
                      TextButton.icon(
                        onPressed: () => _openUri(t.installUrl!),
                        icon: const Icon(Icons.download_outlined, size: 16),
                        label: const Text('설치 페이지'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    if (t.installed && t.uninstallHintKo != null) ...<Widget>[
                      TextButton.icon(
                        onPressed: () => _openUri('ms-settings:appsfeatures'),
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('앱 제거 설정'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      Tooltip(
                        message: t.uninstallHintKo!,
                        child: Text(
                          t.uninstallHintKo!,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _featureTile(EcosystemFeatureRow f) {
    final Color c = f.level.color(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(f.level.icon, color: c, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  f.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  f.summary,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
