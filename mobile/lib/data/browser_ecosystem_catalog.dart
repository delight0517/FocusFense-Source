/// How this browser is protected when installed on Windows.
enum BrowserInstallSupport {
  /// Chrome / Edge — CRX 확장 강제 설치 + URLBlocklist.
  fullExtension,
  /// Firefox — XPI + WebsiteFilter.
  firefoxPack,
  /// 레거시 — Chromium 파생은 [fullExtension]으로 통합됨.
  policyMirror,
  /// Safari 등 — 이 Windows 앱 범위 밖.
  platformOther,
}

/// Install URLs + uninstall hints + honest plugin-readiness copy.
final class BrowserCatalogEntry {
  const BrowserCatalogEntry({
    required this.id,
    required this.displayName,
    this.installUrl,
    required this.uninstallHintKo,
    this.appsSearchName,
    required this.installSupport,
    required this.ifYouInstallKo,
  });

  final String id;
  final String displayName;
  final String? installUrl;
  final String uninstallHintKo;
  /// Windows 설정 → 앱에서 검색할 이름.
  final String? appsSearchName;
  final BrowserInstallSupport installSupport;
  /// 미설치 카드에 보여 줄 솔직한 안내 (설치하면 무엇이 되는지).
  final String ifYouInstallKo;

  /// 설치 시 자동으로 줄 수 있는 **브라우저 확장(플러그인)** 이 있는지.
  bool get pluginSupportReady =>
      installSupport == BrowserInstallSupport.fullExtension ||
      installSupport == BrowserInstallSupport.firefoxPack;

  String get pluginReadyBadgeKo {
    switch (installSupport) {
      case BrowserInstallSupport.fullExtension:
        return '플러그인 준비됨';
      case BrowserInstallSupport.firefoxPack:
        return 'Firefox 확장 준비됨';
      case BrowserInstallSupport.policyMirror:
        return '아직 플러그인 준비 안 됨';
      case BrowserInstallSupport.platformOther:
        return '플러그인 준비 안 됨';
    }
  }

  static BrowserCatalogEntry? forId(String id) {
    for (final BrowserCatalogEntry e in kBrowserCatalog) {
      if (e.id == id) return e;
    }
    if (id == 'opera_gx') return forId('opera');
    return null;
  }
}

const List<BrowserCatalogEntry> kBrowserCatalog = <BrowserCatalogEntry>[
  BrowserCatalogEntry(
    id: 'chrome',
    displayName: 'Google Chrome',
    installUrl: 'https://www.google.com/chrome/',
    appsSearchName: 'Google Chrome',
    uninstallHintKo: '설정 → 앱 → Google Chrome → 제거',
    installSupport: BrowserInstallSupport.fullExtension,
    ifYouInstallKo:
        '설치하면 Focus Fense 확장(CRX) + URLBlocklist가 자동 적용됩니다. '
        '「원탭 차단 적용」 후 사용하세요.',
  ),
  BrowserCatalogEntry(
    id: 'edge',
    displayName: 'Microsoft Edge',
    installUrl: 'https://www.microsoft.com/edge',
    appsSearchName: 'Microsoft Edge',
    uninstallHintKo: '설정 → 앱 → Microsoft Edge → 제거 (또는 Windows 기능 끄기)',
    installSupport: BrowserInstallSupport.fullExtension,
    ifYouInstallKo:
        '설치하면 Edge용 확장 + URLBlocklist가 적용됩니다. 원탭 적용 후 사용하세요.',
  ),
  BrowserCatalogEntry(
    id: 'firefox',
    displayName: 'Firefox',
    installUrl: 'https://www.mozilla.org/firefox/new/',
    appsSearchName: 'Mozilla Firefox',
    uninstallHintKo: '설정 → 앱 → Mozilla Firefox → 제거',
    installSupport: BrowserInstallSupport.firefoxPack,
    ifYouInstallKo:
        '설치하면 sixvpn-blocker XPI + WebsiteFilter가 적용됩니다. '
        'YouTube는 채널·영상만 차단(전체 차단 아님).',
  ),
  BrowserCatalogEntry(
    id: 'whale',
    displayName: 'Naver Whale',
    installUrl: 'https://whale.naver.com/ko/download/win/',
    appsSearchName: 'Whale',
    uninstallHintKo: '설정 → 앱 → Whale → 제거',
    installSupport: BrowserInstallSupport.fullExtension,
    ifYouInstallKo:
        '설치하면 Focus Fense 확장 + URLBlocklist가 자동 적용됩니다. '
        '「원탭 차단 적용」 후 Whale을 완전히 종료하고 다시 여세요.',
  ),
  BrowserCatalogEntry(
    id: 'brave',
    displayName: 'Brave',
    installUrl: 'https://brave.com/download/',
    appsSearchName: 'Brave',
    uninstallHintKo: '설정 → 앱 → Brave → 제거',
    installSupport: BrowserInstallSupport.fullExtension,
    ifYouInstallKo:
        '설치하면 Brave 전용 Focus Fense 확장 + URLBlocklist가 자동 적용됩니다. '
        '「원탭 차단 적용」 후 Brave를 완전히 종료하고 다시 여세요. '
        '차단이 없으면 brave.exe가 강제 종료됩니다.',
  ),
  BrowserCatalogEntry(
    id: 'vivaldi',
    displayName: 'Vivaldi',
    installUrl: 'https://vivaldi.com/download/',
    appsSearchName: 'Vivaldi',
    uninstallHintKo: '설정 → 앱 → Vivaldi → 제거',
    installSupport: BrowserInstallSupport.fullExtension,
    ifYouInstallKo:
        '설치하면 Focus Fense 확장 + URLBlocklist가 자동 적용됩니다. '
        '원탭 적용 후 Vivaldi 완전 종료·재실행.',
  ),
  BrowserCatalogEntry(
    id: 'opera',
    displayName: 'Opera',
    installUrl: 'https://www.opera.com/computer',
    appsSearchName: 'Opera',
    uninstallHintKo: '설정 → 앱 → Opera → 제거',
    installSupport: BrowserInstallSupport.fullExtension,
    ifYouInstallKo:
        '설치하면 Focus Fense 확장 + URLBlocklist가 자동 적용됩니다. '
        '원탭 적용 후 Opera 완전 종료·재실행.',
  ),
];

/// Maps Windows HTTP ProgId → [BrowserCatalogEntry.id].
const Map<String, String> kHttpProgIdToBrowserId = <String, String>{
  'chromehtml': 'chrome',
  'chromiumhtml': 'chrome',
  'msedgehtm': 'edge',
  'msedgeht': 'edge',
  'firefoxurl': 'firefox',
  'firefoxurl-utf8': 'firefox',
  'naverwhalehtml': 'whale',
  'whalehtml': 'whale',
  'bravehtml': 'brave',
  'vivaldihtml': 'vivaldi',
  'operastable': 'opera',
  'operagxstable': 'opera',
};
