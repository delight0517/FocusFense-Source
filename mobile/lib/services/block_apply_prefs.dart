import 'package:shared_preferences/shared_preferences.dart';

/// When true, DB edits only mark hosts apply as **pending** until the user
/// taps the global 「적용」 control (avoids repeated UAC prompts).
final class BlockApplyPrefs {
  BlockApplyPrefs._();
  static final BlockApplyPrefs instance = BlockApplyPrefs._();

  static const String _deferKey = 'block_defer_hosts_apply_v1';

  Future<bool> deferHostsApply() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getBool(_deferKey) ?? true;
  }

  Future<void> setDeferHostsApply(bool v) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_deferKey, v);
  }
}
