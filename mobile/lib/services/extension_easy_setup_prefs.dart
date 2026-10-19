import 'package:shared_preferences/shared_preferences.dart';

/// First-run 「쉬운 설치」 wizard completion flag.
final class ExtensionEasySetupPrefs {
  ExtensionEasySetupPrefs._();
  static final ExtensionEasySetupPrefs instance = ExtensionEasySetupPrefs._();

  static const String _completeKey = 'extension_easy_setup_v1_complete';
  static const String _skippedKey = 'extension_easy_setup_v1_skipped';

  Future<bool> isComplete() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_completeKey) ?? false;
  }

  Future<bool> wasSkipped() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_skippedKey) ?? false;
  }

  Future<void> markComplete() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_completeKey, true);
    await p.remove(_skippedKey);
  }

  Future<void> markSkipped() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_skippedKey, true);
  }

  Future<void> clearComplete() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.remove(_completeKey);
  }

  Future<void> reset() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.remove(_completeKey);
    await p.remove(_skippedKey);
  }

  /// Show full-screen wizard on Windows until completed or explicitly skipped once.
  Future<bool> shouldShowWizard() async {
    if (await isComplete()) return false;
    if (await wasSkipped()) return false;
    return true;
  }
}
