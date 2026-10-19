import 'build_identity_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'windows_extension_guard_service.dart';
import 'windows_firefox_extension_install_service.dart';

/// User-facing install result text (no duplicate HKLM noise when shortcut mode works).
abstract final class ExtensionInstallUserMessage {
  static Future<String> buildStamp() async {
    final build = await BuildIdentityService.instance.current();
    return '앱 빌드: ${build.version}+${build.buildNumber}';
  }

  static Future<String> formatSetupResult({
    required ExtensionPolicyVerifyResult verify,
    required FirefoxInstallVerifyResult firefoxVerify,
    required bool hasUnpackedDevCopy,
    String? extraLead,
  }) async {
    final StringBuffer msg = StringBuffer();
    if (extraLead != null && extraLead.trim().isNotEmpty) {
      msg.writeln(extraLead.trim());
      msg.writeln();
    }

      if (verify.firefoxPolicyOk && verify.chromeOk) {
        if (verify.chromeLoadExtensionFallbackOk) {
          msg.writeln(
            '✅ Firefox + Chrome/Edge 보호 적용 완료 (3단계 우회)\n'
            '① 바로가기 통합 ② 링크 프로토콜 ③ 순정 Chrome 자동 종료\n'
            '작업 표시줄·시작 메뉴 Chrome도 보호 실행기를 가리킵니다.',
          );
        } else if (verify.usesHkcuFallback) {
        msg.writeln('✅ Firefox + Chrome/Edge (사용자 레지스트리 정책 모드)');
      } else {
        msg.writeln('✅ 자동 설치 완료 (Chrome/Edge 관리자 + Firefox)');
      }
    } else if (verify.firefoxPolicyOk) {
      msg.writeln('✅ Firefox 완료');
      msg.writeln('❌ Chrome/Edge 미완료');
    } else {
      msg.writeln('❌ 브라우저 보호 미완료');
    }

    if (hasUnpackedDevCopy) {
      msg.writeln(
        '\n⚠ chrome://extensions → 「압축 해제됨」 Focus Fense 제거 권장',
      );
    }

    msg.writeln('\n---\n${verify.userFacingDetail}');
    if (firefoxVerify.detail.trim().isNotEmpty) {
      msg.writeln('\n${firefoxVerify.detail}');
    }
    msg.writeln(
      '\nFirefox: about:addons 에서 **제거·끄기 없음** = 성공. '
      'about:debugging 임시 애드온은 쓰지 마세요.',
    );
    msg.writeln('\n---\n${await buildStamp()}');
    return msg.toString().trim();
  }

  static String shortcutOnlyHint() =>
      'Chrome: ${ChromeLoadExtensionLauncher.chromeBatPath}';
}
