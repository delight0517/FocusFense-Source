import 'package:shared_preferences/shared_preferences.dart';

/// Autonomous block-test agent — on by default, light cadence.
final class BlockingSelfHealPrefs {
  BlockingSelfHealPrefs._();
  static final BlockingSelfHealPrefs instance = BlockingSelfHealPrefs._();

  static const String _enabledKey = 'blocking_self_heal_enabled_v1';
  static const String _browserProbeKey = 'blocking_self_heal_browser_probe_v1';
  static const String _autoEasySetupKey = 'blocking_auto_easy_setup_v1';
  static const String _zeroTouchKey = 'blocking_zero_touch_handoff_v1';
  // Auto live headless URL test — launches browsers in headless mode to probe
  // URL blocking. Disabled by default: invasive (kills/restarts browser procs),
  // causes IFEO toast storms when blocked browsers are installed.
  // Users can enable from Settings → 도구 → "자동 URL 실측" toggle.
  static const String _autoLiveTestKey = 'blocking_auto_live_test_v1';

  /// Auto close unprotected Chrome/Edge and launch protected — no user steps.
  Future<bool> zeroTouchHandoff() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_zeroTouchKey) ?? true;
  }

  Future<void> setZeroTouchHandoff(bool value) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_zeroTouchKey, value);
  }

  Future<bool> isEnabled() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_enabledKey) ?? true;
  }

  /// Open one test URL in protected Chrome per cycle (when rules exist).
  Future<bool> browserProbeEnabled() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_browserProbeKey) ?? false;
  }

  /// Full 「쉬운 설치」 without wizard when protection missing (default on).
  Future<bool> autoEasySetup() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_autoEasySetupKey) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_enabledKey, value);
  }

  Future<void> setBrowserProbeEnabled(bool value) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_browserProbeKey, value);
  }

  Future<void> setAutoEasySetup(bool value) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_autoEasySetupKey, value);
  }

  /// Whether headless URL leak tests fire automatically (default: OFF).
  Future<bool> autoLiveTestEnabled() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_autoLiveTestKey) ?? false;
  }

  Future<void> setAutoLiveTestEnabled(bool value) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_autoLiveTestKey, value);
  }
}
