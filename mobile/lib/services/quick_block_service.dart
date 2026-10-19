import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/schedule_domain_presets.dart';
import '../models/quick_block_rule_entries.dart';
import '../models/quick_block_user_bundle.dart';
import '../models/rules_meta.dart';
import 'local_database.dart';
import 'lock_policy_service.dart';
import 'mac_system_block_service.dart';
import 'quick_block_controller.dart';
import 'quick_block_prefs_store.dart';

/// Named bundles of hosts added as **global** (`schedule_id` null) domains with
/// `source: quick_block` so they stay separate from 스케줄 규칙 and can be
/// removed with one "해제" action.
final class QuickBlockBundle {
  const QuickBlockBundle({
    required this.id,
    required this.label,
    required this.hosts,
  });

  final String id;
  final String label;
  final List<String> hosts;
}

abstract final class QuickBlockCatalog {
  static const QuickBlockBundle games = QuickBlockBundle(
    id: 'games',
    label: '게임·채팅',
    hosts: <String>[
      'steampowered.com',
      'steamcommunity.com',
      'store.steampowered.com',
      'epicgames.com',
      'store.epicgames.com',
      'battle.net',
      'riotgames.com',
      'playvalorant.com',
      'discord.com',
      'discordapp.com',
      'discord.gg',
      'twitch.tv',
      'roblox.com',
    ],
  );

  static const QuickBlockBundle media = QuickBlockBundle(
    id: 'media',
    label: '영상·SNS',
    hosts: <String>[
      'youtube.com',
      'youtu.be',
      'netflix.com',
      'disneyplus.com',
      'twitter.com',
      'x.com',
      'instagram.com',
      'facebook.com',
      'tiktok.com',
      'reddit.com',
    ],
  );

  static const List<QuickBlockBundle> all = <QuickBlockBundle>[games, media];

  /// Catalog entries not hidden by the user (for dock + settings).
  static Future<List<QuickBlockBundle>> visibleAll() async {
    final Set<String> hidden =
        await QuickBlockPrefsStore.instance.hiddenCatalogIds();
    return all.where((QuickBlockBundle b) => !hidden.contains(b.id)).toList();
  }

  static QuickBlockBundle? byId(String id) {
    for (final QuickBlockBundle b in all) {
      if (b.id == id) return b;
    }
    return null;
  }
}

abstract final class QuickBlockDockPrefs {
  static const String _kShowGames = 'quick_dock_show_games_v1';
  static const String _kShowMedia = 'quick_dock_show_media_v1';

  static Future<bool> showGames() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_kShowGames) ?? true;
  }

  static Future<bool> showMedia() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_kShowMedia) ?? true;
  }

  static Future<void> setShowGames(bool v) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_kShowGames, v);
  }

  static Future<void> setShowMedia(bool v) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_kShowMedia, v);
  }
}

final class QuickBlockService {
  QuickBlockService._();
  static final QuickBlockService instance = QuickBlockService._();

  final LocalDatabase _db = LocalDatabase.instance;

  String _domainId(String bundleId, String host) {
    final String slug =
        host.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    return 'qb_d_${bundleId}_$slug';
  }

  String _keywordId(String bundleId, String pattern) =>
      'qb_k_${bundleId}_${pattern.hashCode.abs()}';

  /// Domains currently active from quick-block bundles (global only).
  Future<int> activeQuickBlockDomainCount() async {
    final List<Map<String, Object?>> rows = await _db.allDomainsQuickBlock();
    return rows.length;
  }

  /// Built-in preset with optional user-edited domain list.
  Future<QuickBlockBundle> resolvedCatalogBundle(String catalogId) async {
    final QuickBlockBundle? base = QuickBlockCatalog.byId(catalogId);
    if (base == null) {
      throw ArgumentError('unknown catalog id: $catalogId');
    }
    final List<QuickBlockDomainRule>? custom =
        await QuickBlockPrefsStore.instance.catalogDomains(catalogId);
    if (custom != null && custom.isNotEmpty) {
      final List<String> hosts = custom
          .map((QuickBlockDomainRule r) => MacSystemBlockService.canonicalHost(r.host))
          .where((String h) => h.isNotEmpty)
          .toList();
      return QuickBlockBundle(id: base.id, label: base.label, hosts: hosts);
    }
    return base;
  }

  /// Inserts missing hosts from catalog or user bundle [bundleId].
  Future<int> applyBundle(String bundleId) async {
    final QuickBlockBundle? catalog = QuickBlockCatalog.byId(bundleId);
    if (catalog != null) {
      final QuickBlockBundle resolved = await resolvedCatalogBundle(bundleId);
      return _applyHosts(bundleId, resolved.hosts);
    }
    final List<QuickBlockUserBundle> user =
        await QuickBlockPrefsStore.instance.loadBundles();
    for (final QuickBlockUserBundle b in user) {
      if (b.id == bundleId) {
        final int d = await _applyDomainRules(bundleId, b.domains);
        final int k = await _applyKeywordRules(bundleId, b.keywords);
        return d + k;
      }
    }
    return 0;
  }

  /// Adds an existing domain/keyword preset to the always-on quick-block list.
  /// Existing active rules are skipped so applying it repeatedly is safe.
  Future<int> applySchedulePreset(ScheduleDomainPreset preset) async {
    final List<Map<String, Object?>> domains =
        await _db.domainsForSchedule(null);
    final List<Map<String, Object?>> keywords =
        await _db.keywordsForSchedule(null);
    final Set<String> existingDomains = domains
        .map((Map<String, Object?> row) =>
            (row['host'] as String? ?? '').toLowerCase())
        .toSet();
    final Set<String> existingKeywords = keywords
        .map((Map<String, Object?> row) =>
            (row['pattern'] as String? ?? '').toLowerCase())
        .toSet();
    int added = 0;

    Future<void> insertPresetDomain(String rawHost, {bool isStem = false}) async {
      final String host = MacSystemBlockService.canonicalHost(rawHost);
      if (host.isEmpty || !existingDomains.add(host)) return;
      await _db.insertDomain(
        id: _domainId(preset.id, host),
        host: host,
        scheduleId: null,
        source: 'quick_block',
        isStem: isStem,
      );
      added++;
    }

    for (final String host in preset.domains) {
      await insertPresetDomain(host);
    }
    for (final String stem in preset.numericStems) {
      await insertPresetDomain(stem, isStem: true);
    }
    for (final String rawPattern in preset.keywords) {
      final String pattern = rawPattern.trim().toLowerCase();
      if (pattern.isEmpty || !existingKeywords.add(pattern)) continue;
      await _db.insertKeyword(
        id: _keywordId(preset.id, pattern),
        pattern: pattern,
        scheduleId: null,
      );
      added++;
    }

    if (added > 0) QuickBlockController.instance.bump();
    return added;
  }

  Future<int> _applyHosts(String bundleId, List<String> rawHosts) async {
    final List<QuickBlockDomainRule> rules = rawHosts
        .map((String h) => QuickBlockDomainRule(host: MacSystemBlockService.canonicalHost(h)))
        .where((QuickBlockDomainRule r) => r.host.isNotEmpty)
        .toList();
    return _applyDomainRules(bundleId, rules);
  }

  Future<int> _applyDomainRules(
    String bundleId,
    List<QuickBlockDomainRule> rules,
  ) async {
    int added = 0;
    for (final QuickBlockDomainRule rule in rules) {
      final String host = MacSystemBlockService.canonicalHost(rule.host);
      if (host.isEmpty) continue;
      if (await _db.hasActiveDomainHost(host)) continue;
      await _db.insertDomain(
        id: _domainId(bundleId, host),
        host: host,
        scheduleId: null,
        source: 'quick_block',
        isStem: rule.isStem,
      );
      added++;
    }
    QuickBlockController.instance.bump();
    return added;
  }

  Future<int> _applyKeywordRules(
    String bundleId,
    List<QuickBlockKeywordRule> rules,
  ) async {
    int added = 0;
    for (final QuickBlockKeywordRule rule in rules) {
      final String pat = rule.pattern.trim().toLowerCase();
      if (pat.isEmpty) continue;
      if (await _db.hasActiveKeywordPattern(pat)) continue;
      await _db.insertKeyword(
        id: _keywordId(bundleId, pat),
        pattern: pat,
        scheduleId: null,
      );
      added++;
    }
    if (added > 0) {
      QuickBlockController.instance.bump();
    }
    return added;
  }

  Future<QuickBlockUserBundle> saveUserBundle(QuickBlockUserBundle bundle) async {
    final List<QuickBlockUserBundle> all =
        await QuickBlockPrefsStore.instance.loadBundles();
    final int idx = all.indexWhere((QuickBlockUserBundle b) => b.id == bundle.id);
    if (idx >= 0) {
      all[idx] = bundle;
    } else {
      all.add(bundle);
    }
    await QuickBlockPrefsStore.instance.saveBundles(all);
    QuickBlockController.instance.bump();
    return bundle;
  }

  Future<void> deleteUserBundle(String id) async {
    final List<QuickBlockUserBundle> all =
        await QuickBlockPrefsStore.instance.loadBundles();
    all.removeWhere((QuickBlockUserBundle b) => b.id == id);
    await QuickBlockPrefsStore.instance.saveBundles(all);
    QuickBlockController.instance.bump();
  }

  /// Hides a built-in preset from dock/settings (sites list kept for restore).
  Future<void> hideCatalogPreset(String catalogId) async {
    if (QuickBlockCatalog.byId(catalogId) == null) return;
    await QuickBlockPrefsStore.instance.setCatalogHidden(catalogId, true);
    if (catalogId == QuickBlockCatalog.games.id) {
      await QuickBlockDockPrefs.setShowGames(false);
    } else if (catalogId == QuickBlockCatalog.media.id) {
      await QuickBlockDockPrefs.setShowMedia(false);
    }
    QuickBlockController.instance.bump();
  }

  Future<void> restoreCatalogPreset(String catalogId) async {
    if (QuickBlockCatalog.byId(catalogId) == null) return;
    await QuickBlockPrefsStore.instance.setCatalogHidden(catalogId, false);
    if (catalogId == QuickBlockCatalog.games.id) {
      await QuickBlockDockPrefs.setShowGames(true);
    } else if (catalogId == QuickBlockCatalog.media.id) {
      await QuickBlockDockPrefs.setShowMedia(true);
    }
    QuickBlockController.instance.bump();
  }

  static String newUserBundleId() => 'user_${const Uuid().v4().substring(0, 8)}';

  Future<List<QuickBlockUserBundle>> userBundles() =>
      QuickBlockPrefsStore.instance.loadBundles();

  /// Soft-deletes all global domains tagged as quick_block.
  Future<int> clearAllQuickBlocks() async {
    final RulesMeta m = await _db.rulesMeta();
    if (LockPolicyService.instance.isLockedByPolicy(m)) {
      return -1;
    }
    final int domains = await _db.softDeleteQuickBlockGlobalDomains();
    final int keywords = await _db.softDeleteQuickBlockGlobalKeywords();
    QuickBlockController.instance.bump();
    if (domains < 0) return domains;
    return domains + keywords;
  }
}
