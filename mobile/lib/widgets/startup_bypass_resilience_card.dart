import 'package:flutter/material.dart';

import '../services/startup_bypass_resilience_service.dart';
import '../theme/app_colors.dart';

/// Settings → 진단: 4 startup failures + 5 bypass holes matrix.
class StartupBypassResilienceCard extends StatefulWidget {
  const StartupBypassResilienceCard({super.key});

  @override
  State<StartupBypassResilienceCard> createState() =>
      _StartupBypassResilienceCardState();
}

class _StartupBypassResilienceCardState extends State<StartupBypassResilienceCard> {
  StartupBypassTestReport? _report;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _loadCached();
  }

  Future<void> _loadCached() async {
    final StartupBypassTestReport? r =
        await StartupBypassResilienceService.instance.loadLastReport();
    if (mounted) setState(() => _report = r);
  }

  Future<void> _runTest() async {
    setState(() => _running = true);
    final StartupBypassTestReport? r =
        await StartupBypassResilienceService.instance.runLiveTest();
    if (mounted) {
      setState(() {
        _report = r;
        _running = false;
      });
    }
  }

  static const Map<String, String> _kTitleKo = <String, String>{
    's1_stale_exe': '앱 exe 경로 깨짐·Run 레지스트리 불일치',
    's2_startup_disabled': '작업 관리자에서 시작 프로그램 비활성',
    's3_crash_before_init': '앱 크래시·초기화 전 종료',
    's4_logon_gap': '부팅~앱 기동 사이 공백',
    'b1_reg_tamper': '레지스트리 URLBlocklist 삭제',
    'b2_secure_dns': 'Chrome/Edge 보안 DNS DoH 우회',
    'b3_secondary_dns': '보조 DNS로 hosts 싱크홀 우회',
    'b4_pac_tamper': 'PAC·ProxyPacUrl 삭제',
    'b5_kill_app': '앱 강제 종료 시 프로세스 차단 공백',
  };

  Widget _caseTile(StartupBypassCase c) {
    final String title = _kTitleKo[c.id] ?? c.title;
    final Color color = c.mitigated ? Colors.green.shade700 : Colors.orange.shade800;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
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
                Text(c.detail, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                Text(
                  '대응: ${c.fix}',
                  style: TextStyle(fontSize: 11, color: AppColors.accent.withValues(alpha: 0.9)),
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
    final StartupBypassTestReport? r = _report;
    final String score = r == null
        ? '—'
        : '${r.passCount}/${r.totalCount}';

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.security, color: AppColors.accent, size: 26),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '시작 실패·우회 구멍 점검',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                Text(score, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '앱이 안 떠도 URLBlocklist·PAC·오프라인 가드가 막는지, '
              'DoH·레지 조작·PAC 삭제 등 9가지를 자동 점검합니다.',
              style: TextStyle(fontSize: 12),
            ),
            if (r?.youtubeIp != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'youtube.com DNS: ${r!.youtubeIp} '
                '${r.youtubeSinkholed == true ? "(싱크홀)" : ""}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
            const SizedBox(height: 10),
            if (r != null) ...<Widget>[
              const Text('시작 실패 4가지', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              ...r.startupScenarios.map(_caseTile),
              const SizedBox(height: 6),
              const Text('우회 구멍 5가지', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              ...r.bypassHoles.map(_caseTile),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _running ? null : _runTest,
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_running ? '점검 중…' : '지금 점검 (오프라인 가드 포함)'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
