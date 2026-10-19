/// Allow-list of *in-browser apps* that must keep working even while the
/// underlying browser (Chrome / Edge / …) is otherwise "blocked".
///
/// WHY THIS EXISTS (2026-06-21 incident — see
/// `docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md` §"브라우저 통째 종료"):
/// A schedule / quick-block entry that targets the *whole browser*
/// (`win|chrome.exe|_main`, or a stray window-title row `"Google Chrome"`)
/// makes the native kill path run `taskkill *Google Chrome*` /
/// `taskkill /PID <main chrome>`. Because **every Chrome window title ends in
/// "- Google Chrome"** and **all tabs share one browser process**, that nukes
/// Gemini, Gmail, Google 로그인, YouTube Music — apps the user explicitly
/// wants to keep using — not just the bad site.
///
/// The only layer that can block one tab while leaving another open is the
/// extension (declarativeNetRequest). So the rule the native layer must obey
/// is: **never process-kill a browser while an allow-listed app window is
/// open in it.** The extension still blocks disallowed URLs per-tab.
///
/// This catalog is the single source of truth for "which in-browser apps are
/// allowed". Both Dart kill sites and the generated PowerShell guard scripts
/// (`browser_realtime_guard.ps1`) consult it (via the sidecar written by
/// [BrowserAppAllowlistService]).
library;

/// One allow-listed in-browser app.
class AllowedBrowserApp {
  const AllowedBrowserApp({
    required this.id,
    required this.displayName,
    required this.titleTokens,
    required this.domains,
  });

  final String id;
  final String displayName;

  /// Lower-case substrings matched against a browser window title. A window
  /// whose title contains any of these is treated as this allowed app.
  final List<String> titleTokens;

  /// Hostnames this app lives on. Used so the extension/URL layer can allow
  /// these even when general browsing is blocked (incl. the Google login flow
  /// that Gemini/Gmail need: accounts.google.com).
  final List<String> domains;
}

/// Built-in allow-list. Defaults cover the apps the user named (Gemini,
/// YouTube Music) plus the Google services they depend on (Gmail, Google
/// account login — Gemini cannot sign in without accounts.google.com).
final class AllowedBrowserAppCatalog {
  AllowedBrowserAppCatalog._();

  static const List<AllowedBrowserApp> builtIn = <AllowedBrowserApp>[
    AllowedBrowserApp(
      id: 'gemini',
      displayName: 'Google Gemini',
      titleTokens: <String>['gemini'],
      domains: <String>['gemini.google.com'],
    ),
    AllowedBrowserApp(
      id: 'gmail',
      displayName: 'Gmail',
      // "Gmail - …", Korean inbox title "받은편지함".
      titleTokens: <String>['gmail', '받은편지함'],
      domains: <String>['mail.google.com'],
    ),
    AllowedBrowserApp(
      id: 'google_login',
      // Gemini/Gmail sign-in flow. Without this the user "cannot log in".
      displayName: 'Google 로그인 / 계정',
      titleTokens: <String>[
        'google 계정',
        'google account',
        'sign in - google',
        '로그인 - google',
        '계정 선택',
        'accounts.google',
      ],
      domains: <String>['accounts.google.com', 'myaccount.google.com'],
    ),
    AllowedBrowserApp(
      id: 'youtube_music',
      // ONLY YouTube Music — regular "YouTube" stays blockable.
      displayName: 'YouTube Music',
      titleTokens: <String>['youtube music'],
      domains: <String>['music.youtube.com'],
    ),
  ];

  /// Generic browser *brand* window titles. A block entry whose
  /// window-title-match is one of these means "the whole browser", which the
  /// native layer must NEVER `taskkill` by title (it would match every window,
  /// incl. allowed apps). Compared case-insensitively, exact match.
  static const Set<String> genericBrowserBrandTitles = <String>{
    'google chrome',
    'chrome',
    'microsoft edge',
    'msedge',
    'edge',
    'mozilla firefox',
    'firefox',
    'brave',
    'naver whale',
    'whale',
    'vivaldi',
    'opera',
    'chromium',
  };

  /// True if [windowTitle] belongs to an allow-listed in-browser app.
  static bool isAllowedWindowTitle(String windowTitle) {
    final String t = windowTitle.toLowerCase().trim();
    if (t.isEmpty) return false;
    for (final AllowedBrowserApp app in builtIn) {
      for (final String tok in app.titleTokens) {
        if (tok.isNotEmpty && t.contains(tok)) return true;
      }
    }
    return false;
  }

  /// True if [titleSubstring] is a bare browser brand name (→ block targets the
  /// whole browser, which must not be killed by a window-title substring).
  static bool isGenericBrowserBrand(String titleSubstring) {
    return genericBrowserBrandTitles.contains(titleSubstring.trim().toLowerCase());
  }

  /// Flat list of every allow title token (for the PowerShell sidecar).
  static List<String> allTitleTokens() => <String>[
        for (final AllowedBrowserApp a in builtIn) ...a.titleTokens,
      ];

  /// Flat list of every allowed domain.
  static List<String> allDomains() => <String>[
        for (final AllowedBrowserApp a in builtIn) ...a.domains,
      ];
}
