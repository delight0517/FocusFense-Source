import 'adult_domain_component_store.dart';
import '../models/rules_meta.dart';
import '../utils/cold_turkey_rule_parser.dart';
import '../utils/youtube_blocklist_parser.dart';
import 'local_database.dart';
import 'lock_policy_service.dart';
import 'lock_schedule_enforcement.dart';
import 'mac_system_block_service.dart';
import 'browser_youtube_policy_split.dart';
import 'builtin_block_domains.dart';
import 'mandatory_youtube_block_service.dart';
import '../utils/numeric_suffix_evasion.dart';
import 'windows_protection_mode_prefs.dart';
import 'extension_guard_prefs.dart';
import 'youtube_budget_exemption_store.dart';
import 'locale_controller.dart';
import 'browser_performance_prefs.dart';

export 'builtin_block_domains.dart'
    show kDiagnosticBlockSentinelHost, kExtensionBuiltinBlockedDomains;

/// One blocked search phrase for Google/YouTube query parameters.
final class ExtensionSearchQueryRule {
  const ExtensionSearchQueryRule({required this.term, required this.match});

  final String term;
  final String match;

  Map<String, String> toJson() => <String, String>{
    'term': term,
    'match': match,
  };
}

/// Rules payload for browser extensions (`GET /rules`) and policy export.
final class ExtensionKeywordRule {
  const ExtensionKeywordRule({
    required this.pattern,
    required this.match,
    required this.action,
    required this.caseSensitive,
  });
  final String pattern;
  final String match;
  final String action;
  final bool caseSensitive;
  Map<String, Object?> toJson() => <String, Object?>{
    'pattern': pattern,
    'match': match,
    'action': action,
    'caseSensitive': caseSensitive,
  };
}

final class ExtensionRulesPayload {
  const ExtensionRulesPayload({
    required this.blockedDomains,
    required this.keywords,
    required this.searchQueries,
    required this.precisionContentFilter,
    required this.updatedAtMs,
    this.blockedYoutubeHandles = const <String>[],
    this.blockedYoutubeChannelIds = const <String>[],
    this.blockedYoutubeVideoIds = const <String>[],
    this.rawKeywords = const <String>[],
    this.forceSafeSearch = true,
    this.numericStemHosts = const <String>[],
    this.adultNumericStemHosts = const <String>[],
    this.focusLocked = false,
    this.protectionEnabled = true,
    this.keywordRules = const <ExtensionKeywordRule>[],
    this.youtubeBudgetExemptions = const <Map<String, Object?>>[],
    this.locale = 'en',
    this.hideYoutubeResults,
  });

  final List<String> blockedDomains;

  /// Lowercased + expanded keywords — what the browser extension consumes
  /// for case-insensitive in-page matching.
  final List<String> keywords;
  final List<ExtensionSearchQueryRule> searchQueries;
  final bool precisionContentFilter;
  final bool? hideYoutubeResults;
  final int updatedAtMs;

  /// Original-case @handles (no @) for HKCU URLBlocklist patterns where the
  /// query/path component is case-sensitive. Lowercased equivalent lives in
  /// the JS extension's own lowercasing path.
  final List<String> blockedYoutubeHandles;

  /// Original-case UC… channel ids.
  final List<String> blockedYoutubeChannelIds;

  /// 11-char (or longer) YouTube video IDs to block outright — the content
  /// script matches these directly against the current page's `?v=` / shorts
  /// / youtu.be id, so a specific video is blocked even on SPA navigation and
  /// in any browser the extension loads in (Chrome / Edge / Firefox).
  final List<String> blockedYoutubeVideoIds;

  /// Case-preserved versions of the original DB keywords — used by
  /// [ChromiumPolicyService] to extract video IDs without losing case.
  /// URL match patterns are case-sensitive in path/query, so a lowercased
  /// `?v=okv36jq64qm*` never matches YouTube's actual `?v=oKv36JQ64QM`.
  final List<String> rawKeywords;
  final bool forceSafeSearch;

  /// Stem-mode domains (`linkdamoa` — blocks `linkdamoa01.com`, …).
  final List<String> numericStemHosts;

  /// Built-in adult mirror stems; lower priority than user-entered stems in
  /// Chromium's capped URLBlocklist.
  final List<String> adultNumericStemHosts;

  /// True while [LockPolicyService.isEffectivelyLocked] holds — the user's
  /// self-declared lock schedule window is active and no PIN/grace unlock is
  /// in effect. The extension's `youtube_distraction.js` force-applies its
  /// hardcoded strict preset whenever this is true, overriding whatever the
  /// user has toggled in the options page for that duration. This is the
  /// entire point of a lock schedule — see docs on `LockPolicyService`.
  final bool focusLocked;
  final bool protectionEnabled;
  final List<ExtensionKeywordRule> keywordRules;
  final List<Map<String, Object?>> youtubeBudgetExemptions;
  final String locale;

  bool get hasYoutubeChannelBlocks =>
      blockedYoutubeHandles.isNotEmpty || blockedYoutubeChannelIds.isNotEmpty;

  /// Firefox keeps channel/video rules — not site-wide YouTube apex DNS-style block.
  ExtensionRulesPayload copyWithoutYoutubeApex() => _copy(
    domains: BrowserYoutubePolicySplit.withoutYoutubeApexDomains(
      blockedDomains,
    ),
  );

  ExtensionRulesPayload withYoutubeFeedFiltering(bool enabled) =>
      _copy(feedFiltering: precisionContentFilter && enabled);

  ExtensionRulesPayload _copy({List<String>? domains, bool? feedFiltering}) {
    return ExtensionRulesPayload(
      blockedDomains: domains ?? blockedDomains,
      keywords: keywords,
      searchQueries: searchQueries,
      precisionContentFilter: precisionContentFilter,
      updatedAtMs: updatedAtMs,
      blockedYoutubeHandles: blockedYoutubeHandles,
      blockedYoutubeChannelIds: blockedYoutubeChannelIds,
      blockedYoutubeVideoIds: blockedYoutubeVideoIds,
      rawKeywords: rawKeywords,
      forceSafeSearch: forceSafeSearch,
      numericStemHosts: numericStemHosts,
      adultNumericStemHosts: adultNumericStemHosts,
      focusLocked: focusLocked,
      protectionEnabled: protectionEnabled,
      keywordRules: keywordRules,
      youtubeBudgetExemptions: youtubeBudgetExemptions,
      locale: locale,
      hideYoutubeResults: feedFiltering ?? hideYoutubeResults,
    );
  }

  Map<String, Object?> toJson({required int port}) => <String, Object?>{
    'blockedDomains': blockedDomains,
    'keywords': keywords,
    'searchQueries': searchQueries
        .map((ExtensionSearchQueryRule e) => e.toJson())
        .toList(),
    'blockedYoutubeHandles': blockedYoutubeHandles,
    'blockedYoutubeChannelIds': blockedYoutubeChannelIds,
    'blockedYoutubeVideoIds': blockedYoutubeVideoIds,
    'youtubeBudgetExemptions': youtubeBudgetExemptions,
    'focusfenseLocale': locale,
    'precisionContentFilter': precisionContentFilter,
    'hideSerp': precisionContentFilter,
    'hideYoutubeResults': hideYoutubeResults ?? precisionContentFilter,
    'hideYtHomeFeed': hasYoutubeChannelBlocks,
    'hideImagesOnYoutube': false,
    'forceSafeSearch': forceSafeSearch,
    'focusLocked': focusLocked,
    'protectionEnabled': protectionEnabled,
    'keywordRules': keywordRules.map((rule) => rule.toJson()).toList(),
    'updatedAtMs': updatedAtMs,
    'port': port,
  };
}

final class ExtensionRulesBuilder {
  ExtensionRulesBuilder._();

  static String? browserIdFromClient({String? requested, String? userAgent}) {
    if (ExtensionGuardPrefs.managedBrowserIds.contains(requested)) {
      return requested;
    }
    final String ua = (userAgent ?? '').toLowerCase();
    if (ua.contains('aside')) return 'aside';
    if (ua.contains('firefox/')) return 'firefox';
    if (ua.contains('edg/')) return 'edge';
    if (ua.contains('chrome/')) return 'chrome';
    return null;
  }

  static bool runtimeProtectionEnabled({
    String? browserId,
    ExtensionGuardPrefs? preferences,
    bool? protectionEnabledForTesting,
  }) =>
      (protectionEnabledForTesting ??
          !WindowsProtectionModePrefs.isProtectionExplicitlyOff) &&
      !(preferences ?? ExtensionGuardPrefs.instance)
          .isBrowserExplicitlyDisabled(browserId ?? '');

  /// Runtime OFF is separate from configured rules: do not erase the database
  /// or change editor/preview results to make a stopped extension harmless.
  static Future<ExtensionRulesPayload> buildForExtensionRuntime({
    DateTime? at,
    String? browserId,
    ExtensionGuardPrefs? preferences,
    bool? protectionEnabledForTesting,
  }) async {
    if (!runtimeProtectionEnabled(
      browserId: browserId,
      preferences: preferences,
      protectionEnabledForTesting: protectionEnabledForTesting,
    )) {
      return ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>[],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: false,
        forceSafeSearch: false,
        protectionEnabled: false,
        locale: LocaleController.instance.locale.languageCode,
        updatedAtMs: (at ?? DateTime.now()).millisecondsSinceEpoch,
      );
    }
    final ExtensionRulesPayload payload = await buildForBrowserEnforcement(
      at: at,
    );
    if (!runtimeProtectionEnabled(
      browserId: browserId,
      preferences: preferences,
      protectionEnabledForTesting: protectionEnabledForTesting,
    )) {
      return ExtensionRulesPayload(
        blockedDomains: const <String>[],
        keywords: const <String>[],
        searchQueries: const <ExtensionSearchQueryRule>[],
        precisionContentFilter: false,
        forceSafeSearch: false,
        protectionEnabled: false,
        locale: LocaleController.instance.locale.languageCode,
        updatedAtMs: (at ?? DateTime.now()).millisecondsSinceEpoch,
      );
    }
    return browserId == 'firefox'
        ? payload.withYoutubeFeedFiltering(
            await BrowserPerformancePrefs.instance.youtubeFeedFiltering(),
          )
        : payload;
  }

  /// Schedule-aware rules (hosts file, coverage UI, “active now” probes).
  static Future<ExtensionRulesPayload> buildActiveNow({DateTime? at}) async {
    final DateTime now = at ?? DateTime.now();
    final List<Map<String, Object?>> kws = await LocalDatabase.instance
        .keywordsActiveNow(now);
    final List<Map<String, Object?>> doms = await LocalDatabase.instance
        .domainsActiveNow(now);
    final List<Map<String, Object?>> sq = await LocalDatabase.instance
        .searchQueryBlocksActiveNow(now);
    return await _assemblePayload(
      now: now,
      keywordRows: kws,
      domainRows: doms,
      searchQueryRows: sq,
    );
  }

  /// Rules for PAC, HKCU URLBlocklist, and extension snapshot.
  ///
  /// Browser rules use the same active time windows as app blocking. Exporting
  /// all enabled schedules made scheduled websites stay blocked outside hours.
  static Future<ExtensionRulesPayload> buildForBrowserEnforcement({
    DateTime? at,
  }) => buildActiveNow(at: at);

  static Future<ExtensionRulesPayload> _assemblePayload({
    required DateTime now,
    required List<Map<String, Object?>> keywordRows,
    required List<Map<String, Object?>> domainRows,
    required List<Map<String, Object?>> searchQueryRows,
  }) async {
    // Refresh focusEnabled from the lock schedule (trusted-time anchored, see
    // lock_schedule_enforcement.dart) BEFORE reading meta, so a browser poll
    // that lands exactly at the window boundary sees the current state
    // instead of a stale one from the last periodic tick.
    await enforceLockScheduleIfNeeded();
    final RulesMeta meta = await LocalDatabase.instance.rulesMeta();
    final bool focusLocked = await LockPolicyService.instance
        .isEffectivelyLocked(meta);
    final List<String> mandatoryLines = await MandatoryYoutubeBlockService
        .instance
        .patterns();
    final List<String> rawPatterns = <String>[
      ...mandatoryLines,
      ...keywordRows
          .where((Map<String, Object?> r) => (r['enabled'] as int? ?? 0) == 1)
          .map(
            (Map<String, Object?> r) => (r['pattern'] as String? ?? '').trim(),
          )
          .where((String s) => s.isNotEmpty),
    ];

    final List<ExtensionSearchQueryRule> searchQueries = searchQueryRows
        .map(
          (Map<String, Object?> r) => ExtensionSearchQueryRule(
            term: (r['term'] as String? ?? '').trim(),
            match: (r['match'] as String? ?? 'contains').trim(),
          ),
        )
        .where((ExtensionSearchQueryRule r) => r.term.isNotEmpty)
        .toList();

    final Set<String> hosts = <String>{};
    final List<String> stemHosts = <String>[];
    final List<String> adultStemHosts = <String>[];
    for (final String h in kExtensionBuiltinBlockedDomains) {
      final String c = MacSystemBlockService.canonicalHost(h);
      if (c.isNotEmpty) hosts.add(c);
    }
    for (final Map<String, Object?> row in domainRows) {
      if ((row['enabled'] as int? ?? 0) != 1) continue;
      final String? raw = row['host'] as String?;
      if (raw == null) continue;
      final String c = MacSystemBlockService.canonicalHost(raw);
      if (c.isEmpty) continue;
      final bool isStem = (row['is_stem'] as int? ?? 0) == 1;
      if (isStem) {
        stemHosts.add(c);
        for (final String glob in NumericSuffixEvasion.keywordPatternsForStem(
          c,
        )) {
          rawPatterns.add(glob);
        }
      } else {
        hosts.add(c);
      }
    }

    // The default policy enables built-in adult categories. Keep the explicit
    // setting check so users who opt out do not receive those domain rules.
    if (meta.adultSitesBlocked) {
      final adultRules = await AdultDomainComponentStore.instance.read();
      for (final String h in adultRules.domains) {
        final String c = MacSystemBlockService.canonicalHost(h);
        if (c.isNotEmpty) hosts.add(c);
      }
      for (final String stem in adultRules.numericStems) {
        final String s = stem.trim().toLowerCase();
        if (s.isEmpty) continue;
        adultStemHosts.add(s);
        for (final String glob in NumericSuffixEvasion.keywordPatternsForStem(
          s,
        )) {
          rawPatterns.add(glob);
        }
      }
    }

    final List<String> blockedDomains = hosts.toList()..sort();
    final List<String> keywords = _expandKeywordsForExtension(rawPatterns);
    final bool precision = keywords.isNotEmpty || searchQueries.isNotEmpty;
    // Extract YT metadata from `rawPatterns` (case preserved), NOT from the
    // already-lowercased `keywords`. Match patterns are case-sensitive for
    // the path/query component, so the HKCU URLBlocklist needs the actual
    // case YouTube serves (`@SC2HL`, `v=oKv36JQ64QM`, …).
    // Mandatory lines lead URLBlocklist + extension snapshot so they never
    // fall off the 1000-entry Chrome/Edge cap behind DB bulk.
    final _YoutubeBlockMeta ytMeta = _mergeYoutubeMeta(
      _extractYoutubeBlockMeta(mandatoryLines),
      _mergeYoutubeMeta(
        _extractYoutubeBlockMeta(rawPatterns),
        _extractYoutubeBlockMeta(keywords),
      ),
    );
    return ExtensionRulesPayload(
      blockedDomains: blockedDomains,
      keywords: keywords,
      rawKeywords: rawPatterns,
      keywordRules: keywordRows
          .where((row) => (row['enabled'] as int? ?? 0) == 1)
          .map(
            (row) => ExtensionKeywordRule(
              pattern: (row['pattern'] as String? ?? '').trim(),
              match: row['match_type'] as String? ?? 'contains',
              action: row['action'] as String? ?? 'redact',
              caseSensitive: (row['case_sensitive'] as int? ?? 0) == 1,
            ),
          )
          .where((rule) => rule.pattern.isNotEmpty)
          .toList(),
      searchQueries: searchQueries,
      precisionContentFilter: precision,
      updatedAtMs: now.millisecondsSinceEpoch,
      blockedYoutubeHandles: ytMeta.handles,
      blockedYoutubeChannelIds: ytMeta.channelIds,
      blockedYoutubeVideoIds: ytMeta.videoIds,
      youtubeBudgetExemptions: await YoutubeBudgetExemptionStore.instance
          .listEntries(),
      locale: LocaleController.instance.locale.languageCode,
      forceSafeSearch: meta.forceSafeSearch,
      numericStemHosts: stemHosts,
      adultNumericStemHosts: adultStemHosts,
      focusLocked: focusLocked,
    );
  }

  /// Expands `@handle` / `youtube.com/@handle` into every pattern the extension expects.
  static List<String> _expandKeywordsForExtension(List<String> raw) {
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];

    void add(String pattern) {
      final String p = pattern.trim().toLowerCase();
      if (p.isEmpty || !seen.add(p)) return;
      out.add(p);
    }

    for (final String line in raw) {
      add(line);
      YouTubeBlocklistBatch batch = parseYouTubeBlocklistLines(<String>[line]);
      if (batch.rules.isEmpty) {
        final String t = line.trim();
        if (t.startsWith('@')) {
          batch = parseYouTubeBlocklistLines(<String>['youtube.com/$t']);
        } else if (t.contains('youtube.com') || t.contains('youtu.be')) {
          final String normalized = t.startsWith('http') ? t : 'https://$t';
          batch = parseYouTubeBlocklistLines(<String>[normalized]);
        }
      }
      for (final ColdTurkeyParsedRule r in batch.rules) {
        final String? kp = r.keywordPattern;
        if (kp != null) add(kp);
      }
    }
    return out;
  }

  static String _safeUriDecode(String segment) {
    try {
      return Uri.decodeComponent(segment);
    } catch (_) {
      return segment;
    }
  }

  static _YoutubeBlockMeta _extractYoutubeBlockMeta(List<String> keywords) {
    final Set<String> handles = <String>{};
    final Set<String> channelIds = <String>{};
    final Set<String> videoIds = <String>{};
    // Match the URL/path patterns case-insensitively, but PRESERVE the original
    // case of the handle/channel id we capture. Match patterns
    // (Chrome/Edge/Firefox enterprise WebsiteFilter) are **case-sensitive for
    // the path** — so lowercasing `@SC2HL` to `@sc2hl` here used to silently
    // make the HKCU pattern fail to match `https://www.youtube.com/@SC2HL`.
    for (final String raw in keywords) {
      final String k = raw.trim();
      if (k.isEmpty) continue;

      // Video IDs first — a watch/shorts/youtu.be URL is the single most common
      // "block this exact video" case. Capture the 11-char id (case preserved).
      RegExpMatch? vm = RegExp(
        r'[?&]v=([\w-]{6,})',
        caseSensitive: false,
      ).firstMatch(k);
      vm ??= RegExp(
        r'youtu\.be/([\w-]{6,})',
        caseSensitive: false,
      ).firstMatch(k);
      vm ??= RegExp(r'/shorts/([\w-]{6,})', caseSensitive: false).firstMatch(k);
      vm ??= RegExp(r'/embed/([\w-]{6,})', caseSensitive: false).firstMatch(k);
      if (vm != null) {
        videoIds.add(vm.group(1)!);
        // A watch URL can also carry a channel ref, but the video id is the
        // primary signal — keep scanning the other patterns below too.
      }

      RegExpMatch? m = RegExp(
        r'youtube\.com/@([^/?#\s]+)',
        caseSensitive: false,
      ).firstMatch(k);
      if (m != null) {
        handles.add(_safeUriDecode(m.group(1)!));
        continue;
      }
      m = RegExp(
        r'youtube\.com/c/([^/?#\s]+)',
        caseSensitive: false,
      ).firstMatch(k);
      if (m != null) {
        handles.add(_safeUriDecode(m.group(1)!));
        continue;
      }
      m = RegExp(
        r'youtube\.com/channel/([^/?#\s]+)',
        caseSensitive: false,
      ).firstMatch(k);
      if (m != null) {
        channelIds.add(m.group(1)!);
        continue;
      }
      if (k.startsWith('@') && !k.contains('/')) {
        handles.add(_safeUriDecode(k.substring(1)));
        continue;
      }
      // Legacy vanity: youtube.com/뷰티풀너드 (no @/c/channel prefix)
      m = RegExp(
        r'youtube\.com/([^/?#\s@]+)',
        caseSensitive: false,
      ).firstMatch(k);
      if (m != null) {
        final String slug = _safeUriDecode(m.group(1)!);
        const Set<String> reserved = <String>{
          'watch',
          'shorts',
          'feed',
          'results',
          'playlist',
          'gaming',
          'premium',
          'account',
          'channel',
          'c',
          'user',
          'post',
          'live',
        };
        if (slug.isNotEmpty && !reserved.contains(slug.toLowerCase())) {
          handles.add(slug);
        }
      }
    }
    // PRESERVE INSERTION ORDER (no `..sort()`). The caller feeds keywords in
    // `created_at DESC` order (newest first — see LocalDatabase.keywordsActiveNow).
    // When the downstream URLBlocklist 1000-entry cap clips the tail, we want
    // the user's most-recently-added blocks to survive — NOT the alphabetically
    // earliest. The user kept reporting "I added this video but it's not
    // blocked" because the alphabetical sort pushed late-letter video IDs
    // (e.g. `wCrc7vy_Tmk`) to the end of the list and they fell off the cap.
    // Dart Set is insertion-ordered by default (LinkedHashSet), so dropping
    // the sort preserves DB DESC order automatically.
    final List<String> orderedHandles = handles
        .map((String h) => _safeUriDecode(h.trim()))
        .where((String h) => h.isNotEmpty)
        .toSet()
        .toList();
    final List<String> orderedIds = channelIds.toList();
    final List<String> orderedVideoIds = videoIds.toList();
    return _YoutubeBlockMeta(
      handles: orderedHandles,
      channelIds: orderedIds,
      videoIds: orderedVideoIds,
    );
  }
}

final class _YoutubeBlockMeta {
  const _YoutubeBlockMeta({
    required this.handles,
    required this.channelIds,
    required this.videoIds,
  });

  final List<String> handles;
  final List<String> channelIds;
  final List<String> videoIds;
}

_YoutubeBlockMeta _mergeYoutubeMeta(_YoutubeBlockMeta a, _YoutubeBlockMeta b) {
  List<String> mergeOrdered(List<String> first, List<String> second) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final String item in <String>[...first, ...second]) {
      final String t = item.trim();
      if (t.isEmpty || !seen.add(t)) continue;
      out.add(t);
    }
    return out;
  }

  return _YoutubeBlockMeta(
    handles: mergeOrdered(a.handles, b.handles),
    channelIds: mergeOrdered(a.channelIds, b.channelIds),
    videoIds: mergeOrdered(a.videoIds, b.videoIds),
  );
}
