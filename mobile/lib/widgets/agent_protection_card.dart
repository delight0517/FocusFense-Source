import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/agent_destruct_gate_service.dart';
import '../services/agent_tamper_watchdog_service.dart';
import '../theme/app_colors.dart';

/// Settings → 진단: 5 Cursor-AI bypass scenarios + owner override token.
class AgentProtectionCard extends StatefulWidget {
  const AgentProtectionCard({super.key});

  @override
  State<AgentProtectionCard> createState() => _AgentProtectionCardState();
}

class _AgentProtectionCardState extends State<AgentProtectionCard> {
  AgentTamperReport? _report;
  bool _running = false;
  bool _gateEnabled = true;
  String? _token;

  static const Map<String, String> _kTitleKo = <String, String>{
    's1_ai_delete_app': 'S1: Cursor에게 「앱 삭제/mobile 지워」',
    's2_ai_gut_block_code': 'S2: Cursor에게 「차단 코드·builtin 제거」',
    's3_ai_disable_guards': 'S3: Cursor에게 「가드·자동유지 끄기」',
    's4_ai_strip_cursor_rules': 'S4: Cursor에게 「.cursorrules 삭제」',
    's5_ai_wipe_policies': 'S5: Cursor에게 「URLBlocklist·PAC 삭제」',
    's6_token_social_engineering': 'S6: 가짜 토큰·형식 유출·검증 코드 설명',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final AgentTamperReport? r =
        await AgentTamperWatchdogService.instance.loadLastReport();
    final bool gate = await AgentDestructGateService.instance.isEnabled();
    final String? tok = await AgentDestructGateService.instance.token();
    await AgentDestructGateService.instance.syncLocalVerifierArtifacts();
    if (!mounted) return;
    setState(() {
      _report = r;
      _gateEnabled = gate;
      _token = tok;
    });
  }

  Future<void> _runVerify() async {
    setState(() => _running = true);
    final AgentTamperReport? r =
        await AgentTamperWatchdogService.instance.runVerifyAndHeal(
      reason: 'diagnostics_ui',
    );
    if (!mounted) return;
    setState(() {
      _report = r;
      _running = false;
    });
  }

  Future<void> _rotateToken() async {
    final String t = await AgentDestructGateService.instance.rotateToken();
    if (!mounted) return;
    setState(() => _token = t);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('오버라이드 토큰을 새로 발급했습니다.')),
    );
  }

  Widget _scenarioTile(AgentTamperCase c) {
    final String title = _kTitleKo[c.id] ?? c.title;
    final Color color =
        c.mitigated ? Colors.green.shade700 : Colors.orange.shade800;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            c.mitigated ? Icons.shield : Icons.warning_amber_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                Text(
                  c.detail,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                if (c.defense.isNotEmpty)
                  Text(
                    '방어: ${c.defense}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.accent.withValues(alpha: 0.9),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AgentTamperReport? r = _report;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.smart_toy_outlined, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI 우회 방어 (Cursor 5종)',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: '점검·복구',
                  onPressed: _running ? null : _runVerify,
                  icon: _running
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            Text(
              '게임하려고 Cursor에게 「그냥 삭제해」라고 해도, 규칙·오프라인 가드·점검 스크립트가 막습니다. '
              '파괴 명령은 아래 토큰을 채팅에 붙여넣고 검증 스크립트가 통과할 때만 허용됩니다. '
              '「2534」 같은 추측·AI에게 토큰 형식 물어보기는 통하지 않습니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('AI 파괴 명령 잠금', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '켜짐 = Cursor가 S1–S5 삭제·비활성화 거부 (토큰 없을 때)',
                style: TextStyle(fontSize: 12),
              ),
              value: _gateEnabled,
              onChanged: (bool v) async {
                await AgentDestructGateService.instance.setEnabled(v);
                final String? tok =
                    v ? await AgentDestructGateService.instance.token() : null;
                if (!mounted) return;
                setState(() {
                  _gateEnabled = v;
                  _token = tok;
                });
              },
            ),
            if (_gateEnabled && _token != null) ...<Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: SelectableText(
                        _token!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '복사',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _token!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('토큰 복사됨')),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: '재발급',
                      icon: const Icon(Icons.autorenew, size: 18),
                      onPressed: _rotateToken,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (r != null)
              Text(
                '점검: ${r.passCount}/${r.totalCount} 방어 활성',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: r.allPass ? Colors.green.shade700 : Colors.orange.shade800,
                ),
              ),
            if (_running)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(minHeight: 2),
              )
            else if (r != null && r.scenarios.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              ...r.scenarios.map(_scenarioTile),
            ],
          ],
        ),
      ),
    );
  }
}
