/// Domains always blocked independently of optional user-selected presets.
///
/// Single source of truth so the next UAC 「적용」 regenerates the same
/// sinkhole entries as a manual hosts patch (explicit always-on rules only).
const String kDiagnosticBlockSentinelHost = 'blocked-test.example';

/// Merged into extension rules, PAC, and Windows `hosts` managed region.
/// Adult categories stay in the manual preset and are never added here.
///
/// **NOTE — DO NOT add `youtube.com` / `youtu.be` here.** Build +330 traced
/// the YouTube overblock to those two apex entries being treated as
/// fully-blocked hosts by every downstream sink (hosts, PAC, URLBlocklist,
/// extension `blockedDomains`). Per-channel / per-video YouTube blocks
/// live in `blockedYoutubeHandles`, `blockedYoutubeChannelIds`, and
/// `blockedYoutubeVideoIds` on the extension payload and in
/// `youtubeUrlBlockPatterns()` on the URLBlocklist side — adding the apex
/// here causes "user added one channel → entire YouTube broken".
const List<String> kExtensionBuiltinBlockedDomains = <String>[
  kDiagnosticBlockSentinelHost,
  // User explicitly requested this apex as an always-on site rule.
  'wang004.com',
  // User explicitly reported Firefox access and requested this domain blocked.
  'jusohot7.com',
];
