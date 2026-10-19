import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// In-app self introduction / usage guide.
class AppIntroScreen extends StatelessWidget {
  const AppIntroScreen({super.key});

  static const String appTitle = '철벽 Chrome';
  static const String appSubtitle = '유튜브 채널·영상 & 웹사이트 차단기';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('앱 소개'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  appTitle,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  appSubtitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Chrome에서 특정 사이트, 유튜브 채널, 채널 아래 영상까지 실제로 차단하기 위해 '
                  '정책·확장·DNS·네트워크를 함께 쓰는 데스크톱 차단 앱입니다.',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _section(
            context,
            '핵심 기능',
            <String>[
              '사이트 차단: 도메인/URL 기준으로 Chrome에서 접근 차단',
              '유튜브 채널 차단: @핸들·채널 URL 등록 시 채널 전체 차단',
              '채널 영상 차단: 채널 영상 ID를 반영해 watch URL까지 차단',
              '자동 복구: 정책/확장/PAC 상태를 주기 점검하고 자동 재적용',
              '진단 도구: 5계층 LIVE 점검으로 실제 차단 여부 즉시 확인',
            ],
          ),
          _section(
            context,
            '핵심 원리 (A/B/C)',
            <String>[
              'A. 브라우저 정책 강제: ExtensionInstallForcelist + URLBlocklist',
              'B. hosts 잠금: 시스템 DNS 차단 + 파일 잠금으로 우회 난이도 상승',
              'C. 계정 분리 권장: 차단 대상은 표준 사용자 계정 사용',
            ],
          ),
          _section(
            context,
            '사용법 (빠른 시작)',
            <String>[
              '1) 스케줄/규칙에서 차단할 사이트 또는 유튜브 채널 추가',
              '2) 설정·진단에서 시스템 차단 적용(UAC) 실행',
              '3) Chrome 완전 종료 후 다시 실행',
              '4) 차단 URL 접속 테스트 (예: watch?v=...)',
              '5) 안 되면 진단에서 정책 재적용 + LIVE 점검 실행',
            ],
          ),
          _section(
            context,
            '앱 안에서 확인할 곳',
            <String>[
              '설정 > 진단: 5계층 LIVE 차단 상태',
              '설정 > 도구 > Chrome 열기(차단 켜짐): 보호 모드 실행',
              '설정 > 도구 > 보호 커버리지 점검: 미적용 항목 자동 안내',
              '홈 차단 현황판: 규칙→브라우저→동기화→차단 단계 확인',
            ],
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '권장 타이틀: "$appTitle"\n'
                '서브타이틀: "$appSubtitle"\n\n'
                '현재 빌드/로그 식별명(Focus Fense)은 지원·디버그 호환을 위해 유지할 수 있습니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<String> lines) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            for (final String line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '- $line',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
