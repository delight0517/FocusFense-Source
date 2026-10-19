import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/ecosystem_scan_models.dart';
import '../services/build_identity_service.dart';
import '../services/blocking_ecosystem_scan_service.dart';
import '../theme/app_colors.dart';
import '../screens/browser_extensions_screen.dart';
import 'blocking_ecosystem_status_screen.dart';

/// 앱 상단 고정 스트립 — 진단 메뉴 없이도 브라우저 차단 현황을 열 수 있게 함.
class BlockingEcosystemStatusStrip extends StatefulWidget {
  const BlockingEcosystemStatusStrip({super.key});

  @override
  State<BlockingEcosystemStatusStrip> createState() =>
      _BlockingEcosystemStatusStripState();
}

class _BlockingEcosystemStatusStripState
    extends State<BlockingEcosystemStatusStrip> {
  BlockingEcosystemReport? _report;
  bool _loading = true;
  String? _loadError;
  String? _runningBuildLabel;

  @override
  void initState() {
    super.initState();
    BlockingEcosystemScanService.instance.revision.addListener(_onScanRevision);
    unawaited(_loadRunningBuildLabel());
    unawaited(_load());
  }

  @override
  void dispose() {
    BlockingEcosystemScanService.instance.revision.removeListener(
      _onScanRevision,
    );
    super.dispose();
  }

  void _onScanRevision() {
    if (!mounted) return;
    unawaited(_load(force: true));
  }

  Future<void> _loadRunningBuildLabel() async {
    try {
      final BuildIdentity id = await BuildIdentityService.instance.current();
      if (!mounted) return;
      setState(() => _runningBuildLabel = 'v${id.version}+${id.buildNumber}');
    } catch (_) {
      // Non-critical. The scan summary can still render its cached label.
    }
  }

  String _summaryFor(BlockingEcosystemReport r) {
    final String? label = _runningBuildLabel;
    if (label == null || label.isEmpty) return r.summaryKo;
    return r.summaryKo.replaceFirst(
      RegExp(r'^v[0-9][^\s]*\s*·\s*'),
      '$label · ',
    );
  }

  Future<void> _load({bool force = false}) async {
    try {
      if (!force) {
        final BlockingEcosystemReport? cached =
            await BlockingEcosystemScanService.instance.readDiskCache();
        if (cached != null && mounted) {
          setState(() {
            _report = cached;
            _loading = false;
          });
        }
      }
      final BlockingEcosystemReport r = await BlockingEcosystemScanService
          .instance
          .scan(force: force);
      if (!mounted) return;
      setState(() {
        _report = r;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '$e';
        });
      }
    }
  }

  void _openDetail() {
    unawaited(
      openBlockingEcosystemStatusScreen(
        context,
      ).then((_) => _load(force: true)),
    );
  }

  Future<void> _openSetup() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const BrowserExtensionsScreen()),
    );
    if (mounted) await _load(force: true);
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return const SizedBox.shrink();
    }

    if (_loading && _report == null) {
      return Material(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: <Widget>[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                '브라우저 차단 현황 확인 중…',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
            ],
          ),
        ),
      );
    }

    final BlockingEcosystemReport? r = _report;
    if (r == null) {
      if (_loadError != null) {
        return Material(
          color: Colors.red.shade50,
          child: InkWell(
            onTap: () => _load(force: true),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.error_outline,
                    color: Colors.red.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '브라우저 차단 현황 스캔 실패 — 탭하여 다시 시도',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.red.shade900,
                      ),
                    ),
                  ),
                  const Icon(Icons.refresh, size: 18),
                ],
              ),
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    final BlockingSetupNotice notice = BlockingSetupNotice.fromReport(r);
    final Color accent = notice.isReady
        ? Colors.green.shade700
        : Colors.orange.shade800;

    return Material(
      color: Colors.white,
      elevation: 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: accent.withValues(alpha: 0.25)),
          ),
          gradient: LinearGradient(
            colors: <Color>[accent.withValues(alpha: 0.08), Colors.white],
          ),
        ),
        child: InkWell(
          onTap: _openDetail,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    notice.isReady
                        ? Icons.shield_outlined
                        : Icons.warning_amber_rounded,
                    color: accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        notice.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: AppColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        notice.isReady ? _summaryFor(r) : notice.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!notice.isReady) ...<Widget>[
                  FilledButton.icon(
                    onPressed: _openSetup,
                    icon: const Icon(
                      Icons.download_for_offline_outlined,
                      size: 17,
                    ),
                    label: const Text('설정 마치기'),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                TextButton(
                  onPressed: _openDetail,
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                  ),
                  child: Text(notice.isReady ? '자세히' : '브라우저별 상태'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 홈 탭용 컴팩트 카드 — 탭 한 번으로 전체 화면 현황판.
class BlockingEcosystemHomeCard extends StatelessWidget {
  const BlockingEcosystemHomeCard({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return const SizedBox.shrink();
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => openBlockingEcosystemStatusScreen(context),
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: <Color>[
                AppColors.accent.withValues(alpha: 0.12),
                Colors.white,
              ],
            ),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.dashboard_customize_outlined,
                  color: AppColors.accent,
                  size: 32,
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '브라우저 차단 현황판',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: AppColors.ink,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Chrome · Edge · Firefox 등 설치된 브라우저마다 '
                        '지금 URL이 막히는지 밝은 화면으로 확인합니다.',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
