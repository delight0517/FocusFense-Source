/// Five cross-browser URL-block leak scenarios the app actively seals.
enum CrossBrowserLeakScenario {
  /// User launches `chrome.exe` / taskbar pin / Win+Search without VBS flags.
  plainBrowserLaunch,

  /// Whale / Brave / Opera / Edge Beta — Chrome blocked but derivative is not.
  derivativeChromiumGap,

  /// Firefox DoH or Private Browsing skips hosts / PAC / extension.
  firefoxDohOrPrivate,

  /// Secure DNS, QUIC, or built-in DNS resolves before PAC / URLBlocklist.
  networkStackBypass,

  /// URLAllowlist overrides blocklist, Incognito, or Edge IE Mode.
  policyPrecedenceBypass,
}

extension CrossBrowserLeakScenarioLabels on CrossBrowserLeakScenario {
  String get title {
    switch (this) {
      case CrossBrowserLeakScenario.plainBrowserLaunch:
        return '순정 브라우저 직접 실행';
      case CrossBrowserLeakScenario.derivativeChromiumGap:
        return '파생 Chromium 격차';
      case CrossBrowserLeakScenario.firefoxDohOrPrivate:
        return 'Firefox DoH·프라이빗';
      case CrossBrowserLeakScenario.networkStackBypass:
        return 'DNS·QUIC 네트워크 우회';
      case CrossBrowserLeakScenario.policyPrecedenceBypass:
        return '정책 역우선·시크릿';
    }
  }

  String get remedy {
    switch (this) {
      case CrossBrowserLeakScenario.plainBrowserLaunch:
        return '바로가기→VBS, HKCU Start Menu override, soft handoff';
      case CrossBrowserLeakScenario.derivativeChromiumGap:
        return 'Whale/Brave/Opera/EdgeBeta에 URLBlocklist+PAC 동기화';
      case CrossBrowserLeakScenario.firefoxDohOrPrivate:
        return 'DoH OFF + WebsiteFilter + PAC autoconfig(user.js)';
      case CrossBrowserLeakScenario.networkStackBypass:
        return 'BuiltInDnsClient=0, DnsOverHttps=off, QuicAllowed=0 (전 루트)';
      case CrossBrowserLeakScenario.policyPrecedenceBypass:
        return 'URLAllowlist 청소, 시크릿 비활성, IE Mode OFF';
    }
  }
}

final class CrossBrowserLeakGuardReport {
  const CrossBrowserLeakGuardReport({
    required this.ok,
    required this.message,
    required this.sealed,
    required this.steps,
  });

  final bool ok;
  final String message;
  final List<CrossBrowserLeakScenario> sealed;
  final List<String> steps;
}
