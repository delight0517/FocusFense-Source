import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/browser_ecosystem_catalog.dart';
import '../models/ecosystem_scan_models.dart';
import 'windows_hidden_process.dart';

/// Reads Windows default HTTP browser and advises if it is blocked / killed.
final class WindowsDefaultBrowserService {
  WindowsDefaultBrowserService._();
  static final WindowsDefaultBrowserService instance =
      WindowsDefaultBrowserService._();

  String _regExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'reg.exe');
  }

  Future<DefaultBrowserAdvisory?> detect({
    required List<EcosystemTargetRow> targets,
  }) async {
    if (!Platform.isWindows) return null;

    String? progId = await _readUserChoiceProgId();
    progId ??= await _readHttpCommandProgId();
    if (progId == null || progId.isEmpty) {
      return const DefaultBrowserAdvisory(
        browserId: 'unknown',
        displayName: '알 수 없음',
        blockActive: false,
        isProblem: false,
        messageKo:
            '기본 브라우저를 읽지 못했습니다. Windows 설정 → 앱 → 기본 앱에서 확인하세요.',
        settingsUri: 'ms-settings:defaultapps',
      );
    }

    final String key = progId.toLowerCase();
    String browserId = kHttpProgIdToBrowserId[key] ?? 'unknown';
    for (final MapEntry<String, String> e in kHttpProgIdToBrowserId.entries) {
      if (key.contains(e.key)) {
        browserId = e.value;
        break;
      }
    }

    final BrowserCatalogEntry? catalog = BrowserCatalogEntry.forId(browserId);
    final String displayName =
        catalog?.displayName ?? progId;

    EcosystemTargetRow? match;
    for (final EcosystemTargetRow t in targets) {
      if (t.id == browserId) {
        match = t;
        break;
      }
    }

    final bool blockActive =
        match != null && match.urlBlockUsable;
    final bool isBlockedOrRisky = match != null &&
        (!match.urlBlockUsable || match.killOnNoBlock);

    String? suggestName;
    for (final EcosystemTargetRow t in targets) {
      if (!t.installed) continue;
      if (t.urlBlockUsable) {
        suggestName = t.displayName;
        break;
      }
    }
    suggestName ??= () {
      for (final EcosystemTargetRow t in targets) {
        if (!t.installed) continue;
        if (t.level == EcosystemScanLevel.partial) {
          return t.displayName;
        }
      }
      for (final String prefer in <String>['edge', 'chrome']) {
        for (final EcosystemTargetRow t in targets) {
          if (t.id == prefer && t.installed) return t.displayName;
        }
      }
      for (final EcosystemTargetRow t in targets) {
        if (t.installed &&
            t.id != browserId &&
            t.id != 'safari' &&
            t.id != 'safari_ios') {
          return t.displayName;
        }
      }
      return null;
    }();

    String messageKo;
    bool isProblem = false;
    if (browserId == 'unknown') {
      messageKo =
          '기본 브라우저($displayName)는 이 앱이 관리하지 않을 수 있습니다. '
          '차단이 필요하면 설정 → 기본 앱에서 Chrome/Edge 등으로 바꾸세요.';
    } else if (isBlockedOrRisky) {
      isProblem = true;
      messageKo =
          '⚠ PC 기본 브라우저가 **$displayName** 인데, 지금 URL 차단이 약하거나 '
          '자동 종료 대상입니다. 웹 링크가 막히거나 브라우저가 꺼질 수 있어요.\n'
          '기본 앱을 ${suggestName ?? "차단이 적용된 다른 브라우저"}(으)로 바꾸는 것을 권장합니다.';
    } else if (!blockActive && match != null && match.installed) {
      isProblem = true;
      messageKo =
          '기본 브라우저 **$displayName** — URL 차단이 아직 완전하지 않습니다. '
          '「원탭 차단 적용」 후 사용하거나, 기본 앱을 차단 OK인 브라우저로 바꾸세요.';
    } else if (blockActive) {
      messageKo =
          '✅ PC 기본 브라우저 **$displayName** — URL 차단이 적용된 상태입니다. '
          '일반 웹·메일 링크를 쓸 수 있습니다.';
    } else {
      messageKo = '기본 브라우저: $displayName';
    }

    return DefaultBrowserAdvisory(
      browserId: browserId,
      displayName: displayName,
      progId: progId,
      blockActive: blockActive,
      isProblem: isProblem,
      messageKo: messageKo,
      suggestSwitchTo: isProblem ? suggestName : null,
      settingsUri: 'ms-settings:defaultapps',
    );
  }

  Future<String?> _readUserChoiceProgId() async {
    try {
      final ProcessResult pr = await windowsRunHidden(
        _regExe(),
        <String>[
          'query',
          r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice',
          '/v',
          'ProgId',
        ],
      );
      if (pr.exitCode != 0) return null;
      final RegExpMatch? m =
          RegExp(r'ProgId\s+REG_SZ\s+(\S+)').firstMatch('${pr.stdout}');
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readHttpCommandProgId() async {
    try {
      final ProcessResult pr = await windowsRunHidden(
        _regExe(),
        <String>[
          'query',
          r'HKCR\http\shell\open\command',
        ],
      );
      if (pr.exitCode != 0) return null;
      final String out = '${pr.stdout}'.toLowerCase();
      if (out.contains('chrome.exe')) return 'ChromeHTML';
      if (out.contains('msedge.exe')) return 'MSEdgeHTM';
      if (out.contains('firefox.exe')) return 'FirefoxURL';
      if (out.contains('whale.exe')) return 'WhaleHTML';
      if (out.contains('brave.exe')) return 'BraveHTML';
      if (out.contains('vivaldi.exe')) return 'VivaldiHTML';
      if (out.contains('opera.exe')) return 'OperaStable';
      return null;
    } catch (_) {
      return null;
    }
  }
}
