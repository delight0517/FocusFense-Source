import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import 'app_logger.dart';

/// Windows 설정 → 기본 앱 (기본 브라우저 변경).
abstract final class WindowsDefaultAppsLauncher {
  static const String defaultAppsUri = 'ms-settings:defaultapps';

  static Future<bool> openDefaultAppsSettings() async {
    if (!Platform.isWindows) return false;
    return _open(defaultAppsUri);
  }

  static Future<bool> _open(String uri) async {
    try {
      final Uri parsed = Uri.parse(uri);
      final bool ok = await launchUrl(parsed, mode: LaunchMode.externalApplication);
      if (!ok) {
        AppLogger.instance.warn('default_apps_launch: failed $uri');
      }
      return ok;
    } catch (e) {
      AppLogger.instance.warn('default_apps_launch error: $e');
      return false;
    }
  }
}
