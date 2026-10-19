import 'package:flutter/material.dart';

import 'builtin_adult_apex_domains.dart';
import 'premade_adult_pack_extra.dart';
import 'premade_p_block_website_list.dart';
import 'premade_visible_pack_extra.dart';

/// One-tap domain **bundles** for schedule 「빠른 추가」 chips.
///
/// [id] is the stable bundle identifier persisted on every domain/keyword
/// row it creates (`domains.preset_id` / `keywords.preset_id`) and in
/// `schedule_applied_presets`. Applying a preset is idempotent and its
/// items are managed **as one unit** — see
/// `ScheduleEditScreen._applyPreset` / `_removePresetBundle`. Never rename
/// an existing [id]: it is the join key used to find and remove a bundle's
/// rows later, and a rename would orphan already-applied rows.
final class ScheduleDomainPreset {
  const ScheduleDomainPreset({
    required this.id,
    required this.name,
    required this.hint,
    required this.icon,
    required this.domains,
    this.numericStems = const <String>[],
    this.keywords = const <String>[],
  });

  final String id;
  final String name;
  final String hint;
  final IconData icon;
  final List<String> domains;
  final List<String> numericStems;
  final List<String> keywords;

  int get itemCount => domains.length + numericStems.length + keywords.length;
}

/// Schedule edit screen — domain quick-add presets (single source of truth).
List<ScheduleDomainPreset> scheduleDomainPresets() {
  return <ScheduleDomainPreset>[
    ScheduleDomainPreset(
      id: 'adult_combined',
      name: '성인',
      hint:
          '성인 사이트 ${kBuiltinAdultApexCount + kPremadeAdultExtraHosts.length}개 '
          '+ 채널·게시판·검색어 ${kPremadeAdultExtraKeywords.length}개 '
          '+ 숫자 우회 stem ${kBuiltinAdultNumericStems.length}개',
      icon: Icons.no_adult_content,
      // Additive merge: the original built-in list + the 4VPN premade-pack
      // import (2026-07-01). Nothing from the original list was removed —
      // duplicates across the two sources are already deduped at build time
      // in premade_adult_pack_extra.dart.
      domains: <String>[
        ...kBuiltinAdultApexDomains,
        ...kPremadeAdultExtraHosts,
      ],
      numericStems: kBuiltinAdultNumericStems,
      keywords: kPremadeAdultExtraKeywords,
    ),
    ScheduleDomainPreset(
      id: 'p_block_0501',
      name: 'P 차단 목록',
      hint:
          'Mac P 리스트 ${kPBlockWebsiteDomains.length}개 도메인 + '
          '${kPBlockWebsiteUrlPatterns.length}개 URL/검색 패턴',
      icon: Icons.filter_alt_outlined,
      domains: kPBlockWebsiteDomains,
      keywords: kPBlockWebsiteUrlPatterns,
    ),
    const ScheduleDomainPreset(
      id: 'sns',
      name: 'SNS',
      hint: '인스타·틱톡·X 등',
      icon: Icons.forum_outlined,
      domains: <String>[
        'instagram.com',
        'tiktok.com',
        'twitter.com',
        'x.com',
        'reddit.com',
        'facebook.com',
        'threads.net',
      ],
    ),
    const ScheduleDomainPreset(
      id: 'shopping',
      name: '쇼핑',
      hint: '쿠팡·아마존 등',
      icon: Icons.shopping_bag_outlined,
      domains: <String>[
        'amazon.com',
        'coupang.com',
        'aliexpress.com',
        'temu.com',
        'ebay.com',
      ],
    ),
    ScheduleDomainPreset(
      id: 'gaming_pack_400',
      name: '게임',
      hint:
          '게임 사이트 ${kPremadeGamingHosts.length}개 + YouTube 채널·검색어 ${kPremadeGamingKeywords.length}개',
      icon: Icons.sports_esports_outlined,
      domains: kPremadeGamingHosts,
      keywords: kPremadeGamingKeywords,
    ),
    ScheduleDomainPreset(
      id: 'gambling',
      name: '도박',
      hint:
          '도박·토토·카지노 사이트 ${kPremadeGamblingHosts.length}개 + 키워드 ${kPremadeGamblingKeywords.length}개',
      icon: Icons.casino_outlined,
      domains: kPremadeGamblingHosts,
      keywords: kPremadeGamblingKeywords,
    ),
    ScheduleDomainPreset(
      id: 'illegal_webtoon_sites',
      name: '불법 웹툰/사이트',
      hint:
          '불법 웹툰·사이트 ${kPremadeIllegalSiteHosts.length}개 + 키워드 ${kPremadeIllegalSiteKeywords.length}개',
      icon: Icons.gpp_bad_outlined,
      domains: kPremadeIllegalSiteHosts,
      keywords: kPremadeIllegalSiteKeywords,
    ),
    const ScheduleDomainPreset(
      id: 'finance',
      name: '증권/주식',
      hint: '증권사 HTS 웹·시세 사이트',
      icon: Icons.candlestick_chart_outlined,
      domains: <String>[
        'finance.naver.com',
        'finance.yahoo.com',
        'marketwatch.com',
        'investing.com',
        'tradingview.com',
        'bloomberg.com',
        'cnbc.com',
        'robinhood.com',
        'etrade.com',
        'schwab.com',
        'fidelity.com',
        'webull.com',
        'tossinvest.com',
        'kiwoom.com',
        'koreainvestment.com',
        'nhqv.com',
        'samsungpop.com',
        'shinhaninvest.com',
      ],
    ),
    const ScheduleDomainPreset(
      id: 'news',
      name: '뉴스',
      hint: '자극적 뉴스·커뮤니티',
      icon: Icons.article_outlined,
      domains: <String>[
        'naver.com/news',
        'news.naver.com',
        'cnn.com',
        'foxnews.com',
        'dcinside.com',
        'fmkorea.com',
      ],
    ),
  ];
}

/// Search aliases used by the quick-block input (for example, typing
/// "porn site" finds the existing 성인 preset).
const Map<String, List<String>> _quickBlockPresetAliases =
    <String, List<String>>{
      'adult_combined': <String>[
        '성인',
        '성인 사이트',
        '성인사이트',
        '야동',
        '음란물',
        '음란',
        'porn',
        'pornography',
        'adult',
        'adult content',
        'porn site',
        'porn sites',
        'porn website',
        'porn websites',
        'adult site',
        'adult sites',
      ],
      'p_block_0501': <String>[
        'P 차단 목록',
        'porn',
        'pornography',
        '야동',
        '음란물',
        'p block',
        'p block websites',
        'p list',
        'p-list',
        'porn list',
        'porn block',
        'p blocker',
        'adult block list',
        '야동 리스트',
        '음란물 리스트',
      ],
      'gambling': <String>[
        '도박',
        '도박 사이트',
        '도박사이트',
        '카지노',
        '토토',
        '불법도박',
        'gambling',
        'casino',
        'betting',
        'bet site',
        'gambling site',
        'gambling sites',
      ],
      'gaming_pack_400': <String>[
        '게임',
        '게임 사이트',
        'game',
        'gaming',
        'game site',
        'gaming sites',
      ],
      'sns': <String>['sns', 'social media', 'social sites'],
      'shopping': <String>['쇼핑', '쇼핑 사이트', 'shopping', 'shopping sites'],
      'illegal_webtoon_sites': <String>[
        '불법 웹툰',
        '불법사이트',
        'illegal webtoon',
        'pirated webtoon',
      ],
      'finance': <String>['증권', '주식', '주식 사이트', 'stocks', 'stock sites'],
      'news': <String>['뉴스', '뉴스 사이트', 'news', 'news sites'],
    };

final List<ScheduleDomainPreset> _quickBlockPresetIndex =
    scheduleDomainPresets();

String _normalizePresetQuery(String query) => query
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9가-힣]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// Existing schedule presets that match a quick-block query, ordered with
/// exact matches first. Two-character prefixes are enough for discoverability
/// without suggesting a preset for every single keystroke.
List<ScheduleDomainPreset> matchQuickBlockPresets(String query) {
  final String normalized = _normalizePresetQuery(query);
  if (normalized.isEmpty) return <ScheduleDomainPreset>[];

  final Map<String, int> scores = <String, int>{};
  for (final ScheduleDomainPreset preset in _quickBlockPresetIndex) {
    final List<String> aliases =
        _quickBlockPresetAliases[preset.id] ?? <String>[preset.name];
    for (final String rawAlias in aliases) {
      final String alias = _normalizePresetQuery(rawAlias);
      if (alias == normalized) {
        scores[preset.id] = 0;
        break;
      }
      if (normalized.length >= 2 && alias.startsWith(normalized)) {
        scores.putIfAbsent(preset.id, () => 1);
      }
    }
  }

  return _quickBlockPresetIndex
      .where((ScheduleDomainPreset preset) => scores.containsKey(preset.id))
      .toList()
    ..sort(
      (ScheduleDomainPreset a, ScheduleDomainPreset b) =>
          scores[a.id]!.compareTo(scores[b.id]!),
    );
}

/// A query is treated as a preset command only when it exactly matches an
/// alias. Other free-form input continues through normal URL/keyword detection.
ScheduleDomainPreset? exactQuickBlockPreset(String query) {
  final String normalized = _normalizePresetQuery(query);
  if (normalized.isEmpty) return null;
  for (final ScheduleDomainPreset preset in _quickBlockPresetIndex) {
    final List<String> aliases =
        _quickBlockPresetAliases[preset.id] ?? <String>[preset.name];
    if (aliases.any(
      (String alias) => _normalizePresetQuery(alias) == normalized,
    )) {
      return preset;
    }
  }
  return null;
}
