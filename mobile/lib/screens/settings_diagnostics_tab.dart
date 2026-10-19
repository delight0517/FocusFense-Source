import 'package:flutter/material.dart';

import '../widgets/settings_disclosure.dart';
import '../widgets/blocking_ecosystem_report_card.dart';
import '../widgets/live_block_status_card.dart';
import '../widgets/url_live_test_card.dart';
import '../widgets/agent_protection_card.dart';
import '../widgets/startup_bypass_resilience_card.dart';
import '../widgets/browser_youtube_split_card.dart';
import '../widgets/youtube_block_sources_card.dart';
import '../widgets/vpn_bypass_diagnostic_panel.dart';
import 'block_activity_screen.dart';
import 'diagnostic_agent_screen.dart';
import 'diagnostics_screen.dart';
import 'log_viewer_screen.dart';
import 'one_tap_block_screen.dart';
import 'user_feedback_screen.dart';

/// Detailed probes are mounted only when requested.
class SettingsDiagnosticsTab extends StatelessWidget {
  const SettingsDiagnosticsTab({super.key, required this.buildTagLine});
  final String? buildTagLine;

  void _open(BuildContext context, Widget page) {
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => page));
  }

  Widget _link(BuildContext context, String title, Widget page) => ListTile(
    title: Text(title),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => _open(context, page),
  );

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    children: [
      Text('차단 확인과 문제 해결', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 6),
      const Text('확인할 사이트를 넣어 보세요. 문제가 있으면 차단 설정을 점검할 수 있습니다.'),
      const SizedBox(height: 16),
      SettingsDisclosure(
        title: '사이트 하나 확인하기',
        subtitle: '주소를 넣고 차단 규칙과 적용 상태 확인',
        icon: Icons.search,
        builder: (_) => const UrlLiveTestCard(),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '차단이 안 되나요?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              const Text('확장과 브라우저 설정을 순서대로 점검합니다. 해결되지 않은 항목도 알려드립니다.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _open(context, const OneTapBlockScreen()),
                icon: const Icon(Icons.build_outlined),
                label: const Text('차단 설정 점검·복구'),
              ),
            ],
          ),
        ),
      ),
      SettingsDisclosure(
        title: '브라우저별 상태',
        subtitle: 'Chrome, Edge, Firefox 등의 적용 상태',
        icon: Icons.web,
        builder: (_) => const LiveBlockStatusCard(),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.support_agent),
          title: const Text('문제 신고하기'),
          subtitle: const Text('해결되지 않은 문제와 진단 자료 전달'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(context, const UserFeedbackScreen()),
        ),
      ),
      SettingsDisclosure(
        title: '상세 진단·개발 도구',
        subtitle: '지원이나 개발 중에만 필요한 세부 정보',
        icon: Icons.code,
        builder: (context) => Column(
          children: [
            SettingsDisclosure(
              title: '전체 보호 점검',
              subtitle: '보호 범위와 자동 복구 상태',
              builder: (_) => const Column(
                children: [
                  BlockingEcosystemReportCard(),
                  StartupBypassResilienceCard(),
                  AgentProtectionCard(),
                ],
              ),
            ),
            SettingsDisclosure(
              title: 'YouTube·우회 차단 점검',
              subtitle: '동영상 차단 목록과 네트워크 진단',
              builder: (_) => const Column(
                children: [
                  YoutubeBlockSourcesCard(),
                  BrowserYoutubeSplitCard(),
                  VpnBypassDiagnosticPanel(),
                ],
              ),
            ),
            _link(context, '전체 진단', const DiagnosticsScreen()),
            _link(context, '차단 활동 기록', const BlockActivityScreen()),
            _link(context, '문제 해결 에이전트', const DiagnosticAgentScreen()),
            _link(context, '오류·상세 로그', const LogViewerScreen()),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                buildTagLine ?? '버전 정보를 불러오는 중…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
