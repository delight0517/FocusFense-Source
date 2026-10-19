import 'package:shared_preferences/shared_preferences.dart';

/// 쉬운 설치 — 레지스트리 막힌 PC용 강화 옵션.
final class EasySetupBulletproofPrefs {
  EasySetupBulletproofPrefs._();
  static final EasySetupBulletproofPrefs instance =
      EasySetupBulletproofPrefs._();

  static const String _hijackKey = 'easy_setup_bullet_hijack_v1';
  static const String _browserWdKey = 'easy_setup_bullet_browser_wd_v1';
  static const String _enterpriseKey = 'easy_setup_bullet_enterprise_v1';
  static const String _realtimeKey = 'easy_setup_bullet_realtime_v1';

  Future<bool> hijackShortcuts() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_hijackKey) ?? true;
  }

  /// Win+검색·직접 exe — 보호 없는 Chrome 감지 후 soft-handoff (기본 켜짐).
  Future<bool> realtimeBrowserGuard() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_realtimeKey) ?? true;
  }

  Future<bool> browserWatchdog() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_browserWdKey) ?? true;
  }

  Future<bool> forceEnterprisePolicies() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_enterpriseKey) ?? true;
  }

  Future<void> setAll({
    required bool hijackShortcuts,
    required bool browserWatchdog,
    required bool forceEnterprisePolicies,
    bool realtimeBrowserGuard = true,
  }) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_hijackKey, hijackShortcuts);
    await p.setBool(_browserWdKey, browserWatchdog);
    await p.setBool(_enterpriseKey, forceEnterprisePolicies);
    await p.setBool(_realtimeKey, realtimeBrowserGuard);
  }
}
