import 'package:flutter/material.dart';

import '../services/windows_background_components_service.dart';
import '../theme/app_colors.dart';

/// "백그라운드 항목 안내" — explains every Windows scheduled task / autostart
/// entry Focus Fense registers, so a stray PowerShell window never reads as a
/// virus. Known items are badged 정상; orphans from old builds can be removed.
class BackgroundComponentsScreen extends StatefulWidget {
  const BackgroundComponentsScreen({super.key});

  @override
  State<BackgroundComponentsScreen> createState() =>
      _BackgroundComponentsScreenState();
}

class _BackgroundComponentsScreenState
    extends State<BackgroundComponentsScreen> {
  List<BgComponent>? _items;
  bool _loading = true;
  bool _cleaning = false;
  String? _banner;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _loading = true);
    final List<BgComponent> items =
        await WindowsBackgroundComponentsService.instance.scan();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _cleanup() async {
    final List<BgComponent> items = _items ?? <BgComponent>[];
    final List<BgComponent> removable =
        items.where((BgComponent c) => c.isRemovable).toList();
    if (removable.isEmpty) return;

    setState(() {
      _cleaning = true;
      _banner = null;
    });
    final BgCleanupResult res = await WindowsBackgroundComponentsService.instance
        .removeOrphans(removable);
    if (!mounted) return;

    final StringBuffer msg = StringBuffer();
    if (res.removed.isNotEmpty) {
      msg.write('${res.removed.length}개 항목을 제거했습니다.');
    }
    if (res.needsAdmin.isNotEmpty) {
      if (msg.isNotEmpty) msg.write(' ');
      msg.write('${res.needsAdmin.length}개는 관리자 권한이 필요합니다 — '
          '다음에 차단을 적용(UAC 승인)할 때 자동으로 정리됩니다.');
    }
    if (res.failed.isNotEmpty) {
      if (msg.isNotEmpty) msg.write(' ');
      msg.write('${res.failed.length}개는 제거에 실패했습니다.');
    }

    setState(() {
      _cleaning = false;
      _banner = msg.toString();
    });
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final List<BgComponent> items = _items ?? <BgComponent>[];
    final List<BgComponent> present =
        items.where((BgComponent c) => c.present).toList();
    final int removableCount =
        present.where((BgComponent c) => c.isRemovable).length;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('백그라운드 항목 안내'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: <Widget>[
                _intro(),
                const SizedBox(height: 16),
                if (_banner != null) ...<Widget>[
                  _bannerBox(_banner!),
                  const SizedBox(height: 12),
                ],
                if (removableCount > 0) ...<Widget>[
                  _cleanupCard(removableCount),
                  const SizedBox(height: 16),
                ],
                ...present.map(_componentCard),
                if (present.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Text(
                        '등록된 백그라운드 항목이 없습니다.',
                        style: TextStyle(color: AppColors.muted),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: _loading ? null : _scan,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('다시 검사'),
                ),
              ],
            ),
    );
  }

  Widget _intro() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withOpacity(0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.verified_user_outlined,
                  color: AppColors.accent, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '이 항목들은 Focus Fense가 등록한 정상 구성요소입니다',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '차단이 꺼지거나 우회되지 않도록 Windows 작업 스케줄러·자동 시작에 '
            '등록된 항목입니다. 대부분 화면에 보이지 않게 숨겨서 실행됩니다. '
            '간혹 PowerShell 창이 잠깐 떴다면, 아래에서 "불필요" 표시된 옛 항목 '
            '때문일 수 있으니 정리할 수 있습니다.',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bannerBox(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.success.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.success.withOpacity(0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(color: AppColors.ink, fontSize: 13, height: 1.45),
      ),
    );
  }

  Widget _cleanupCard(int count) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warning.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.cleaning_services_outlined,
                  color: AppColors.warning, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '정리 가능한 옛 항목 $count개',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '예전 버전이 남긴 항목입니다. 일부는 PowerShell 창을 띄워 작업을 '
            '방해할 수 있습니다. 제거해도 차단 기능에는 영향이 없습니다.',
            style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _cleaning ? null : _cleanup,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.warning,
                foregroundColor: Colors.white,
              ),
              icon: _cleaning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(_cleaning ? '정리 중…' : '옛 항목 정리'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _componentCard(BgComponent c) {
    final ({Color color, String label, IconData icon}) badge = _badgeFor(c);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  c.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badge.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(badge.icon, size: 12, color: badge.color),
                    const SizedBox(width: 4),
                    Text(
                      badge.label,
                      style: TextStyle(
                        color: badge.color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            c.purpose,
            style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
          ),
          if (c.showsWindow) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Icon(Icons.warning_amber_rounded,
                    size: 14, color: AppColors.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '이 항목이 화면에 PowerShell 창을 띄우는 원인입니다.',
                    style: TextStyle(
                      color: AppColors.warning,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            c.kind == BgComponentKind.runKey
                ? '유형: 로그인 자동 시작 · ${c.id}'
                : '유형: 예약 작업 · ${c.id}${c.disabled ? ' (사용 안 함)' : ''}',
            style: TextStyle(
              color: AppColors.muted.withOpacity(0.7),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  ({Color color, String label, IconData icon}) _badgeFor(BgComponent c) {
    switch (c.classification) {
      case BgComponentClass.essential:
        return (
          color: AppColors.success,
          label: '정상 · 필수',
          icon: Icons.check_circle_outline
        );
      case BgComponentClass.optional:
        return (
          color: AppColors.accent,
          label: '정상',
          icon: Icons.check_circle_outline
        );
      case BgComponentClass.orphan:
        return (
          color: AppColors.warning,
          label: '불필요',
          icon: Icons.cleaning_services_outlined
        );
      case BgComponentClass.unknown:
        return (
          color: AppColors.muted,
          label: '확인 필요',
          icon: Icons.help_outline
        );
    }
  }
}
