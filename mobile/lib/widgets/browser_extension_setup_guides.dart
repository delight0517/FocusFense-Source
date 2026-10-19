import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Step-by-step install copy for [BrowserExtensionsScreen].
final class BrowserExtensionSetupGuides {
  BrowserExtensionSetupGuides._();

  /// **권장** — 개발자 모드 없이 UAC만 (Chrome이 레지스트리에서 자동 로드).
  static const List<BrowserSetupGuide> chromeAdminOnly = <BrowserSetupGuide>[
    BrowserSetupGuide(
      step: 'A1',
      title: '폴더 준비 (앱)',
      body: '「① Chrome / Edge 용 폴더 준비」 버튼을 누릅니다.',
    ),
    BrowserSetupGuide(
      step: 'A2',
      title: '관리자 설치 (UAC)',
      body: '「UAC · 확장 시스템 고정」→ Windows 「예」\n'
          '→ 확장이 ProgramData로 복사되고 레지스트리에 등록됩니다.\n'
          '→ **개발자 모드는 켤 필요 없습니다.**',
      highlight: '압축 해제 로드 하지 마세요',
    ),
    BrowserSetupGuide(
      step: 'A3',
      title: '개발자 모드 복사본 제거',
      body: 'chrome://extensions 에서\n'
          '「압축 해제된 확장 프로그램」으로 넣은 기존 확장(화면 표시명: 6 VPN Blocker)이 있으면 **제거**.\n'
          '「관리자가 설치」만 남기려면 예전 복사본을 지워야 합니다.',
    ),
    BrowserSetupGuide(
      step: 'A4',
      title: 'Chrome 완전 종료 후 재실행',
      body: '작업 표시줄 Chrome 아이콘 우클릭 → **모든 Chrome 창 닫기**\n'
          '→ Chrome 다시 실행 → chrome://extensions 확인',
    ),
    BrowserSetupGuide(
      step: 'A5',
      title: '성공 확인',
      body: '확장 카드에 **「관리자가 설치」** (또는 Installed by your administrator)\n'
          '→ **제거 버튼 없음**\n\n'
          '「압축 해제됨」+ 제거 버튼이 보이면 → 아직 개발자 모드 복사본이거나 UAC 등록 실패입니다.',
    ),
  ];

  /// 빠른 테스트용 (제거 쉬움) — 고정이 목적이면 쓰지 마세요.
  static const List<BrowserSetupGuide> chromeDevMode = <BrowserSetupGuide>[
    BrowserSetupGuide(
      step: 'B1',
      title: '(테스트만) 개발자 모드',
      body: '고정·삭제 방지가 목적이면 **이 경로를 쓰지 마세요.**\n'
          '개발자 모드 → 압축 해제 로드 → 언제든 제거 가능합니다.',
    ),
    BrowserSetupGuide(
      step: 'B2',
      title: '압축 해제 로드',
      body: 'chrome_blocker **폴더** 선택 (manifest.json 파일이 아님).',
    ),
  ];

  static const List<BrowserSetupGuide> chrome = chromeAdminOnly;

  /// 용어·실패 시 대처 (앱 내 「도움말」 패널).
  static const List<BrowserSetupGuide> glossary = <BrowserSetupGuide>[
    BrowserSetupGuide(
      step: '?',
      title: '개발자 모드 복사본이란?',
      body: 'chrome://extensions 에서 **개발자 모드**를 켠 뒤\n'
          '「압축 해제된 확장 프로그램을 로드」로 폴더를 넣은 **테스트용 복사본**입니다.\n\n'
          '· 카드에 **「압축 해제됨」** 이라고 뜸\n'
          '· **제거** 버튼이 있어 언제든 지울 수 있음\n'
          '· 고정·삭제 방지 목적에는 **쓰지 않습니다**',
    ),
    BrowserSetupGuide(
      step: '?',
      title: '관리자 설치(정상)란?',
      body: '앱의 **「한 번에 자동 설치」** 또는 **UAC · 관리자 설치** 후\n'
          'Windows 레지스트리(HKLM)에 등록되는 방식입니다.\n\n'
          '· **「관리자가 설치」** (Installed by your administrator)\n'
          '· **제거·끄기 버튼 없음** (정책이 잠금)\n'
          '· ProgramData 폴더에서 Chrome이 자동 로드',
    ),
    BrowserSetupGuide(
      step: '?',
      title: '레지스트리 확인이 전부 「없음」일 때',
      body: '1) UAC 창에서 **예** 를 눌렀는지 (아니오 = 등록 0개)\n'
          '2) 앱 아이콘 우클릭 → **관리자 권한으로 실행** 후 재시도\n'
          '3) 학교·회사 PC면 HKLM 정책이 막혀 있을 수 있음\n'
          '4) C:\\ProgramData\\SixVPNBlocker\\guard_last.log 확인',
    ),
  ];

  static const List<BrowserSetupGuide> edge = <BrowserSetupGuide>[
    BrowserSetupGuide(
      step: '1',
      title: 'Chrome과 동일',
      body: '① 폴더 준비 → UAC 시스템 고정 → Chrome 복사본 제거 → Edge도 완전 종료 후 재실행.\n'
          'Edge도 **압축 해제 로드 없이** 레지스트리에서 자동 설치됩니다.',
    ),
    BrowserSetupGuide(
      step: '2',
      title: '확인',
      body: 'edge://extensions → 「관리자가 설치」+ 제거 버튼 없음',
      highlight: 'edge://extensions',
    ),
  ];

  static const List<BrowserSetupGuide> firefox = <BrowserSetupGuide>[
    BrowserSetupGuide(
      step: '1',
      title: '한 번에 자동 설치 (권장)',
      body: '화면 상단 **「한 번에 자동 설치」** → UAC **예**\n'
          '→ XPI 패키징 + policies.json + 모든 프로필 복사 + DoH 잠금',
      highlight: '제거·끄기 버튼 없음 = 성공',
    ),
    BrowserSetupGuide(
      step: '2',
      title: '확인',
      body: 'about:addons → 6 VPN Blocker (기존 확장 표시명)\n'
          '「관리 정책에 의해 설치됨」·제거 불가\n\n'
          '「Firefox 정책·XPI 확인」 버튼으로 앱에서 점검',
    ),
    BrowserSetupGuide(
      step: '3',
      title: '임시 애드온 (비권장)',
      body: 'about:debugging 임시 불러오기는 **언제든 삭제 가능**합니다.\n'
          '고정 차단 목적에는 쓰지 마세요.',
      highlight: 'about:debugging#/runtime/this-firefox',
    ),
    BrowserSetupGuide(
      step: '4',
      title: 'AMO 서명 (최종 배포)',
      body: 'Release Firefox는 **서명된 XPI**가 가장 안정적입니다.\n'
          'mobile/scripts/AMO_SIGN_FIREFOX.md 참고 → '
          'sixvpn_blocker_signed.xpi 를 assets에 넣고 다시 자동 설치.',
    ),
  ];
}

/// One install step block.
final class BrowserSetupGuide {
  const BrowserSetupGuide({
    required this.step,
    required this.title,
    required this.body,
    this.highlight,
  });

  final String step;
  final String title;
  final String body;
  final String? highlight;
}

/// Expandable panel of [guides].
class BrowserSetupGuidePanel extends StatelessWidget {
  const BrowserSetupGuidePanel({
    super.key,
    required this.title,
    required this.icon,
    required this.guides,
    required this.accent,
  });

  final String title;
  final IconData icon;
  final List<BrowserSetupGuide> guides;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icon, color: accent),
          title: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          children: guides
              .map(
                (BrowserSetupGuide g) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: accent.withValues(alpha: 0.2),
                            child: Text(
                              g.step,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: accent,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  g.title,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  g.body,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    height: 1.45,
                                    color: AppColors.muted,
                                  ),
                                ),
                                if (g.highlight != null) ...<Widget>[
                                  const SizedBox(height: 6),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: accent.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      g.highlight!,
                                      style: theme.textTheme.labelMedium
                                          ?.copyWith(
                                        fontFamily: 'monospace',
                                        color: accent,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}
