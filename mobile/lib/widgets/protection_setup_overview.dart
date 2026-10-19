import 'package:flutter/material.dart';

/// User-facing setup stages; file/policy readiness is not runtime verification.
class ProtectionSetupOverview extends StatelessWidget {
  const ProtectionSetupOverview({super.key, required this.running});
  final bool running;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '차단 설정을 시작하세요',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        running
            ? '필요한 설정을 확인하고 있습니다. 화면을 그대로 두세요.'
            : '아래 버튼을 누르면 필요한 설정을 확인하고 다음 할 일을 안내합니다.',
      ),
      const SizedBox(height: 12),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.shield_outlined),
        title: Text('1. 보호 설정 준비'),
        subtitle: Text('앱과 차단 설정을 점검합니다. 권한 요청이 나타날 수 있습니다.'),
      ),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.web),
        title: Text('2. 브라우저 연결'),
        subtitle: Text('Chrome·Aside의 확장 설치와 활성화가 필요합니다. 최초 확인이 필요할 수 있습니다.'),
      ),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.fact_check_outlined),
        title: Text('3. 실제 차단 확인'),
        subtitle: Text('시간이 감지되고 한도에 도달하면 멈추는지 확인해야 설정이 끝납니다.'),
      ),
      const SizedBox(height: 8),
      const Text(
        'Firefox YouTube 기본 목표: 최근 60분 중 실제 재생 10분. '
        '브라우저 관리에서 확장 활성화를 확인하세요. Chrome·Aside는 스토어 배포 확인 후 연결합니다.',
      ),
    ],
  );
}
