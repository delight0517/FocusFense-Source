import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Information card explaining blocking and lock mechanisms for users who
/// might try to bypass protections impulsively.
class ProtectionInfoCard extends StatefulWidget {
  const ProtectionInfoCard({super.key});

  @override
  State<ProtectionInfoCard> createState() => _ProtectionInfoCardState();
}

class _ProtectionInfoCardState extends State<ProtectionInfoCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppColors.accent.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.accent.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.shield, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '차단이 어떻게 작동하는지 알아보세요',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ),
            if (_expanded) ...<Widget>[
              const SizedBox(height: 12),
              _buildSection(
                context,
                title: '🌐 도메인 차단 (웹사이트 차단)',
                items: _domainBlockBullets(),
              ),
              const SizedBox(height: 10),
              _buildSection(
                context,
                title: '🔍 키워드 필터링 (검색 결과 차단)',
                items: <String>[
                  '앱 내 검색(webview)에서만 작동합니다',
                  '웹사이트를 직접 방문하면 필터링 안 됨',
                  '앱 내에서만 특정 검색어 결과를 숨깁니다',
                  '예: "porn" 키워드 → Google 검색 결과에서 해당 결과만 필터',
                ],
              ),
              const SizedBox(height: 10),
              _buildSection(
                context,
                title: '🔐 잠금 설정 (중요!)',
                items: <String>[
                  '활성화 시 차단을 끌 수 없습니다',
                  '5분 잠금 해제가 필요합니다',
                  'PIN을 설정하면 추가 보안이 됩니다',
                  '잠금 상태에서 규칙 삭제/비활성화 불가능',
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '⚠️ "앱을 삭제하면 차단이 풀리나?"',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppColors.warning,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _hostsPersistExplanation(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            fontSize: 12,
                            color: AppColors.muted,
                            height: 1.4,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (Platform.isMacOS)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppColors.success.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '✓ 시스템 차단 활성화하면:',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: AppColors.success,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '1. macOS 시스템 설정 변경 (admin 권한)\n'
                        '2. Firefox DoH(DNS-over-HTTPS) 자동 비활성화\n'
                        '3. 매 시간마다 자동 동기화\n'
                        '4. 규칙 변경 시 즉시 적용\n\n'
                        '※ 시스템 차단을 해제하려면 반드시 앱의 "차단 해제" 버튼을 클릭해야 합니다.',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontSize: 12,
                              color: AppColors.muted,
                              height: 1.5,
                            ),
                      ),
                    ],
                  ),
                )
              else if (Platform.isWindows)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppColors.success.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '✓ Windows 시스템 차단을 켜면:',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: AppColors.success,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '이 앱의 핵심 3원칙 (Chrome 유튜브·사이트 차단):\n\n'
                        'A. Chrome 정책 — ExtensionInstallForcelist로 확장 강제 설치·삭제 불가, '
                        'URLBlocklist로 사이트·유튜브 채널·영상 URL 차단\n'
                        'B. hosts 잠금 — UAC 적용 후 hosts 읽기 전용 + 일반 사용자 쓰기 거부\n'
                        'C. 표준 사용자 계정 — 차단 대상은 관리자가 아닌 표준 계정 권장\n\n'
                        'hosts/DNS + Chrome 정책이 주기 동기화됩니다.\n'
                        '※ 해제도 이 앱의 시스템 차단 해제 흐름을 따르세요.',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontSize: 12,
                              color: AppColors.muted,
                              height: 1.5,
                            ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  List<String> _domainBlockBullets() {
    if (Platform.isWindows) {
      return <String>[
        r'%SystemRoot%\System32\drivers\etc\hosts 등 시스템 DNS 차단에 반영됩니다',
        'Chrome, Edge, Firefox 등에서 해당 호스트 접속이 막힙니다',
        '앱을 삭제해도 hosts 항목은 남을 수 있습니다',
        '차단 해제는 이 앱의 시스템 차단/규칙 화면에서 정리하세요',
      ];
    }
    if (Platform.isMacOS) {
      return <String>[
        '시스템의 /etc/hosts 파일에 저장됩니다',
        '모든 브라우저(Safari, Chrome, Firefox)에서 작동합니다',
        '앱을 삭제해도 유지될 수 있습니다',
        '차단을 해제하려면 앱을 다시 켜서 "차단 해제"를 진행하세요',
      ];
    }
    return <String>[
      '시스템 네트워크 규칙에 반영됩니다',
      '설치된 브라우저에서 동일하게 적용됩니다',
      '앱을 삭제해도 일부 시스템 설정은 남을 수 있습니다',
    ];
  }

  String _hostsPersistExplanation() {
    if (Platform.isWindows) {
      return '아닙니다! Windows hosts/DNS 항목은 앱을 지워도 남을 수 있습니다. '
          '반드시 이 앱에서 시스템 차단을 해제하거나 hosts를 정리하세요.';
    }
    if (Platform.isMacOS) {
      return '아닙니다! 차단 설정은 시스템 파일(/etc/hosts)에 저장되므로 앱을 삭제해도 유지됩니다. '
          '반드시 앱을 다시 설치해서 차단을 해제해야 합니다.';
    }
    return '차단 규칙은 운영체제 네트워크 설정에 남을 수 있습니다. 앱만 삭제하면 자동으로 풀리지 않을 수 있어요.';
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required List<String> items,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
        ),
        const SizedBox(height: 6),
        ...items.map(
          (String item) => Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '• ',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Expanded(
                  child: Text(
                    item,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 12,
                          color: AppColors.muted,
                          height: 1.3,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
