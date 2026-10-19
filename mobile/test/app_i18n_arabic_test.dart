import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/localization/app_i18n.dart';

void main() {
  test('Arabic locale is selectable and every AppI18n key is translated', () {
    expect(
      AppI18n.supportedLocales.any(
        (Locale locale) => locale.languageCode == 'ar',
      ),
      isTrue,
    );
    expect(AppI18n.languageName('ar'), 'العربية');

    const List<String> keys = <String>[
      'tab_home',
      'tab_rules',
      'tab_test',
      'tab_chat',
      'tab_settings',
      'scope_ios',
      'scope_mac',
      'mac_hero_title',
      'mac_hero_on',
      'mac_hero_off',
      'mac_hero_action_on',
      'mac_hero_action_off',
      'mac_hero_action_disable',
      'mac_hero_locked',
      'settings_title',
      'settings_intro',
      'language_title',
      'language_subtitle',
      'mode_title',
      'mode_practice',
      'mode_live',
      'mode_practice_desc',
      'mode_live_desc',
      'advanced_title',
      'advanced_subtitle',
      'apply_rules_sim',
      'apply_rules_live',
      'refresh_path',
      'todo_title_practice',
      'todo_title_live',
    ];

    for (final String key in keys) {
      final String arabic = AppI18n.t(const Locale('ar'), key);
      expect(arabic, isNot(key), reason: 'Missing Arabic value for $key');
      expect(arabic, isNot(AppI18n.t(const Locale('en'), key)), reason: key);
    }
  });
}
