import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Windows-only OS integration prefs (Start Menu search, login autostart).
final class WindowsIntegrationPrefs {
  WindowsIntegrationPrefs._();
  static final WindowsIntegrationPrefs instance = WindowsIntegrationPrefs._();

  static const String _autostartOffKey = 'windows_autostart_explicitly_off_v1';
  static String get _offMarkerPath {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker', 'autostart_disabled_v1.json');
  }

  /// User turned autostart OFF in Settings — do not re-enable on boot.
  Future<bool> isAutostartExplicitlyOff() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    if (p.getBool(_autostartOffKey) ?? false) return true;
    return Platform.isWindows && await File(_offMarkerPath).exists();
  }

  Future<void> setAutostartExplicitlyOff(bool off) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_autostartOffKey, off);
    if (!Platform.isWindows) return;
    final File marker = File(_offMarkerPath);
    if (off) {
      await marker.parent.create(recursive: true);
      await marker.writeAsString('{"autostartDisabled":true}', flush: true);
    } else if (await marker.exists()) {
      await marker.delete();
    }
  }
}
