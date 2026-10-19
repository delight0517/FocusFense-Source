import 'dart:convert';
import 'dart:io';
import '../enforcement/layers/browser_policy_layer.dart';

import 'package:path/path.dart' as p;

import 'browser_enforcement_readiness_service.dart';
import 'browser_youtube_policy_split.dart';
import 'youtube_enforcement_hosts.dart';
import 'connection_url_block_pattern_builder.dart';
import 'extension_rules_builder.dart';
import 'windows_browser_bypass_closer_service.dart';
import 'windows_chromium_registry_service.dart';
import 'mac_system_block_service.dart';
import '../utils/numeric_suffix_evasion.dart';

/// Chrome / Edge enterprise policies (DNS off + URL blocklist).
/// Installed beside Firefox policy during elevated hosts apply on Windows.
final class ChromiumPolicyService {
  ChromiumPolicyService._();
  static final ChromiumPolicyService instance = ChromiumPolicyService._();

  // Chrome / Edge URLBlocklist documents support up to 1000 entries. We use
  // the full ceiling so every handle the user adds Ã¢â‚¬â€ including alphabetically
  // late ones (uthermal, winterstarcraft) and the camelCase / TitleCase
  // variants we emit per handle Ã¢â‚¬â€ fits without being silently dropped.
  // Each handle generates ~50 patterns (3-5 case variants Ãƒâ€” ~14 URL surfaces),
  // so 14 channels alone push past 700; the previous 800 cap dropped late
  // handles. 1000 covers ~18 channels + ~4 videos comfortably.
  static const int _kMaxBlocklistEntries = 1000;
  // Do not let YouTube URL variants consume the entire Chrome/Edge policy.
  // In build +372 the policy file had 1000 YouTube rows and 0 adult-site
  // rows, so subdomains such as 16.xbbg.tv depended only on PAC refresh.
  static const int _kYoutubePolicyBudget = 360;

  /// Active blocklist patterns Ã¢â‚¬â€ shared by JSON file and registry installers.
  static Future<List<String>> activeBlocklistPatterns({DateTime? at}) async {
    final ExtensionRulesPayload payload =
        await ExtensionRulesBuilder.buildForBrowserEnforcement(at: at);
    final List<String> blocklist = <String>[];
    final Set<String> seen = <String>{};

    void add(String pattern) {
      final String p = pattern.trim();
      if (p.isEmpty || !seen.add(p)) return;
      blocklist.add(p);
    }

    final Set<String> apexHosts = <String>{};
    String? canonicalApex(String raw) {
      final String h = MacSystemBlockService.canonicalHost(raw);
      if (h.isEmpty || !apexHosts.add(h)) return null;
      return h;
    }

    void addHostSubdomainWildcard(String host) {
      if (blocklist.length >= _kMaxBlocklistEntries) return;
      // URLBlocklist uses host filters, not extension match-pattern syntax.
      // A bare host covers the apex and its subdomains.
      add(host);
    }

    void addHostApex(String host) {
      if (blocklist.length >= _kMaxBlocklistEntries) return;
      add(host);
    }

    void addNumericStemPolicyFilters(
      String stem, {
      int maxHosts = 8,
      bool reserveConcreteApex = false,
    }) {
      if (reserveConcreteApex) {
        for (final String h in NumericSuffixEvasion.priorityConcreteApexForStem(
          stem,
          maxHosts: 180,
        )) {
          final String? c = canonicalApex(h);
          if (c == null) continue;
          if (blocklist.length >= _kMaxBlocklistEntries) break;
          addHostSubdomainWildcard(c);
          if (blocklist.length >= _kMaxBlocklistEntries) break;
          addHostApex(c);
        }
      }
      for (final String pat
          in NumericSuffixEvasion.chromiumPolicyHostFiltersForStem(
            stem,
            maxHosts: maxHosts,
          )) {
        if (blocklist.length >= _kMaxBlocklistEntries) break;
        add(pat);
      }
    }

    // YouTube remains high priority, but it cannot consume all 1000 policy
    // rows. Extension + PAC still handle the long tail; URLBlocklist must keep
    // room for adult/preset site subdomains such as 16.xbbg.tv.
    for (final String yt in youtubeUrlBlockPatterns(payload)) {
      if (blocklist.length >= _kMaxBlocklistEntries ||
          blocklist.length >= _kYoutubePolicyBudget) {
        break;
      }
      add(yt);
    }

    // Numeric-stem mirrors (linkdamoa01.com, mingky01.live) are common
    // bypass surfaces when the user explicitly enables a preset. Keep them before bulk lists so
    // Chrome's 1000-row URLBlocklist cap cannot silently drop them.
    for (final String stem in payload.numericStemHosts) {
      if (blocklist.length >= _kMaxBlocklistEntries) break;
      addNumericStemPolicyFilters(
        stem,
        maxHosts: 24,
        reserveConcreteApex: true,
      );
    }

    final List<String> scheduleHosts = <String>[];
    for (final String host in payload.blockedDomains) {
      final String? h = canonicalApex(host);
      if (h != null) scheduleHosts.add(h);
    }
    // O(n) parent/numeric-child detection — was O(n^2) with a freshly
    // compiled RegExp per pair (`scheduleHosts.any(...RegExp...)` inside a
    // loop over scheduleHosts). At 2000+ schedule domains (merged adult
    // preset pushed this well past what used to be a small list) that
    // nested-regex pass hung the UI isolate for minutes — Windows reported
    // the window "Not Responding" because this synchronous work never
    // yielded to the message pump. Single pass: for each host, look at its
    // own immediate parent suffix and check set membership instead of
    // scanning every other host.
    final Set<String> scheduleHostSet = scheduleHosts.toSet();
    final Set<String> parentWildcardHostSet = <String>{};
    final Set<String> numericChildParentHostSet = <String>{};
    final List<String> parentWildcardHosts = <String>[];
    final List<String> numericChildParentHosts = <String>[];
    for (final String h in scheduleHosts) {
      final int firstDot = h.indexOf('.');
      if (firstDot <= 0) continue;
      final String suffix = h.substring(firstDot + 1);
      if (suffix.isEmpty || !scheduleHostSet.contains(suffix)) continue;
      if (parentWildcardHostSet.add(suffix)) {
        parentWildcardHosts.add(suffix);
      }
      final String label = h.substring(0, firstDot);
      final bool isNumericLabel =
          label.isNotEmpty &&
          label.codeUnits.every((int c) => c >= 0x30 && c <= 0x39);
      if (isNumericLabel && numericChildParentHostSet.add(suffix)) {
        numericChildParentHosts.add(suffix);
      }
    }
    final List<String> orderedScheduleHosts = <String>[
      ...numericChildParentHosts,
      ...parentWildcardHosts,
      for (final String h in scheduleHosts)
        if (!numericChildParentHostSet.contains(h) &&
            !parentWildcardHostSet.contains(h))
          h,
    ];

    // Rotating adult mirrors often use numeric subdomains under a stable
    // parent (`14.xbbg.tv`, `16.xbbg.tv`, ...). Give those exact hosts a
    // reserved front slot so Chrome's 1000-row URLBlocklist cap cannot push
    // them out behind bulk preset domains.
    for (final String h in numericChildParentHosts.take(4)) {
      if (blocklist.length >= _kMaxBlocklistEntries) break;
      addHostApex(h);
      for (int i = 1; i <= 99; i++) {
        if (blocklist.length >= _kMaxBlocklistEntries) break;
        addHostApex('$i.$h');
      }
    }

    // Coverage-first pass: one URLBlocklist row per apex blocks subdomains.
    // hosts/PAC cover the bare apex; any remaining rows add bare-apex backup.
    for (final String h in orderedScheduleHosts) {
      if (blocklist.length >= _kMaxBlocklistEntries) break;
      addHostSubdomainWildcard(h);
    }
    for (final String h in orderedScheduleHosts) {
      if (blocklist.length >= _kMaxBlocklistEntries) break;
      addHostApex(h);
    }

    // Explicit built-ins such as wang004.com are in the payload; optional
    // adult categories are included there only while their user switch is on.
    for (final String builtin in kExtensionBuiltinBlockedDomains) {
      if (blocklist.length >= _kMaxBlocklistEntries) break;
      final String c = MacSystemBlockService.canonicalHost(builtin);
      if (c.isEmpty ||
          c == kDiagnosticBlockSentinelHost ||
          YoutubeEnforcementHosts.isYoutubeSiteApex(c)) {
        continue;
      }
      final String? h = canonicalApex(builtin);
      if (h == null) continue;
      addHostSubdomainWildcard(h);
      if (blocklist.length >= _kMaxBlocklistEntries) break;
      addHostApex(h);
    }

    // Adult mirror stems are intentionally lower priority than user-entered
    // domains and numeric stems. The extension also enforces the full stem
    // patterns; reserve only a small policy slice for concrete host mirrors.
    for (final String stem in payload.adultNumericStemHosts) {
      if (blocklist.length >= _kMaxBlocklistEntries) break;
      addNumericStemPolicyFilters(stem, maxHosts: 8);
    }

    // Keyword path/query patterns -- lowest priority (truncate first).
    for (final String urlPat
        in ConnectionUrlBlockPatternBuilder.urlBlocklistPatterns(payload)) {
      if (blocklist.length >= _kMaxBlocklistEntries) break;
      add(urlPat);
    }
    return blocklist;
  }

  /// True when **any** Chromium browser has the MV3 extension (legacy batch path).
  static Future<bool> extensionHandlesYoutubeOnChromium() async {
    final Map<String, BrowserEnforcementReadiness> snap =
        await BrowserEnforcementReadinessService.instance.snapshot();
    return snap.values.any(
      (BrowserEnforcementReadiness r) => r.youtubeListOnlyMode,
    );
  }

  /// Per-browser: extension ready Ã¢â€ â€™ list-only YouTube (no apex in URLBlocklist).
  static Future<bool> extensionHandlesYoutubeForBrowser(
    String browserId,
  ) async {
    final Map<String, BrowserEnforcementReadiness> snap =
        await BrowserEnforcementReadinessService.instance.snapshot();
    return snap[browserId]?.youtubeListOnlyMode ?? false;
  }

  /// Chromium URLBlocklist for one browser, preserving explicit user scope.
  static Future<List<String>> activeBlocklistPatternsForChromiumBrowser(
    String browserId, {
    bool? extensionHandlesYoutube,
    DateTime? at,
  }) async {
    final List<String> base = await activeBlocklistPatterns(at: at);
    // The base contains a YouTube apex only when explicitly selected. Extension
    // availability must neither invent a whole-site block nor erase that choice.
    return BrowserYoutubePolicySplit.withYoutubeApexEnsured(base);
  }

  /// Chromium (Chrome/Edge/derivatives): never widen a channel to a whole site.
  static Future<List<String>> activeBlocklistPatternsForChromium({
    bool? extensionHandlesYoutube,
    DateTime? at,
  }) async {
    return activeBlocklistPatternsForChromiumBrowser(
      'chrome',
      extensionHandlesYoutube: extensionHandlesYoutube,
      at: at,
    );
  }

  /// Firefox uses the same explicitly selected scope as Chromium.
  static Future<List<String>> activeBlocklistPatternsForFirefox({
    DateTime? at,
  }) async {
    final List<String> base = await activeBlocklistPatterns(at: at);
    return firefoxMatchPatterns(base);
  }

  /// WebsiteFilter requires WebExtension match patterns, while Chromium accepts
  /// bare host filters. Passing bare hosts to Firefox silently loses site blocks.
  static List<String> firefoxMatchPatterns(Iterable<String> filters) {
    final Set<String> result = <String>{};
    for (final String raw in filters) {
      String host = raw.trim();
      if (host.isEmpty) continue;
      if (host == '<all_urls>' || host.contains('://')) {
        result.add(host);
      } else {
        bool exact = host.startsWith('.');
        if (host.startsWith('[*.]')) host = host.substring(4);
        if (host.startsWith('*.')) host = host.substring(2);
        if (host.startsWith('.')) host = host.substring(1);
        if (host.isEmpty || RegExp(r'[\s/*?#]').hasMatch(host)) {
          throw FormatException('Invalid Firefox host filter: $raw');
        }
        exact =
            exact ||
            host.contains(':') ||
            RegExp(r'^\d+(?:\.\d+){3}$').hasMatch(host);
        result.add('*://${exact ? '' : '*.'}$host/*');
      }
      if (result.length >= _kMaxBlocklistEntries) break;
    }
    return result.toList(growable: false);
  }

  /// Video IDs parsed from user keywords Ã¢â‚¬â€ must lead URLBlocklist (not AÃ¢â‚¬â€œZ sort).
  static Set<String> keywordYoutubeVideoIds(ExtensionRulesPayload payload) {
    final Set<String> videoIds = <String>{};
    final List<String> idSource = payload.rawKeywords.isNotEmpty
        ? payload.rawKeywords
        : payload.keywords;
    for (final String k in idSource) {
      RegExpMatch? m = RegExp(
        r'(?:^|[?&]v=)([\w-]{6,})',
        caseSensitive: false,
      ).firstMatch(k);
      if (m != null) videoIds.add(m.group(1)!);
      m = RegExp(r'youtu\.be/([\w-]{6,})', caseSensitive: false).firstMatch(k);
      if (m != null) videoIds.add(m.group(1)!);
      m = RegExp(r'/shorts/([\w-]{6,})', caseSensitive: false).firstMatch(k);
      if (m != null) videoIds.add(m.group(1)!);
      m = RegExp(r'/embed/([\w-]{6,})', caseSensitive: false).firstMatch(k);
      if (m != null) videoIds.add(m.group(1)!);
    }
    return videoIds;
  }

  /// All YouTube video IDs from keywords + explicit `blockedYoutubeVideoIds`.
  static Set<String> collectYoutubeVideoIds(ExtensionRulesPayload payload) {
    final Set<String> videoIds = <String>{...payload.blockedYoutubeVideoIds};
    final List<String> idSource = payload.rawKeywords.isNotEmpty
        ? payload.rawKeywords
        : payload.keywords;
    for (final String k in idSource) {
      RegExpMatch? m = RegExp(
        r'(?:^|[?&]v=)([\w-]{6,})',
        caseSensitive: false,
      ).firstMatch(k);
      if (m != null) videoIds.add(m.group(1)!);
      m = RegExp(r'youtu\.be/([\w-]{6,})', caseSensitive: false).firstMatch(k);
      if (m != null) videoIds.add(m.group(1)!);
      m = RegExp(r'/shorts/([\w-]{6,})', caseSensitive: false).firstMatch(k);
      if (m != null) videoIds.add(m.group(1)!);
    }
    return videoIds;
  }

  /// Chrome/Edge/Firefox HKCU URLBlocklist entries for YouTube channel + video rules.
  static List<String> youtubeUrlBlockPatterns(ExtensionRulesPayload payload) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};

    void add(String pattern) {
      final String p = pattern.trim();
      if (p.isEmpty || out.length >= _kMaxBlocklistEntries || !seen.add(p)) {
        return;
      }
      out.add(p);
    }

    void addVideoPatterns(String rawVid) {
      if (out.length >= _kMaxBlocklistEntries) return;
      final String original = rawVid.trim();
      if (original.isEmpty) return;
      // YouTube video IDs ARE case-sensitive Ã¢â‚¬â€ `9zz_j97kDIY` and
      // `9zz_j97kdiy` resolve to DIFFERENT videos. Chrome / Edge / Firefox
      // URLBlocklist match patterns byte-compare against the URL the browser
      // sees, so a lowercased pattern silently fails to match a mixed-case
      // ID in the address bar.
      //
      // Build +331 traced the YouTube channel-specific block regression to
      // an earlier "optimization" that lowercased everything. We emit BOTH
      // the original case AND the lowercased form so that:
      //   * URLs pasted in canonical case match immediately
      //   * URLs the user typed all-lowercase still hit
      //
      // Density: up to 8 patterns/video (was 4). With ~250 user videos this
      // still fits in the 1000-entry cap; mandatory + handles emit first
      // anyway (see ordering in caller).
      //
      // See docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md Ã‚Â§2.1 +
      // test/youtube_block_pipeline_test.dart (video id case-preserved case).
      // #intent:user-video
      for (final String v in <String>{original, original.toLowerCase()}) {
        if (v.isEmpty || !seen.add('ytvid:$v')) continue;
        add('*://*.youtube.com/watch?v=$v*');
        add('*://youtube.com/watch?v=$v*');
        add('*://*.youtube.com/shorts/$v*');
        add('*://*.youtube.com/embed/$v*');
        add('*://*.youtube-nocookie.com/embed/$v*');
        add('*://youtu.be/$v*');
      }
    }

    void addHandlePatterns(String handle) {
      if (out.length >= _kMaxBlocklistEntries) return;
      // Emit BOTH the original-case and lowercased handle. URL match patterns
      // are case-sensitive for the path component (Chrome/Edge/Firefox docs);
      // YouTube serves `@SC2HL` with its actual case, so `@sc2hl` alone fails
      // to match. The pair covers user-typed case + YouTube's canonical case.
      //
      // Also emit a percent-encoded (UTF-8) variant for non-ASCII handles
      // (Korean / Japanese / Chinese). YouTube serves a Korean `@Ã«Â³Â´Ã«â€Â°` URL
      // as `@%EB%B3%B4%EB%94%B0` in the actual URL bar / network layer, and
      // Chrome's URLBlocklist compares the pattern against the encoded URL Ã¢â‚¬â€
      // so a raw-unicode pattern silently fails to block it.
      //
      // See docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md Ã‚Â§2.1 + the regression
      // test in test/youtube_block_pipeline_test.dart (@Ã«Â³Â´Ã«â€Â° case).
      // Common case combinations for handles. Users often type a channel
      // handle all-lowercase, but YouTube actually serves it with the
      // channel-owner's chosen case (e.g. `@uThermal` Ã¢â‚¬â€ lowercase u, uppercase
      // T). URL match patterns are case-sensitive in the path, so we have
      // to emit the handful of common variants we can reasonably guess:
      //
      //   handle                   (as-typed)
      //   handle.toLowerCase()     (canonical lowercase)
      //   handle.toUpperCase()     (rare; some channels use ALL CAPS)
      //   TitleCase variant        (first letter upper, rest lower Ã¢â‚¬â€ extremely common)
      //   uTitle variant           (lowercase first + uppercased second word boundary Ã¢â‚¬â€
      //                              covers patterns like `uThermal`)
      //
      // True mixed-case `uThermal` from a lowercase-typed `uthermal` can't be
      // recovered without a heuristic; the in-app extension content script
      // remains the authoritative case-insensitive layer.
      final Set<String> handleForms = <String>{
        handle,
        handle.toLowerCase(),
        handle.toUpperCase(),
      };
      // Title case: "uthermal" -> "Uthermal", "SC2HL" -> "Sc2hl".
      if (handle.length >= 2) {
        handleForms.add(
          handle.substring(0, 1).toUpperCase() +
              handle.substring(1).toLowerCase(),
        );
      }
      // "uType" pattern: lowercase first letter + uppercase second letter.
      // Heuristic for handles like `uThermal`, `iPhoneNews`, `eSports`,
      // where the first char is a deliberate lowercase prefix. Only safe
      // for ASCII letters; bail on anything non-letter.
      if (handle.length >= 2 && RegExp(r'^[a-zA-Z]+$').hasMatch(handle)) {
        handleForms.add(
          handle.substring(0, 1).toLowerCase() +
              handle.substring(1, 2).toUpperCase() +
              handle.substring(2).toLowerCase(),
        );
      }
      for (final String h in handleForms.toList()) {
        final String enc = _percentEncodeUtf8(h);
        if (enc != h) {
          handleForms.add(enc);
          handleForms.add(enc.toLowerCase());
          handleForms.add(enc.toUpperCase());
        }
      }
      for (final String h in handleForms) {
        if (h.isEmpty) continue;
        // Density: 4 patterns per case form (was 13). The wildcard
        // `*://*.youtube.com/...` matches www / m / music subdomains in a
        // single pattern. Bare `youtube.com` (no subdomain) needs its own
        // pattern because Chrome's match pattern wildcard `*.` requires
        // at least one subdomain segment.
        //
        // The old per-form 13-pattern emit pushed total entries past 1000
        // for users with >10 channels, and alphabetically late handles
        // (uthermal, winterstarcraft) silently fell off the URLBlocklist
        // cap. Collapsing to 4 keeps every channel + every video covered.
        add('*://*.youtube.com/@$h*');
        add('*://*.youtube.com/c/$h*');
        add('*://*.youtube.com/user/$h*');
        add('*://youtube.com/@$h*');
      }
    }

    // Handles + channel IDs BEFORE videos Ã¢â‚¬â€ 1000-entry cap must never drop
    // mandatory @channels (winterstarcraft, etc.) behind bulk video fetch IDs.
    for (final String handle in payload.blockedYoutubeHandles) {
      addHandlePatterns(handle);
      if (out.length >= _kMaxBlocklistEntries) break;
    }

    for (final String cid in payload.blockedYoutubeChannelIds) {
      if (out.length >= _kMaxBlocklistEntries) break;
      for (final String c in <String>{cid, cid.toLowerCase()}) {
        add('https://www.youtube.com/channel/$c');
        add('*://www.youtube.com/channel/$c*');
        add('*://m.youtube.com/channel/$c*');
        add('*://youtube.com/channel/$c*');
        add('*://music.youtube.com/channel/$c*');
      }
    }

    for (final String vid in payload.blockedYoutubeVideoIds) {
      addVideoPatterns(vid);
      if (out.length >= _kMaxBlocklistEntries) break;
    }
    for (final String vid in keywordYoutubeVideoIds(payload)) {
      addVideoPatterns(vid);
      if (out.length >= _kMaxBlocklistEntries) break;
    }

    return out;
  }

  /// Handle path tokens for PAC / policy (decoded + percent-encoded UTF-8).
  static List<String> youtubeHandlePacForms(String handle) {
    final Set<String> forms = <String>{handle.toLowerCase()};
    final String enc = _percentEncodeUtf8(handle);
    if (enc != handle) {
      forms.add(enc);
      forms.add(enc.toLowerCase());
    }
    return forms.toList();
  }

  /// Percent-encode every non-ASCII byte of [value] (UTF-8) using uppercase
  /// hex (RFC 3986). ASCII bytes pass through unchanged so existing patterns
  /// like `@SC2HL` are not double-encoded.
  static String _percentEncodeUtf8(String value) {
    if (value.isEmpty) return value;
    final List<int> bytes = utf8.encode(value);
    final StringBuffer sb = StringBuffer();
    for (final int b in bytes) {
      if (b < 0x80) {
        sb.writeCharCode(b);
      } else {
        sb.write('%');
        sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
    }
    return sb.toString();
  }

  /// Chrome/Edge policy JSON from active DB rules.
  static Future<String> buildPolicyJson() async {
    final List<String> blocklist = await activeBlocklistPatterns();
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'DnsOverHttpsMode': 'off',
      'BuiltInDnsClientEnabled': false,
      'URLBlocklist': blocklist,
    });
  }

  /// Paths written during elevated hosts merge (see [WindowsSystemBlockService]).
  static List<String> windowsPolicyDestinations() {
    final String pf =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final String pf86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    return <String>[
      p.join(pf, 'Google', 'Chrome', 'Application', 'policies', 'managed'),
      p.join(pf86, 'Google', 'Chrome', 'Application', 'policies', 'managed'),
      p.join(pf, 'Microsoft', 'Edge', 'Application', 'policies', 'managed'),
      p.join(pf86, 'Microsoft', 'Edge', 'Application', 'policies', 'managed'),
    ];
  }

  /// PowerShell fragment that writes Chromium/Edge policies via the
  /// **registry** (`HKLM\Software\Policies\Google\Chrome` and
  /// `HKLM\Software\Policies\Microsoft\Edge`).
  ///
  /// This is critical because the JSON `policies\managed\*.json` files are
  /// only read by Chrome/Edge installed under `Program Files`. User-installed
  /// Chrome (`%LOCALAPPDATA%\Google\Chrome`) ignores them Ã¢â‚¬â€ but it always
  /// honors `HKLM\Software\Policies\Ã¢â‚¬Â¦`. Result: `BuiltInDnsClientEnabled=0`
  /// actually takes effect, forcing Chrome through Windows DNS Client / NRPT.
  static Future<String> elevatedRegistryPolicyFragment() async {
    return buildOwnedRegistryPolicyFragment(await activeBlocklistPatterns());
  }

  static const _elevatedDnsRoots = <String>[
    r'HKLM:\SOFTWARE\Policies\Google\Chrome',
    r'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
    r'HKLM:\SOFTWARE\Policies\Chromium',
  ];
  static String get _dnsOwnershipPath => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'SixVPNBlocker',
    'owned_elevated_dns_v1.json',
  );
  static String get _protectionOffPath => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'SixVPNBlocker',
    'protection_disabled_v1.json',
  );
  static String _ownedDnsFragment(
    List<String> roots,
    String journal,
    String marker,
  ) => BrowserPolicyLayer.ownedPacPowerShell(
    journalPath: journal,
    offMarkerPath: marker,
    values: [
      for (final root in roots) ...[
        {
          'key': root,
          'name': 'BuiltInDnsClientEnabled',
          'kind': 'DWord',
          'value': 0,
        },
        {
          'key': root,
          'name': 'DnsOverHttpsMode',
          'kind': 'String',
          'value': 'off',
        },
      ],
    ],
  );

  static String buildOwnedRegistryPolicyFragment(
    List<String> patterns, {
    String? journalPath,
    List<String>? policyRoots,
    String? dnsJournalPath,
    String? offMarkerPath,
  }) {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final roots = policyRoots ?? _elevatedDnsRoots;
    final dnsJournal =
        dnsJournalPath ??
        (journalPath == null ? _dnsOwnershipPath : '$journalPath.dns');
    final marker = offMarkerPath ?? _protectionOffPath;
    return BrowserPolicyLayer.ownedListsPowerShell(
          journalPath: journalPath,
          policyRoots: policyRoots,
        ) +
        _ownedDnsFragment(roots, dnsJournal, marker) +
        '\nif (Test-Path -LiteralPath ${quote(marker)}) { throw \'FocusFense protection is OFF\' }\n' +
        "if (-not (Invoke-FFPacApply)) { throw 'FocusFense DNS apply interrupted by OFF' }\n" +
        "\n\$ffApplyPatterns = @(" +
        patterns.map(quote).join(',') +
        ")\n" +
        "foreach (\$root in @(" +
        roots.map(quote).join(',') +
        ")) {\n" +
        r'''
  if (Test-Path -LiteralPath $ffPacOff) { throw 'FocusFense protection is OFF' }
  Set-FFOwnedList -key (Join-Path $root 'URLBlocklist') -patterns $ffApplyPatterns
}
''';
  }

  /// Removes the policy keys this app sets. Leaves the hive itself intact in
  /// case the user/admin has other policies under it.
  static String elevatedRegistryPolicyRemoveFragment({
    String? journalPath,
    List<String>? policyRoots,
    String? dnsJournalPath,
    String? offMarkerPath,
  }) {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final roots = policyRoots ?? _elevatedDnsRoots;
    final dnsJournal =
        dnsJournalPath ??
        (journalPath == null ? _dnsOwnershipPath : '$journalPath.dns');
    return BrowserPolicyLayer.ownedListsPowerShell(
          journalPath: journalPath,
          policyRoots: policyRoots,
        ) +
        _ownedDnsFragment(
          roots,
          dnsJournal,
          offMarkerPath ?? _protectionOffPath,
        ) +
        "\n\$ffRestoreFailures = @()\n" +
        "try { Restore-FFOwnedLists } catch { \$ffRestoreFailures += 'site policies' }\n" +
        'try { Restore-FFPac -selectedKeys @(${roots.map(quote).join(',')}) } catch { \$ffRestoreFailures += \'DNS policies\' }\n' +
        (policyRoots == null
            ? 'try { & {\n${WindowsBrowserBypassCloserService.buildOwnedHardeningRestoreScript()}\n} } catch { \$ffRestoreFailures += \'browser hardening\' }\n'
                  'try { & {\n${WindowsChromiumRegistryService.instance.buildPacCleanupScript()}\n} } catch { \$ffRestoreFailures += \'primary PAC\' }\n'
            : '') +
        "if (\$ffRestoreFailures.Count -gt 0) { throw ('FocusFense restore incomplete: ' + (\$ffRestoreFailures -join ', ')) }\n";
  }
}
