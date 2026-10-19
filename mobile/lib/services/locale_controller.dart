import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../localization/app_i18n.dart';

class LocaleController extends ChangeNotifier {
  LocaleController._();
  static final LocaleController instance = LocaleController._();

  static const String _kLocaleCodeKey = 'ui_locale_code_v1';
  Locale _locale = const Locale('en');

  Locale get locale => _locale;

  Future<void> init() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? code = prefs.getString(_kLocaleCodeKey);
    if (code != null && code.isNotEmpty) {
      _locale = Locale(code);
      return;
    }
    final String systemCode = PlatformDispatcher.instance.locale.languageCode;
    if (AppI18n.supportedLocales.any((Locale e) => e.languageCode == systemCode)) {
      _locale = Locale(systemCode);
    }
  }

  Future<void> setLocaleCode(String code) async {
    _locale = Locale(code);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLocaleCodeKey, code);
    notifyListeners();
  }
}
