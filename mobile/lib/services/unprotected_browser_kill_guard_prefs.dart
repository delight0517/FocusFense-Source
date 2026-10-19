import 'package:shared_preferences/shared_preferences.dart';

/// When ON, browsers running without an active URLBlocklist are terminated
/// (prevents adult-site leaks through unprotected Whale/Brave/etc.).
final class UnprotectedBrowserKillGuardPrefs {
  UnprotectedBrowserKillGuardPrefs._();
  static final UnprotectedBrowserKillGuardPrefs instance =
      UnprotectedBrowserKillGuardPrefs._();

  static const String _kEnabled = 'unprotected_browser_kill_guard_v1';

  Future<bool> enabled() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_kEnabled) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, value);
  }
}
