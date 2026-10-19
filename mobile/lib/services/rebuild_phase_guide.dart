/// Plain-Korean copy for the in-app Windows rebuild overlay.
abstract final class RebuildPhaseGuide {
  static GuideCopy forPhase(
    String phase, {
    int elapsedSec = 0,
    String? statusMessage,
  }) {
    final String msg = statusMessage?.trim() ?? '';
    switch (phase) {
      case 'pub_get':
        return GuideCopy(
          step: '②',
          title: '패키지 다운로드',
          detail: msg.isNotEmpty ? msg : 'Flutter 패키지를 받는 중입니다.',
          how: '백그라운드 PowerShell이 `flutter pub get`으로 pubspec에 적힌 라이브러리를 PC에 받습니다.',
          eta: '약 30초~1분',
        );
      case 'pre_exit':
        return GuideCopy(
          step: '③',
          title: '잠깐 닫힘 (정상)',
          detail: msg.isNotEmpty
              ? msg
              : 'exe 잠금을 풀기 위해 이 창이 곧 닫힙니다.',
          how: 'Windows는 실행 중인 exe를 덮어쓸 수 없어서, 잠시 앱을 닫고 백그라운드에서 빌드를 이어갑니다. 완료되면 새 창이 자동으로 열립니다.',
          eta: '3초 뒤 닫힘 → 빌드 약 2~4분 → 새 창 자동 실행',
        );
      case 'building':
        final int remain = (240 - elapsedSec).clamp(30, 240);
        return GuideCopy(
          step: '④',
          title: '새 exe 빌드',
          detail: msg.isNotEmpty ? msg : '소스 코드를 Windows 실행 파일로 컴파일 중입니다.',
          how: '백그라운드 PowerShell이 `flutter build windows --release`를 실행합니다. 앱 창은 닫혀 있어도 정상입니다.',
          eta: elapsedSec > 120
              ? '곧 끝납니다 (약 ${(remain / 60).ceil()}분 이내)'
              : '약 2~4분 (경과 ${elapsedSec ~/ 60}분 ${elapsedSec % 60}초)',
        );
      case 'installing':
        return GuideCopy(
          step: '⑤',
          title: '새 버전 설치',
          detail: msg.isNotEmpty ? msg : '빌드된 파일을 설치 폴더에 복사 중입니다.',
          how: '이전 exe를 지우고 `%LOCALAPPDATA%\\Programs\\SixVPNBlocker`에 새 파일을 복사합니다.',
          eta: '약 10~20초',
        );
      case 'relaunching':
        return GuideCopy(
          step: '⑥',
          title: '새 창 열기',
          detail: msg.isNotEmpty ? msg : '방금 설치한 새 버전을 실행합니다.',
          how: '이전 창은 이미 닫혀 있습니다. 새 exe를 바로 실행해 화면을 다시 띄웁니다.',
          eta: '약 2~5초',
        );
      case 'done':
        return GuideCopy(
          step: '✓',
          title: '업데이트 완료',
          detail: '새 버전이 준비되었습니다.',
          how: '곧 새 창으로 전환됩니다.',
          eta: '즉시',
        );
      case 'failed':
        return GuideCopy(
          step: '!',
          title: '업데이트 실패',
          detail: msg.isNotEmpty ? msg : '빌드가 실패했습니다.',
          how: '아래 로그를 확인하거나 설정 → Windows 개발 빌드에서 터미널 명령으로 다시 시도하세요.',
          eta: '—',
        );
      default:
        return GuideCopy(
          step: '①',
          title: '준비 중',
          detail: msg.isNotEmpty ? msg : '빌드 스크립트를 시작합니다.',
          how: '백그라운드 PowerShell이 소스 폴더·Flutter SDK를 확인한 뒤 패키지 다운로드로 넘어갑니다.',
          eta: '약 10~20초',
        );
    }
  }
}

final class GuideCopy {
  const GuideCopy({
    required this.step,
    required this.title,
    required this.detail,
    required this.how,
    required this.eta,
  });

  final String step;
  final String title;
  final String detail;
  final String how;
  final String eta;
}
