import 'dart:io';

import 'adult_domain_component_store.dart';
import '../models/rules_meta.dart';
import '../utils/host_idn_codec.dart';
import 'app_logger.dart';
import 'firefox_config_service.dart';
import 'local_database.dart';
import 'usage_quota_enforcer_service.dart';
import '../utils/numeric_suffix_evasion.dart';
import 'youtube_enforcement_hosts.dart';

/// Mac-only system-wide blocker that edits `/etc/hosts` so DNS lookups for
/// blocked hostnames return 0.0.0.0. Works across Safari, Chrome, Firefox,
/// and any app using the system DNS resolver.
///
/// Notes:
/// * Requires admin password (osascript "with administrator privileges").
/// * Block region is bracketed by markers, so unmanaged hosts are preserved.
/// * Adds optional Google forced SafeSearch (hides adult image results).
final class MacSystemBlockService {
  MacSystemBlockService._();
  static final MacSystemBlockService instance = MacSystemBlockService._();

  static const String kMarkerStart = '# === 6 VPN Blocker BEGIN (managed) ===';
  static const String kMarkerEnd = '# === 6 VPN Blocker END (managed) ===';

  /// Public IP of forcesafesearch.google.com (Google publishes this).
  /// Used to make Google force SafeSearch via DNS, like school networks do.
  static const String _kSafeSearchIp = '216.239.38.120';

  static const List<String> _kGoogleHosts = <String>[
    'www.google.com',
    'google.com',
    'www.google.co.kr',
    'google.co.kr',
    'www.google.co.jp',
    'google.co.jp',
    'images.google.com',
    'www.bing.com',
    'duckduckgo.com',
    'www.duckduckgo.com',
  ];

  bool get isSupported => Platform.isMacOS;

  /// Activates (or re-applies) the managed block region in /etc/hosts using
  /// the current domain rules from the local database. Also disables DNS-over-
  /// HTTPS in every Firefox profile we can find — without that, Firefox routes
  /// DNS through Cloudflare/Mozilla and silently bypasses /etc/hosts.
  Future<MacBlockResult> activate({bool enableSafeSearch = true}) async {
    if (!isSupported) {
      return MacBlockResult.unsupported();
    }
    AppLogger.instance.info('activate() called (safeSearch=$enableSafeSearch)');
    // Run Firefox DoH override first so users don't have to re-auth twice.
    // Profile-level user.js is owned by the user — no admin needed; system
    // policies.json goes inside the hosts-write script so it shares the
    // single admin prompt.
    try {
      final List<String> applied = await FirefoxConfigService.instance
          .disableDoHInAllProfiles();
      AppLogger.instance.info(
        'Firefox user.js applied to ${applied.length} profile(s)',
      );
    } catch (e, st) {
      AppLogger.instance.warn('Firefox user.js step failed', error: e);
      AppLogger.instance.log('DEBUG', 'firefox user.js stack', stack: st);
    }
    final List<String> hosts = await _collectEnabledHosts();
    AppLogger.instance.info(
      'collected ${hosts.length} host entries for /etc/hosts block',
    );
    final String block = _buildBlockSection(
      hosts: hosts,
      enableSafeSearch: enableSafeSearch,
    );
    final MacBlockResult r = await _writeHostsWithBlock(block);
    AppLogger.instance.info(
      'activate() result: ${r.status.name} — ${r.message ?? ""}',
    );
    return r;
  }

  /// Same managed region text that would be written to a hosts file
  /// (markers + `0.0.0.0` lines). Safe to call on **any** OS — only reads DB.
  Future<String> buildManagedHostsRegion({bool enableSafeSearch = true}) async {
    final List<String> hosts = await _collectEnabledHosts();
    return _buildBlockSection(hosts: hosts, enableSafeSearch: enableSafeSearch);
  }

  /// Expanded host list for DNS sinkhole / diagnostics (same as hosts apply).
  Future<List<String>> enabledHostsExpanded() => _collectEnabledHosts();

  /// Removes the managed block region from /etc/hosts, leaving the rest intact.
  Future<MacBlockResult> deactivate() async {
    if (!isSupported) {
      return MacBlockResult.unsupported();
    }
    return _writeHostsWithBlock('');
  }

  /// Reads /etc/hosts and returns true if our managed block region is present.
  Future<bool> isActive() async {
    if (!isSupported) return false;
    try {
      final String contents = await File('/etc/hosts').readAsString();
      return contents.contains(kMarkerStart) && contents.contains(kMarkerEnd);
    } catch (_) {
      return false;
    }
  }

  /// TLDs we expand stem-mode hosts into. Curated for the rotating-domain
  /// pattern (`name1.com`, `name2.com`, `name.net`, `name.xyz`, …). Not a
  /// substitute for a real DNS resolver, but catches the most common bypass
  /// trick (numeric suffix on a known stem) with no extra plumbing.
  static const List<String> _kStemTlds = <String>[
    'com',
    'net',
    'org',
    'xyz',
    'top',
    'live',
    'tv',
    'cc',
    'site',
    'online',
    'pro',
    'co',
    'me',
    'io',
    'fun',
    'sex',
    'porn',
    'adult',
    'xxx',
  ];

  /// Numeric suffixes we expand for each stem. Keeps the list size in check
  /// while covering the most common rotation pattern (`stem1`, `stem2`, …).
  static List<String> _stemNumericSuffixes() {
    return List<String>.generate(50, (int i) => (i + 1).toString());
  }

  /// Common subdomain prefixes that get auto-added for any non-stem domain.
  /// This is the "self wildcard" behaviour the user expects: typing
  /// `naver.com` should block `www.naver.com`, `m.naver.com`, `news.naver.com`,
  /// etc. without having to enumerate each one. `/etc/hosts` has no real
  /// wildcards, so we expand to the most common prefixes.
  static const List<String> _kCommonSubdomains = <String>[
    'www',
    'm',
    'mobile',
    'wap',
    'news',
    'mail',
    'blog',
    'cafe',
    'shop',
    'shopping',
    'store',
    'login',
    'auth',
    'account',
    'accounts',
    'sso',
    'api',
    'apis',
    'cdn',
    'static',
    'assets',
    'image',
    'images',
    'img',
    'video',
    'videos',
    'media',
    'search',
    'find',
    'go',
    'tv',
    'music',
    'play',
    'live',
    'app',
    'apps',
    'mobile-app',
    'forum',
    'community',
    'help',
    'support',
    'dict',
    'kin',
    'weather',
    'finance',
    'sports',
    'comic',
    'comics',
    'photo',
    'photos',
    'pay',
    'wallet',
    'm-en',
    'en',
    'kr',
    'jp',
  ];

  /// Normalises an input host so it's a canonical domain. Strips scheme,
  /// path, leading dots, and a redundant leading `www.` (so the user can
  /// type either `naver.com` or `www.naver.com` and get the same result).
  static String canonicalHost(String input) {
    String h = input.trim().toLowerCase();
    h = h.replaceFirst(RegExp('^https?://'), '');
    h = h.split('/').first;
    // `https://example.com:443/` → host must not keep `:443` (invalid in hosts).
    h = h.replaceFirst(RegExp(r':\d+$'), '');
    h = h.replaceFirst(RegExp(r'^\.+'), '');
    // Strip leading `www.` only if at least one more label remains
    // (so `www.com` itself is left alone — unlikely real case).
    if (h.startsWith('www.') && h.split('.').length >= 3) {
      h = h.substring(4);
    }
    // Internationalized domains (e.g. 링크다모아.com) → punycode for hosts/PAC.
    if (h.isNotEmpty) {
      h = HostIdnCodec.toAsciiHost(h);
    }
    // DNS treats a final dot as the root label. Keep policy keys and PAC
    // comparisons identical for `example.com` and `example.com.`.
    h = h.replaceFirst(RegExp(r'\.$'), '');
    return h;
  }

  /// Extra **locale / regional** first labels (`ko.*`, `de.*`, …) used by many
  /// global sites for country mirrors. `hosts` has no wildcards — without
  /// these, blocking `example.com` misses `ko.example.com`.
  static const List<String> _kLocaleSubdomains = <String>[
    'ko',
    'de',
    'fr',
    'es',
    'ja',
    'zh',
    'ru',
    'pt',
    'it',
    'nl',
    'pl',
    'tr',
    'th',
    'vi',
    'ar',
    'hi',
    'cs',
    'da',
    'sv',
    'fi',
    'no',
    'ro',
    'hu',
    'bg',
    'sk',
    'sl',
    'et',
    'lv',
    'lt',
    'uk',
    'id',
    'ms',
    'he',
    'ca',
    'tw',
    'hk',
    'sg',
    'mx',
    'br',
    'cl',
    'co',
    'pe',
    'ae',
    'sa',
    'gr',
    'eu',
    'global',
    'intl',
    'ww',
    'world',
  ];

  /// Smaller expansion for Windows `hosts` (UAC write must stay fast/small).
  /// Always blocks apex + www + common mobile prefixes; IPv6 line is added in
  /// [_buildBlockSection].
  static Set<String> expandCompactForHosts(String canonical) {
    return <String>{
      canonical,
      'www.$canonical',
      'm.$canonical',
      'mobile.$canonical',
    };
  }

  /// Expand a canonical host into bare + every common subdomain prefix.
  /// Caller is responsible for canonicalising first.
  static Set<String> expandWithCommonSubdomains(String canonical) {
    final Set<String> out = <String>{canonical};
    for (final String s in _kCommonSubdomains) {
      out.add('$s.$canonical');
    }
    for (final String s in _kLocaleSubdomains) {
      out.add('$s.$canonical');
    }
    return out;
  }

  /// Pin concrete numeric-apex hosts (`mingky01.live`) so they always land in
  /// the managed `hosts` region even when bulk stem expansion order changes.
  static void pinPriorityNumericApexHosts(
    Set<String> hosts,
    Iterable<String> stems, {
    int maxPerStem = 24,
  }) {
    for (final String stem in stems) {
      for (final String h in NumericSuffixEvasion.priorityConcreteApexForStem(
        stem,
        maxHosts: maxPerStem,
      )) {
        final String c = canonicalHost(h);
        if (c.isEmpty) continue;
        if (Platform.isWindows) {
          hosts.addAll(expandCompactForHosts(c));
        } else {
          hosts.addAll(expandWithCommonSubdomains(c));
        }
      }
    }
  }

  Future<List<String>> _collectEnabledHosts() async {
    // Only blocks what's active right now: always-on rules + rules belonging
    // to a schedule that's currently within its window. Outside its window,
    // a schedule's rules go silent — so users get a real time-bound experience
    // instead of "always-on perfection".
    final List<Map<String, Object?>> rows = await LocalDatabase.instance
        .domainsActiveNow(DateTime.now());
    final Set<String> hosts = <String>{};
    final List<String> numericStems = <String>[];
    final List<String> explicitDomainHosts = <String>[];
    bool explicitYoutubeSite = false;
    for (final Map<String, Object?> row in rows) {
      if ((row['enabled'] as int? ?? 0) != 1) continue;
      final String? host = row['host'] as String?;
      if (host == null) continue;
      final String canonical = canonicalHost(host);
      if (canonical.isEmpty) continue;
      if (canonical == 'youtube.com' || canonical == 'youtu.be') {
        explicitYoutubeSite = true;
      }
      final bool isStem = (row['is_stem'] as int? ?? 0) == 1;
      if (isStem) {
        numericStems.add(canonical);
        hosts.addAll(
          Platform.isWindows
              ? _expandStemCompact(canonical)
              : _expandStem(canonical),
        );
      } else {
        explicitDomainHosts.add(canonical);
        final bool sub = (row['include_subdomains'] as int? ?? 1) == 1;
        if (sub) {
          hosts.addAll(
            Platform.isWindows
                ? expandCompactForHosts(canonical)
                : expandWithCommonSubdomains(canonical),
          );
        } else {
          hosts.add(canonical);
        }
      }
    }
    try {
      final List<String> quotaHosts = await UsageQuotaEnforcerService.instance
          .quotaLockedHostsExpanded();
      for (final String h in quotaHosts) {
        if (h.contains('youtube') || h.contains('youtu.be')) {
          explicitYoutubeSite = true;
        }
      }
      hosts.addAll(quotaHosts);
    } catch (e) {
      AppLogger.instance.warn('quota hosts merge failed: $e');
    }
    if (numericStems.isNotEmpty) {
      pinPriorityNumericApexHosts(hosts, numericStems);
    }
    if (Platform.isWindows) {
      for (final String parent in explicitDomainHosts) {
        final bool hasExplicitChild = explicitDomainHosts.any(
          (String other) => other != parent && other.endsWith('.$parent'),
        );
        if (!hasExplicitChild) continue;
        for (int i = 1; i <= 99; i++) {
          hosts.addAll(expandCompactForHosts('$i.$parent'));
        }
      }
      final RulesMeta meta = await LocalDatabase.instance.rulesMeta();
      if (meta.adultSitesBlocked) {
        pinPriorityNumericApexHosts(
          hosts,
          (await AdultDomainComponentStore.instance.read()).numericStems
              .toList(),
          maxPerStem: 24,
        );
      }
    }
    if (Platform.isWindows && !explicitYoutubeSite) {
      YoutubeEnforcementHosts.removeYoutubeSiteApex(hosts);
    }
    if (Platform.isWindows) {
      try {
        hosts.addAll(
          YoutubeEnforcementHosts.expandedBuiltinDomainsForWindowsHosts(
            includeAdult:
                (await LocalDatabase.instance.rulesMeta()).adultSitesBlocked,
            adultDomains:
                (await AdultDomainComponentStore.instance.read()).domains,
          ),
        );
      } catch (e) {
        AppLogger.instance.warn('builtin hosts merge failed: $e');
      }
      // @incident: Aside YouTube overblock — channel/video rules must not
      // sinkhole shared CDN hosts; that disables playback for every video.
    }
    final List<String> sorted = hosts.toList()..sort();
    return sorted;
  }

  /// Expand a stem like "porn" into many concrete hosts to catch rotating
  /// domains (`porn1.com`, `porn2.com`, `porn.net`, `1porn.com`, …).
  /// Returns roughly TLD_count × (1 + 2*suffix_count) entries per stem.
  /// Windows hosts: top TLDs only (full [_expandStem] is 10k+ lines).
  Set<String> _expandStemCompact(String stem) {
    return NumericSuffixEvasion.expandedHostsForStem(stem, maxHosts: 200);
  }

  Set<String> _expandStem(String stem) {
    final String s = stem.replaceAll(RegExp(r'[^a-z0-9-]'), '');
    if (s.isEmpty) return <String>{};
    final Set<String> out = <String>{};
    final List<String> suffixes = _stemNumericSuffixes();
    for (final String tld in _kStemTlds) {
      out.add('$s.$tld');
      out.add('www.$s.$tld');
      for (final String n in suffixes) {
        out.add('$s$n.$tld');
        out.add('www.$s$n.$tld');
        out.add('$n$s.$tld');
      }
    }
    return out;
  }

  String _buildBlockSection({
    required List<String> hosts,
    required bool enableSafeSearch,
  }) {
    if (hosts.isEmpty && !enableSafeSearch) return '';
    final StringBuffer sb = StringBuffer();
    sb.writeln(kMarkerStart);
    sb.writeln('# Managed by 6 VPN Blocker. Edit only via the app.');
    for (final String h in hosts) {
      sb.writeln('0.0.0.0 $h');
      // Many sites (e.g. Cloudflare) publish AAAA; browsers often prefer IPv6.
      // IPv4-only `0.0.0.0` lines are then skipped and public DNS still answers.
      sb.writeln(':: $h');
    }
    if (enableSafeSearch) {
      sb.writeln('# Forced Google/Bing SafeSearch via DNS');
      for (final String g in _kGoogleHosts) {
        sb.writeln('$_kSafeSearchIp $g');
      }
    }
    sb.write(kMarkerEnd);
    return sb.toString();
  }

  /// Replaces the managed region inside /etc/hosts with [block] (which may be
  /// empty to remove the region entirely), via an admin-elevated shell script.
  Future<MacBlockResult> _writeHostsWithBlock(String block) async {
    try {
      final Directory tmpDir = Directory.systemTemp;
      final File payload = File('${tmpDir.path}/sixvpn_hosts_block.txt');
      await payload.writeAsString(block);

      const String shell = r'''
set -e
ORIG=/etc/hosts
BAK=/etc/hosts.6vpn_backup
PAYLOAD="$1"
echo "[6vpn] starting /etc/hosts apply" 1>&2
if [ ! -f "$BAK" ]; then
  cp "$ORIG" "$BAK"
  echo "[6vpn] saved backup to $BAK" 1>&2
fi
CLEAN=$(mktemp)
awk 'BEGIN{skip=0} /# === 6 VPN Blocker BEGIN \(managed\) ===/{skip=1; next} /# === 6 VPN Blocker END \(managed\) ===/{skip=0; next} !skip' "$ORIG" > "$CLEAN"
sed -e :a -e '/^$/N;/\n$/ba' -e 's/\n\{2,\}$/\n/' "$CLEAN" > "$CLEAN.trim"
mv "$CLEAN.trim" "$CLEAN"
if [ -s "$PAYLOAD" ]; then
  printf "\n" >> "$CLEAN"
  cat "$PAYLOAD" >> "$CLEAN"
  printf "\n" >> "$CLEAN"
fi
cp "$CLEAN" "$ORIG"
chmod 644 "$ORIG"
rm -f "$CLEAN"
echo "[6vpn] /etc/hosts written" 1>&2
dscacheutil -flushcache >/dev/null 2>&1 || true
killall -HUP mDNSResponder >/dev/null 2>&1 || true
echo "[6vpn] DNS cache flushed" 1>&2

# Firefox enterprise policy: best-effort only. On modern macOS, writing
# inside another app's signed .app bundle is blocked (Operation not
# permitted) even with admin. We try two locations:
#   1. System-wide /Library/Application Support/Mozilla/ (always writable
#      with admin — preferred, survives Firefox updates)
#   2. Inside Firefox.app/Contents/Resources/distribution/ (legacy path,
#      blocked on signed installs — we attempt anyway in case it's a
#      dev/unsigned build)
# Failure here MUST NOT abort the script — /etc/hosts is already in.
set +e
FF_POLICY_JSON='{
  "policies": {
    "DNSOverHTTPS": {
      "Enabled": false,
      "Locked": true
    },
    "NetworkPrediction": false
  }
}'

# Preferred: system-wide Mozilla policies directory. Firefox reads this on
# macOS as of recent versions and we own this path with admin.
SYS_DIR="/Library/Application Support/Mozilla/distribution"
mkdir -p "$SYS_DIR" 2>/dev/null
if [ -d "$SYS_DIR" ]; then
  printf "%s\n" "$FF_POLICY_JSON" > "$SYS_DIR/policies.json" 2>/dev/null \
    && chmod 644 "$SYS_DIR/policies.json" 2>/dev/null \
    && echo "[6vpn] firefox system policy installed at $SYS_DIR" 1>&2 \
    || echo "[6vpn] firefox system policy write failed (non-fatal)" 1>&2
fi

# Legacy: inside the .app bundle. Expected to fail on signed builds.
for FFAPP in "/Applications/Firefox.app" "/Applications/Firefox Developer Edition.app" "/Applications/Firefox Nightly.app"; do
  if [ -d "$FFAPP" ]; then
    DISTDIR="$FFAPP/Contents/Resources/distribution"
    if mkdir -p "$DISTDIR" 2>/dev/null; then
      printf "%s\n" "$FF_POLICY_JSON" > "$DISTDIR/policies.json" 2>/dev/null \
        && chmod 644 "$DISTDIR/policies.json" 2>/dev/null \
        && echo "[6vpn] firefox bundle policy installed in $FFAPP" 1>&2
    else
      echo "[6vpn] firefox bundle policy skipped (SIP-protected): $FFAPP" 1>&2
    fi
  fi
done
set -e
echo OK
''';

      final File scriptFile = File('${tmpDir.path}/sixvpn_apply_hosts.sh');
      await scriptFile.writeAsString(shell);
      await Process.run('chmod', <String>['+x', scriptFile.path]);

      final String inner =
          '/bin/bash ${_q(scriptFile.path)} ${_q(payload.path)}';
      final String osa =
          'do shell script ${_q(inner)} with administrator privileges';
      final ProcessResult result = await Process.run('osascript', <String>[
        '-e',
        osa,
      ]);
      final String outStr = (result.stdout?.toString() ?? '').trim();
      final String errStr = (result.stderr?.toString() ?? '').trim();
      if (outStr.isNotEmpty) {
        AppLogger.instance.info('osascript stdout: $outStr');
      }
      if (errStr.isNotEmpty) {
        AppLogger.instance.info('osascript stderr: $errStr');
      }
      if (result.exitCode == 0) {
        return MacBlockResult.success(stdout: outStr);
      }
      if (errStr.contains('User canceled') || errStr.contains('-128')) {
        return MacBlockResult.cancelled();
      }
      AppLogger.instance.error(
        'osascript failed (exit ${result.exitCode}): $errStr',
      );
      return MacBlockResult.failure(
        errStr.isEmpty ? 'osascript failed' : errStr,
      );
    } catch (e, st) {
      AppLogger.instance.error('activate exception', error: e, stack: st);
      return MacBlockResult.failure(e.toString());
    }
  }

  /// AppleScript single-quoted string (handles embedded quotes).
  String _q(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

class MacBlockResult {
  const MacBlockResult._(this.status, [this.message]);

  factory MacBlockResult.success({String stdout = ''}) =>
      MacBlockResult._(MacBlockStatus.success, stdout);
  factory MacBlockResult.failure(String reason) =>
      MacBlockResult._(MacBlockStatus.failure, reason);
  factory MacBlockResult.cancelled() =>
      MacBlockResult._(MacBlockStatus.cancelled, 'User cancelled');
  factory MacBlockResult.unsupported() =>
      MacBlockResult._(MacBlockStatus.unsupported, 'macOS only');

  final MacBlockStatus status;
  final String? message;

  bool get ok => status == MacBlockStatus.success;
}

enum MacBlockStatus { success, failure, cancelled, unsupported }
