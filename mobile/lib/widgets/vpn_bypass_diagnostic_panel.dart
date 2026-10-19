import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/vpn_bypass_diagnostic_models.dart';
import '../services/chrome_dns_probe_service.dart';
import '../services/extension_rules_builder.dart';
import '../services/mac_system_block_service.dart';
import '../services/windows_apply_status_service.dart';
import 'apply_activation_dialog.dart';
import '../screens/vpn_bypass_fix_wizard_screen.dart';
import '../services/vpn_bypass_diagnostic_service.dart';
import '../theme/app_colors.dart';

/// Embeddable 4-step bypass diagnostic (settings tab or full screen).
class VpnBypassDiagnosticPanel extends StatefulWidget {
  const VpnBypassDiagnosticPanel({
    super.key,
    this.initialHost,
    this.compact = false,
  });

  final String? initialHost;
  final bool compact;

  @override
  State<VpnBypassDiagnosticPanel> createState() => _VpnBypassDiagnosticPanelState();
}

class _VpnBypassDiagnosticPanelState extends State<VpnBypassDiagnosticPanel> {
  final TextEditingController _hostCtrl = TextEditingController();
  bool _running = false;
  bool _fixing = false;
  VpnBypassDiagnosticReport? _report;

  @override
  void initState() {
    super.initState();
    _hostCtrl.text = widget.initialHost?.trim().isNotEmpty == true
        ? widget.initialHost!.trim()
        : kDiagnosticBlockSentinelHost;
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _report = null;
    });
    try {
      final VpnBypassDiagnosticReport r =
          await VpnBypassDiagnosticService.instance.run(testHost: _hostCtrl.text);
      if (mounted) setState(() => _report = r);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _applyFix() async {
    setState(() => _fixing = true);
    try {
      final String host = MacSystemBlockService.canonicalHost(_hostCtrl.text);
      if (!mounted) return;
      await showApplyActivationDialog(
        context,
        runApply: (onPhase) => WindowsApplyStatusService.instance.applyAndVerify(
          verifyHost: host.isEmpty ? null : host,
          onPhase: onPhase,
        ),
      );
      if (!mounted) return;
      await Future<void>.delayed(const Duration(seconds: 3));
      if (mounted) await _run();
    } finally {
      if (mounted) setState(() => _fixing = false);
    }
  }

  Future<void> _copyReport() async {
    final VpnBypassDiagnosticReport? r = _report;
    if (r == null) return;
    final StringBuffer buf = StringBuffer()
      ..writeln('Focus Fense — 브라우저 우회 자가 진단')
      ..writeln('대상: ${r.probeHost}')
      ..writeln('소요: ${r.elapsedMs}ms')
      ..writeln('요약: ${r.summary}')
      ..writeln();
    for (final VpnBypassDiagnosticStep s in r.steps) {
      buf.writeln('[${s.ok ? "OK" : "ISSUE"}] ${s.title}');
      buf.writeln(s.detail);
      if (s.remedy != null) buf.writeln('처방: ${s.remedy}');
      buf.writeln();
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('진단 결과를 클립보드에 복사했습니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VpnBypassDiagnosticReport? rep = _report;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!widget.compact)
          Text(
            'IPv6 · DoH · QUIC · DNS 어댑터 + 숨겨진 우회 10항목을 검사합니다.',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.35),
          ),
        if (!widget.compact) const SizedBox(height: 10),
        TextField(
          controller: _hostCtrl,
          decoration: const InputDecoration(
            labelText: '테스트 사이트',
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _running || _fixing ? null : _run,
              icon: _running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(_running ? '진단 중…' : '진단 시작'),
            ),
            if (rep != null && rep.hasIssues)
              FilledButton.tonalIcon(
                onPressed: _running
                    ? null
                    : () {
                        Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => VpnBypassFixWizardScreen(report: rep),
                          ),
                        );
                      },
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                label: const Text('단계별 가이드'),
              ),
            FilledButton.tonalIcon(
              onPressed: _running || _fixing ? null : _applyFix,
              icon: _fixing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.healing, size: 18),
              label: Text(_fixing ? '적용 중…' : 'UAC 한 번에 적용'),
            ),
            if (rep != null)
              OutlinedButton.icon(
                onPressed: _copyReport,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('복사'),
              ),
            OutlinedButton(
              onPressed: () async {
                await ChromeDnsProbeService.instance.openSecureDnsSettings();
              },
              child: const Text('Chrome 보안 DNS'),
            ),
            OutlinedButton(
              onPressed: () async {
                await ChromeDnsProbeService.instance.openChromeDnsHostCache();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      '「Clear host cache」누른 뒤 Chrome을 완전히 종료하고 다시 실행하세요',
                    ),
                  ),
                );
              },
              child: const Text('Chrome DNS 캐시'),
            ),
          ],
        ),
        if (rep != null) ...<Widget>[
          const SizedBox(height: 14),
          _summaryCard(context, rep),
          const SizedBox(height: 8),
          ...rep.steps.map((VpnBypassDiagnosticStep s) => _stepTile(context, s)),
        ],
      ],
    );
  }

  Widget _summaryCard(BuildContext context, VpnBypassDiagnosticReport rep) {
    final Color tone = rep.hasIssues ? AppColors.warning : AppColors.success;
    return Card(
      color: tone.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              rep.hasIssues ? '조치 필요' : '흔한 우회 원인 없음',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 6),
            Text(rep.summary, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _stepTile(BuildContext context, VpnBypassDiagnosticStep s) {
    final Color c = s.ok ? AppColors.success : AppColors.danger;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(s.ok ? Icons.check_circle_outline : Icons.error_outline, color: c, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(s.title, style: Theme.of(context).textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              s.detail,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'Menlo',
                    fontSize: 10,
                    height: 1.35,
                  ),
            ),
            if (s.remedy != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                s.remedy!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.35),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
