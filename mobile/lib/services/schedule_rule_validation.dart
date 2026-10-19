import 'dart:io' show Platform;

import '../models/block_app.dart';

/// Shared validation + naming used by schedule edit and quick-block editors.
abstract final class ScheduleRuleValidation {
  static const Set<String> tooBroadHosts = <String>{
    'google.com',
    'google.co.kr',
    'naver.com',
    'apple.com',
    'microsoft.com',
    'cloudflare.com',
    'amazon.com',
    'facebook.com',
    'instagram.com',
  };

  static const List<String> appPresets = <String>[
    'Discord', 'Slack', 'Telegram', 'WhatsApp', 'Messenger',
    'Twitter', 'X', 'Instagram', 'TikTok', 'Reddit',
    'Steam', 'Epic Games Launcher', 'Battle.net', 'StarCraft II',
    'YouTube', 'Spotify', 'Music', 'TV',
    'Chrome', 'Firefox', 'Edge', 'Brave Browser', 'Arc',
  ];

  static String? validateHost(String host) {
    if (host.isEmpty) return '값을 입력하세요.';
    if (tooBroadHosts.contains(host)) {
      return '"$host" 는 너무 광범위해서 다른 앱·로그인도 깨질 수 있습니다. '
          '구체적인 하위 도메인(예: news.naver.com)을 추천합니다.';
    }
    return null;
  }

  static String? validateKeyword(String pattern) {
    if (pattern.isEmpty) return '키워드를 입력하세요.';
    final String p = pattern.toLowerCase();
    if (<String>{'chrome', 'safari', 'firefox', 'google', 'apple'}.contains(p)) {
      return '"$p" 는 너무 일반적입니다. 사용 중인 앱·검색 전반에 영향이 갈 수 있어요. '
          '더 구체적인 단어를 권장합니다.';
    }
    return null;
  }

  static String? validateAppName(String raw) {
    if (raw.isEmpty) return '앱 이름을 입력하세요.';
    final String n = raw.trim().toLowerCase();
    if (Platform.isWindows) {
      const Set<String> winBanned = <String>{
        'explorer',
        'windows explorer',
        'file explorer',
        'task manager',
        '작업 관리자',
        'settings',
        '설정',
        'search',
        '6 vpn blocker',
        'cursor',
        'powershell',
        'windows terminal',
        'devenv',
        'visual studio',
      };
      if (winBanned.contains(n)) {
        return '"$raw" 는 Windows에서 차단하면 작업 환경이 망가질 수 있어요. 다른 앱을 고르세요.';
      }
    } else {
      const Set<String> banned = <String>{
        'finder', 'system', 'system preferences', 'system settings',
        'loginwindow', 'window server', 'controlcenter', 'dock',
        '6 vpn blocker', 'cursor', 'xcode', 'terminal',
      };
      if (banned.contains(n)) {
        return '"$raw" 는 차단하면 Mac이 정상적으로 동작하지 않을 수 있어요. 다른 이름을 사용하세요.';
      }
    }
    return null;
  }

  static String winBundlePayload(BlockApp app) =>
      'win|${app.exeName}|${app.chromeAppId ?? ''}';

  static BlockApp blockAppFromStored({
    required String displayName,
    String? bundleId,
  }) {
    final String name = displayName.trim();
    if (name.isEmpty) {
      return const BlockApp(exeName: '', displayName: '');
    }
    final String? bundle = bundleId?.trim();
    if (bundle != null && bundle.startsWith('win|')) {
      final List<String> parts = bundle.split('|');
      if (parts.length < 3) {
        return BlockApp(
          exeName: '',
          displayName: name,
          windowTitleMatch: name,
        );
      }
      final String exe = BlockApp.normalizeExeName(parts[1]);
      if (exe.isEmpty) {
        return BlockApp(
          exeName: '',
          displayName: name,
          windowTitleMatch: name,
        );
      }
      final String cidRaw = parts.sublist(2).join('|');
      String? chromeId;
      if (BlockApp.browserExes.contains(exe)) {
        chromeId = cidRaw.isEmpty ? BlockApp.mainBrowserKey : cidRaw;
      }
      return BlockApp(
        exeName: exe,
        displayName: name,
        chromeAppId: chromeId,
      );
    }
    return BlockApp(
      exeName: '',
      displayName: name,
      windowTitleMatch: name,
    );
  }

  static String? pickerKeyFromBundleId(String? bundleId) {
    if (bundleId == null || !bundleId.startsWith('win|')) return null;
    final List<String> parts = bundleId.split('|');
    if (parts.length < 3) return null;
    final String exe = BlockApp.normalizeExeName(parts[1]);
    final String cid = parts.sublist(2).join('|');
    if (BlockApp.browserExes.contains(exe)) {
      if (cid.isNotEmpty && cid != BlockApp.mainBrowserKey) {
        return '$exe?app-id=$cid';
      }
      return exe;
    }
    return exe;
  }

  static String pickerKeyForBlockApp(BlockApp a) {
    if (a.isPwa) {
      return '${a.exeName}?app-id=${a.chromeAppId}';
    }
    if (a.isChromiumBrowser) {
      return a.exeName;
    }
    return a.exeName;
  }
}
