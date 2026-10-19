import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import 'quick_block_session_service.dart';

Future<bool> launchAccountAuthorization(Uri uri) async {
  if (Platform.isWindows &&
      (await QuickBlockSessionService.instance.activeBlockApps()).any(
        (app) => app.exeName == 'chrome.exe',
      )) {
    for (final base in [
      Platform.environment['ProgramFiles'],
      Platform.environment['ProgramFiles(x86)'],
    ]) {
      if (base == null) continue;
      final executable = File('$base/Mozilla Firefox/firefox.exe');
      if (await executable.exists()) {
        await Process.start(executable.path, [
          uri.toString(),
        ], mode: ProcessStartMode.detached);
        return true;
      }
    }
    throw StateError('Chrome 차단 중입니다. Firefox를 설치한 뒤 로그인해 주세요.');
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
