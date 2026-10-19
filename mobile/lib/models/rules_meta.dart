import 'dart:convert';

/// 앱·확장이 공유하는 `rules_v1.json` 상위 정책 (기획안 Step 1 블루프린트).
class RulesMeta {
  const RulesMeta({
    this.strictness = 'standard',
    this.focusEnabled = false,
    this.unlockPinRequired = true,
    this.unlockCooldownSeconds = 60,
    this.forceSafeSearch = true,
    this.adultSitesBlocked = true,
    this.bypassTimeLockMinutes = 0,
  });

  /// `standard` | `strict`
  final String strictness;
  final bool focusEnabled;
  final bool unlockPinRequired;
  final int unlockCooldownSeconds;

  /// Force Google / Bing SafeSearch via DNS + extension (default ON).
  final bool forceSafeSearch;

  /// Adult site preset is enabled for new/default profiles; users may opt out.
  final bool adultSitesBlocked;

  /// After a bypass attempt, lock the schedule for this many minutes (0 = off).
  final int bypassTimeLockMinutes;

  static const RulesMeta defaults = RulesMeta();

  RulesMeta copyWith({
    String? strictness,
    bool? focusEnabled,
    bool? unlockPinRequired,
    int? unlockCooldownSeconds,
    bool? forceSafeSearch,
    bool? adultSitesBlocked,
    int? bypassTimeLockMinutes,
  }) {
    return RulesMeta(
      strictness: strictness ?? this.strictness,
      focusEnabled: focusEnabled ?? this.focusEnabled,
      unlockPinRequired: unlockPinRequired ?? this.unlockPinRequired,
      unlockCooldownSeconds:
          unlockCooldownSeconds ?? this.unlockCooldownSeconds,
      forceSafeSearch: forceSafeSearch ?? this.forceSafeSearch,
      adultSitesBlocked: adultSitesBlocked ?? this.adultSitesBlocked,
      bypassTimeLockMinutes:
          bypassTimeLockMinutes ?? this.bypassTimeLockMinutes,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'strictness': strictness,
    'focusEnabled': focusEnabled,
    'unlockPinRequired': unlockPinRequired,
    'unlockCooldownSeconds': unlockCooldownSeconds,
    'forceSafeSearch': forceSafeSearch,
    'adultSitesBlocked': adultSitesBlocked,
    'bypassTimeLockMinutes': bypassTimeLockMinutes,
  };

  factory RulesMeta.fromJson(Map<String, Object?> json) {
    return RulesMeta(
      strictness: json['strictness'] as String? ?? 'standard',
      focusEnabled: json['focusEnabled'] == true,
      unlockPinRequired: json['unlockPinRequired'] != false,
      unlockCooldownSeconds: _clampCooldown(
        (json['unlockCooldownSeconds'] as num?)?.toInt() ?? 60,
      ),
      forceSafeSearch: json['forceSafeSearch'] != false,
      adultSitesBlocked: json['adultSitesBlocked'] != false,
      bypassTimeLockMinutes:
          ((json['bypassTimeLockMinutes'] as num?)?.toInt() ?? 0).clamp(0, 120),
    );
  }

  String toPrefsJson() => jsonEncode(toJson());

  static int _clampCooldown(int v) {
    if (v < 0) return 0;
    if (v > 86400) return 86400;
    return v;
  }

  static RulesMeta fromPrefsString(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return RulesMeta.fromJson(Map<String, Object?>.from(decoded));
      }
    } catch (_) {}
    return RulesMeta.defaults;
  }
}
