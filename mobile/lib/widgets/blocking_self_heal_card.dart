import 'dart:io';

import 'package:flutter/material.dart';

import '../services/blocking_self_heal_agent_service.dart';
import '../services/tri_browser_self_heal_service.dart';
import '../theme/app_colors.dart';

/// Diagnostics: Chrome · Edge · Firefox autonomous diagnose + self-heal.
class BlockingSelfHealCard extends StatefulWidget {
  const BlockingSelfHealCard({super.key});

  @override
  State<BlockingSelfHealCard> createState() => _BlockingSelfHealCardState();
}

class _BlockingSelfHealCardState extends State<BlockingSelfHealCard> {
  bool _running = false;

  @override
  void initState() {
    super.initState();
    BlockingSelfHealAgentService.instance.latest.addListener(_onUpdate);
    TriBrowserSelfHealService.instance.latest.addListener(_onUpdate);
  }

  @override
  void dispose() {
    BlockingSelfHealAgentService.instance.latest.removeListener(_onUpdate);
    TriBrowserSelfHealService.instance.latest.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _runNow() async {
    setState(() => _running = true);
    await TriBrowserSelfHealService.instance.runCycle(
      reason: 'user',
      userInitiated: true,
      repair: true,
    );
    await BlockingSelfHealAgentService.instance.runCycle(
      reason: 'user',
      userInitiated: true,
    );
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return const SizedBox.shrink();
    }
    final TriBrowserHealReport? tri =
        TriBrowserSelfHealService.instance.latest.value;
    final SelfHealReport? heal =
        BlockingSelfHealAgentService.instance.latest.value;
    final String verdict = tri?.verdict ?? heal?.verdict ?? '부팅 후 자동 점검 예정';
    final bool ok = tri?.ok ?? heal?.ok ?? false;
    final Color tone = ok ? AppColors.success : AppColors.warning;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.smart_toy_outlined, color: tone, size: 22),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Chrome · Edge · Firefox — 자동 진단 · 복구',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _running ? null : _runNow,
                  child: Text(_running ? '점검 중…' : '지금 점검'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '앱이 스스로 차단 상태를 확인하고 고칩니다. '
              '문제가 있으면 확장·PAC·보호 Chrome 전환을 자동 처리합니다 (유저 조작 없음 · 20분마다 재점검).',
              style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
            ),
            const SizedBox(height: 10),
            Text(verdict, style: TextStyle(color: tone, fontWeight: FontWeight.w500)),
            if (tri != null && tri.browsers.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              ...tri.browsers.map(_browserRow),
            ],
          ],
        ),
      ),
    );
  }

  Widget _browserRow(BrowserHealthRow row) {
    final Color c = row.skipped
        ? AppColors.muted
        : row.ok
            ? AppColors.success
            : AppColors.warning;
    final IconData icon = row.ok || row.skipped
        ? Icons.check_circle_outline
        : Icons.error_outline;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${row.label}: ${row.detail}',
              style: TextStyle(fontSize: 11, color: c, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
