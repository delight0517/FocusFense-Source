/// One executable to block. We match by [exeName] (case-insensitive); if
/// [windowTitleMatch] is non-empty, we additionally try to kill processes whose
/// main window title contains that substring (also case-insensitive).
///
/// For Chromium-based browsers (chrome / msedge / brave) we further refine
/// matching with [chromeAppId]:
///   - `null`  → not browser-aware (legacy default for non-browser exes).
///   - `_main` → only the main browser, NOT any installed PWAs (Chrome apps).
///   - `<32-char-hash>` → only that specific PWA / Chrome app
///                       (e.g. YouTube Music's id `cinhimbnkkaeohfgghhklpknlkffjgod`).
final class BlockApp {
  const BlockApp({
    required this.exeName,
    required this.displayName,
    this.windowTitleMatch,
    this.chromeAppId,
  });

  /// e.g. "chrome.exe". Always lowercase, always ends with `.exe`.
  final String exeName;

  /// Friendly label used in lists (e.g. "Google Chrome").
  final String displayName;

  /// Optional substring of the main window title. `null`/empty = ignore.
  final String? windowTitleMatch;

  /// Refines matching for Chromium-based browsers. See class doc.
  final String? chromeAppId;

  /// The sentinel meaning "main browser only — exclude PWAs".
  static const String mainBrowserKey = '_main';

  /// Browser exe names we know how to refine with [chromeAppId].
  static const Set<String> browserExes = <String>{
    'chrome.exe',
    'msedge.exe',
    'brave.exe',
    'aside.exe',
  };

  bool get isChromiumBrowser => browserExes.contains(exeName);

  /// Aside ships a same-named CLI; blocking the browser must preserve that tool.
  static bool isAsideCliCommandLine(String commandLine) {
    final text = commandLine.trimLeft();
    final executable = text.startsWith('"')
        ? text.substring(1).split('"').first
        : text.split(RegExp(r'\s')).first;
    return executable
        .replaceAll('/', r'\')
        .toLowerCase()
        .contains(r'\aside\cli\');
  }

  /// True if this entry represents a Chrome-installed app / PWA (has a
  /// 32-char-ish hash app-id, not the [mainBrowserKey] sentinel).
  bool get isPwa =>
      isChromiumBrowser &&
      chromeAppId != null &&
      chromeAppId!.isNotEmpty &&
      chromeAppId != mainBrowserKey;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'exeName': exeName,
    'displayName': displayName,
    if (windowTitleMatch != null && windowTitleMatch!.isNotEmpty)
      'windowTitleMatch': windowTitleMatch,
    if (chromeAppId != null) 'chromeAppId': chromeAppId,
  };

  factory BlockApp.fromJson(Map<String, dynamic> json) {
    final String exe = BlockApp.normalizeExeName(
      json['exeName'] as String? ?? '',
    );
    final String? rawAppId = (json['chromeAppId'] as String?)?.trim();
    final String? appId = (rawAppId == null || rawAppId.isEmpty)
        ? null
        : rawAppId;

    // ---- migration ----------------------------------------------------------
    // Legacy data (pre chromeAppId): a bare "chrome.exe" entry blocked
    // everything including PWAs. The user complaint that motivated this field
    // is "blocking Chrome also blocks my YouTube Music PWA". So on load, we
    // narrow legacy browser entries to "_main" — main browser only. Users
    // who want a PWA blocked add it explicitly from the picker.
    final String? migratedAppId = (appId == null && browserExes.contains(exe))
        ? mainBrowserKey
        : appId;

    return BlockApp(
      exeName: exe,
      displayName: (json['displayName'] as String? ?? '').trim().isEmpty
          ? exe
          : (json['displayName'] as String).trim(),
      windowTitleMatch:
          (json['windowTitleMatch'] as String?)?.trim().isEmpty == true
          ? null
          : (json['windowTitleMatch'] as String?)?.trim(),
      chromeAppId: migratedAppId,
    );
  }

  BlockApp copyWith({
    String? exeName,
    String? displayName,
    String? windowTitleMatch,
    String? chromeAppId,
    bool clearWindowTitle = false,
    bool clearChromeAppId = false,
  }) {
    return BlockApp(
      exeName: exeName ?? this.exeName,
      displayName: displayName ?? this.displayName,
      windowTitleMatch: clearWindowTitle
          ? null
          : (windowTitleMatch ?? this.windowTitleMatch),
      chromeAppId: clearChromeAppId ? null : (chromeAppId ?? this.chromeAppId),
    );
  }

  static String normalizeExeName(String raw) {
    String s = raw.trim();
    if (s.isEmpty) {
      return '';
    }
    s = s.replaceAll('\\', '/').split('/').last;
    if (!s.toLowerCase().endsWith('.exe')) {
      s = '$s.exe';
    }
    return s.toLowerCase();
  }

  /// Extracts a Chrome / Edge `--app-id=<hash>` from a process command line.
  /// Returns null if the command line is null/empty or has no app-id flag,
  /// in which case the caller should treat the process as the main browser.
  static String? extractAppId(String? commandLine) {
    if (commandLine == null) return null;
    final RegExp re = RegExp(r'--app-id=([A-Za-z0-9_\-]+)');
    final RegExpMatch? m = re.firstMatch(commandLine);
    return m?.group(1);
  }

  /// Curated friendly names for well-known executables. We use this when the
  /// raw window title is corrupted (legacy code-page question marks) or is
  /// uninformative (`OLEChannelWnd`, `Default IME`, etc.).
  static const Map<String, String> kKnownExeLabels = <String, String>{
    'chrome': 'Google Chrome',
    'firefox': 'Mozilla Firefox',
    'msedge': 'Microsoft Edge',
    'iexplore': 'Internet Explorer',
    'opera': 'Opera',
    'brave': 'Brave',
    'aside': 'Aside AI Browser',
    'discord': 'Discord',
    'slack': 'Slack',
    'spotify': 'Spotify',
    'steam': 'Steam',
    'epicgameslauncher': 'Epic Games',
    'riotclientservices': 'Riot Client',
    'leagueclient': 'League of Legends',
    'valorant': 'Valorant',
    'overwatch': 'Overwatch',
    'minecraft': 'Minecraft',
    'roblox': 'Roblox',
    'telegram': 'Telegram',
    'kakaotalk': 'KakaoTalk',
    'naverwhale': 'Naver Whale',
    'whale': 'Naver Whale',
    'youtube': 'YouTube',
    'netflix': 'Netflix',
    'notion': 'Notion',
    'obsidian': 'Obsidian',
    'figma': 'Figma',
    'code': 'VS Code',
    'devenv': 'Visual Studio',
    'webstorm': 'WebStorm',
    'pycharm': 'PyCharm',
    'idea': 'IntelliJ IDEA',
    'unity': 'Unity',
    'unreal': 'Unreal Engine',
    'photoshop': 'Photoshop',
    'illustrator': 'Illustrator',
    'blender': 'Blender',
  };

  /// Returns true if [s] looks like garbage from a legacy-codepage transcode:
  /// e.g. "?? ?? - ?? ??? - Mozilla Firefox" or "OLEChannelWnd".
  static bool isCorruptedDisplay(String s) {
    final String t = s.trim();
    if (t.isEmpty) return true;
    // Hidden-window names that mean nothing to a human.
    const Set<String> meaningless = <String>{
      'OLEChannelWnd',
      'Default IME',
      'MSCTFIME UI',
      'GDI+ Window',
    };
    if (meaningless.contains(t)) return true;
    // More than 30% of visible chars are `?`.
    final int qm = '?'.allMatches(t).length;
    final int letters = t.replaceAll(RegExp(r'\s'), '').length;
    if (letters > 0 && qm / letters > 0.3) return true;
    return false;
  }

  /// Best-effort cleanup of a raw display name. Strategy:
  ///   1. If [raw] is corrupted, fall back to the curated label or a
  ///      title-cased exe stem.
  ///   2. Otherwise, strip any `?` runs and the dashes/spaces that surround
  ///      them, e.g. "?? ?? - ?? ??? - Mozilla Firefox" -> "Mozilla Firefox".
  static String prettyDisplayName({
    required String exeName,
    required String raw,
  }) {
    final String stem = exeName.toLowerCase().replaceAll(RegExp(r'\.exe$'), '');
    final String curated = kKnownExeLabels[stem] ?? _titleCase(stem);

    if (isCorruptedDisplay(raw)) return curated;

    // Strip "?" runs and surrounding separators.
    String cleaned = raw;
    cleaned = cleaned.replaceAll(RegExp(r'[?]+'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s*[-–—|·]\s*[-–—|·]+'), ' - ');
    cleaned = cleaned.replaceAll(RegExp(r'^[\s\-–—|·]+'), '');
    cleaned = cleaned.replaceAll(RegExp(r'[\s\-–—|·]+$'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    if (cleaned.isEmpty) return curated;

    // If the cleaned form is just the exe name or one short word, prefer the
    // curated brand label when available.
    if (kKnownExeLabels.containsKey(stem) && cleaned.length < 4) {
      return curated;
    }
    return cleaned;
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
