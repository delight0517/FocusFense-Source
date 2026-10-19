/// Bundled browser extension files (Chrome + Chromium derivatives + Firefox).
abstract final class BrowserExtensionAssetManifest {
  /// Aside has its own branded manifest and protected payload directory.
  /// The Chromium implementation files remain shared with the Chrome build.
  static const List<String> aside = <String>[
    'assets/browser_extensions/aside/manifest.json',
    'assets/browser_extensions/chrome/background.js',
    'assets/browser_extensions/chrome/precision_strike.js',
    'assets/browser_extensions/chrome/content.js',
    'assets/browser_extensions/chrome/content.css',
    'assets/browser_extensions/chrome/youtube_distraction.js',
    'assets/browser_extensions/chrome/youtube_budget_core.js',
    'assets/browser_extensions/chrome/youtube_budget_worker.js',
    'assets/browser_extensions/chrome/youtube_budget_content.js',
    'assets/browser_extensions/chrome/youtube_budget_options.js',
    'assets/browser_extensions/chrome/options.html',
    'assets/browser_extensions/chrome/options.js',
    'assets/browser_extensions/chrome/popup.html',
    'assets/browser_extensions/chrome/popup.css',
    'assets/browser_extensions/chrome/popup.js',
  ];

  static const List<String> chrome = <String>[
    'assets/browser_extensions/chrome/manifest.json',
    'assets/browser_extensions/chrome/background.js',
    'assets/browser_extensions/chrome/precision_strike.js',
    'assets/browser_extensions/chrome/content.js',
    'assets/browser_extensions/chrome/content.css',
    'assets/browser_extensions/chrome/youtube_distraction.js',
    'assets/browser_extensions/chrome/youtube_budget_core.js',
    'assets/browser_extensions/chrome/youtube_budget_worker.js',
    'assets/browser_extensions/chrome/youtube_budget_content.js',
    'assets/browser_extensions/chrome/youtube_budget_options.js',
    'assets/browser_extensions/chrome/options.html',
    'assets/browser_extensions/chrome/options.js',
    'assets/browser_extensions/chrome/popup.html',
    'assets/browser_extensions/chrome/popup.css',
    'assets/browser_extensions/chrome/popup.js',
  ];

  static const List<String> brave = <String>[
    'assets/browser_extensions/brave/manifest.json',
    'assets/browser_extensions/brave/background.js',
    'assets/browser_extensions/brave/precision_strike.js',
    'assets/browser_extensions/brave/content.js',
    'assets/browser_extensions/brave/content.css',
    'assets/browser_extensions/brave/youtube_distraction.js',
    'assets/browser_extensions/brave/options.html',
    'assets/browser_extensions/brave/options.js',
    'assets/browser_extensions/brave/popup.html',
    'assets/browser_extensions/brave/popup.css',
    'assets/browser_extensions/brave/popup.js',
  ];

  static const List<String> opera = <String>[
    'assets/browser_extensions/opera/manifest.json',
    'assets/browser_extensions/opera/background.js',
    'assets/browser_extensions/opera/precision_strike.js',
    'assets/browser_extensions/opera/content.js',
    'assets/browser_extensions/opera/content.css',
    'assets/browser_extensions/opera/youtube_distraction.js',
    'assets/browser_extensions/opera/options.html',
    'assets/browser_extensions/opera/options.js',
    'assets/browser_extensions/opera/popup.html',
    'assets/browser_extensions/opera/popup.css',
    'assets/browser_extensions/opera/popup.js',
  ];

  static const List<String> firefox = <String>[
    'assets/browser_extensions/firefox/manifest.json',
    'assets/browser_extensions/firefox/background.js',
    'assets/browser_extensions/firefox/storage_migration.js',
    'assets/browser_extensions/firefox/precision_strike.js',
    'assets/browser_extensions/firefox/content.js',
    'assets/browser_extensions/firefox/content.css',
    'assets/browser_extensions/firefox/youtube_distraction.js',
    'assets/browser_extensions/firefox/youtube_budget_core.js',
    'assets/browser_extensions/firefox/youtube_budget_worker.js',
    'assets/browser_extensions/firefox/youtube_budget_content.js',
    'assets/browser_extensions/firefox/youtube_budget_options.js',
    'assets/browser_extensions/firefox/options.html',
    'assets/browser_extensions/firefox/options.js',
  ];
}
