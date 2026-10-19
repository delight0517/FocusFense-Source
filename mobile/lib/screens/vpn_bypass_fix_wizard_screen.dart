import 'package:flutter/material.dart';

import '../models/vpn_bypass_diagnostic_models.dart';
import '../services/vpn_bypass_fix_wizard_service.dart';
import '../theme/app_colors.dart';

/// Step-by-step guided fixes from a bypass diagnostic report.
class VpnBypassFixWizardScreen extends StatefulWidget {
  const VpnBypassFixWizardScreen({super.key, required this.report});

  final VpnBypassDiagnosticReport report;

  @override
  State<VpnBypassFixWizardScreen> createState() => _VpnBypassFixWizardScreenState();
}

class _VpnBypassFixWizardScreenState extends State<VpnBypassFixWizardScreen> {
  late final List<VpnBypassFixWizardStep> _steps;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _steps = VpnBypassFixWizardService.instance.stepsFromReport(widget.report);
  }

  Future<void> _runAction(VpnBypassFixAction action) async {
    await action.run();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「${action.label}」 실행함 — ${action.hint}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VpnBypassFixWizardStep step = _steps[_index];

    return Scaffold(
      appBar: AppBar(
        title: const Text('단계별 해결 가이드'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                '${_index + 1} / ${_steps.length}',
                style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          LinearProgressIndicator(
            value: (_index + 1) / _steps.length,
            minHeight: 4,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: <Widget>[
                Text(
                  step.title,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Text(
                  step.body,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
                const SizedBox(height: 20),
                ...step.actions.map((VpnBypassFixAction a) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: a.isPrimary
                        ? FilledButton(
                            onPressed: () => _runAction(a),
                            child: Text(a.label),
                          )
                        : OutlinedButton(
                            onPressed: () => _runAction(a),
                            child: Text(a.label),
                          ),
                  );
                }),
                if (step.actions.isNotEmpty)
                  Text(
                    step.actions.first.hint,
                    style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: <Widget>[
                  if (_index > 0)
                    OutlinedButton(
                      onPressed: () => setState(() => _index -= 1),
                      child: const Text('이전'),
                    )
                  else
                    const SizedBox(width: 80),
                  const Spacer(),
                  FilledButton(
                    onPressed: _index >= _steps.length - 1
                        ? () => Navigator.of(context).pop()
                        : () => setState(() => _index += 1),
                    child: Text(_index >= _steps.length - 1 ? '완료' : '다음 단계'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
