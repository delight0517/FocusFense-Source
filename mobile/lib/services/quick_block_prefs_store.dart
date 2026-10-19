import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/quick_block_rule_entries.dart';
import '../models/quick_block_user_bundle.dart';

/// User quick-block presets + default duration / cancel-delay preferences.
class QuickBlockPrefsStore {
  QuickBlockPrefsStore._();
  static final QuickBlockPrefsStore instance = QuickBlockPrefsStore._();

  static const String _bundlesKey = 'quick_block_user_bundles_v1';
  static const String _sessionKey = 'quick_block_active_session_v1';
  static const String _testLeaseKey = 'quick_block_test_lease_v1';
  static const String _durationHoursKey = 'quick_block_default_duration_hours';
  static const String _cancelDelayMinKey =
      'quick_block_default_cancel_delay_min';
  static const String _catalogOverridesKey = 'quick_block_catalog_overrides_v1';
  static const String _hiddenCatalogKey = 'quick_block_hidden_catalog_ids_v1';

  static const int kDefaultDurationHours = 1;
  static const int kDefaultCancelDelayMinutes = 5;
  static const int maxDurationHours = 24;
  static const int maxCancelDelayMinutes = 120;

  static String formatBlockHoursLabel(int hours) {
    if (hours <= 0) return '';
    if (hours == 1) return '1시간';
    return '${hours}시간';
  }

  Future<List<QuickBlockUserBundle>> loadBundles() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_bundlesKey);
    if (raw == null || raw.isEmpty) return <QuickBlockUserBundle>[];
    try {
      final List<Object?> list = jsonDecode(raw) as List<Object?>;
      return list
          .whereType<Map>()
          .map(
            (Map m) =>
                QuickBlockUserBundle.fromJson(Map<String, Object?>.from(m)),
          )
          .toList();
    } catch (_) {
      return <QuickBlockUserBundle>[];
    }
  }

  Future<void> saveBundles(List<QuickBlockUserBundle> bundles) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(
      bundles.map((QuickBlockUserBundle b) => b.toJson()).toList(),
    );
    await prefs.setString(_bundlesKey, encoded);
  }

  Future<QuickBlockSession?> loadSession() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Map<String, Object?> map = Map<String, Object?>.from(
        jsonDecode(raw) as Map,
      );
      final QuickBlockSession? session = QuickBlockSession.fromJson(map);
      if (session == null || !session.isActive) {
        await clearSession();
        return null;
      }
      return session;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(QuickBlockSession session) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
  }

  Future<void> clearSession() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
  }

  Future<int?> loadTestLeaseUntilMs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_testLeaseKey);
  }

  Future<void> saveTestLeaseUntilMs(int untilMs) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_testLeaseKey, untilMs);
  }

  Future<void> clearTestLease() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_testLeaseKey);
  }

  Future<int> defaultDurationHours() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_durationHoursKey) ?? kDefaultDurationHours).clamp(
      1,
      maxDurationHours,
    );
  }

  Future<void> setDefaultDurationHours(int hours) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_durationHoursKey, hours.clamp(1, maxDurationHours));
  }

  Future<int> defaultCancelDelayMinutes() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_cancelDelayMinKey) ?? kDefaultCancelDelayMinutes)
        .clamp(0, maxCancelDelayMinutes);
  }

  Future<void> setDefaultCancelDelayMinutes(int minutes) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _cancelDelayMinKey,
      minutes.clamp(0, maxCancelDelayMinutes),
    );
  }

  /// Custom domain lists for built-in presets (`games`, `media`).
  Future<List<QuickBlockDomainRule>?> catalogDomains(String catalogId) async {
    final Map<String, List<QuickBlockDomainRule>> all =
        await _loadCatalogOverrides();
    return all[catalogId];
  }

  Future<void> saveCatalogDomains(
    String catalogId,
    List<QuickBlockDomainRule> domains,
  ) async {
    final Map<String, List<QuickBlockDomainRule>> all =
        await _loadCatalogOverrides();
    all[catalogId] = domains;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Map<String, Object?> encoded = <String, Object?>{};
    for (final MapEntry<String, List<QuickBlockDomainRule>> e in all.entries) {
      encoded[e.key] = e.value
          .map((QuickBlockDomainRule d) => d.toJson())
          .toList();
    }
    await prefs.setString(_catalogOverridesKey, jsonEncode(encoded));
  }

  /// Built-in presets (게임·채팅 / 영상·SNS) the user removed from 「내 퀵 블록」.
  Future<Set<String>> hiddenCatalogIds() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String>? raw = prefs.getStringList(_hiddenCatalogKey);
    if (raw == null || raw.isEmpty) return <String>{};
    return raw.toSet();
  }

  Future<bool> isCatalogHidden(String catalogId) async {
    final Set<String> hidden = await hiddenCatalogIds();
    return hidden.contains(catalogId);
  }

  Future<void> setCatalogHidden(String catalogId, bool hidden) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Set<String> ids = await hiddenCatalogIds();
    if (hidden) {
      ids.add(catalogId);
    } else {
      ids.remove(catalogId);
    }
    await prefs.setStringList(_hiddenCatalogKey, ids.toList());
  }

  Future<void> resetCatalogDomains(String catalogId) async {
    final Map<String, List<QuickBlockDomainRule>> all =
        await _loadCatalogOverrides();
    all.remove(catalogId);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (all.isEmpty) {
      await prefs.remove(_catalogOverridesKey);
      return;
    }
    final Map<String, Object?> encoded = <String, Object?>{};
    for (final MapEntry<String, List<QuickBlockDomainRule>> e in all.entries) {
      encoded[e.key] = e.value
          .map((QuickBlockDomainRule d) => d.toJson())
          .toList();
    }
    await prefs.setString(_catalogOverridesKey, jsonEncode(encoded));
  }

  Future<Map<String, List<QuickBlockDomainRule>>>
  _loadCatalogOverrides() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_catalogOverridesKey);
    if (raw == null || raw.isEmpty)
      return <String, List<QuickBlockDomainRule>>{};
    try {
      final Map<String, Object?> map = Map<String, Object?>.from(
        jsonDecode(raw) as Map,
      );
      final Map<String, List<QuickBlockDomainRule>> out =
          <String, List<QuickBlockDomainRule>>{};
      for (final MapEntry<String, Object?> e in map.entries) {
        if (e.value is! List) continue;
        out[e.key] = (e.value! as List)
            .whereType<Map>()
            .map(
              (Map m) =>
                  QuickBlockDomainRule.fromJson(Map<String, Object?>.from(m)),
            )
            .toList();
      }
      return out;
    } catch (_) {
      return <String, List<QuickBlockDomainRule>>{};
    }
  }
}
