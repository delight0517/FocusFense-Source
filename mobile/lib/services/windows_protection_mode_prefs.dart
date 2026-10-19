import 'dart:io';

import 'package:path/path.dart' as p;

/// Persistent Windows protection switch, separate from autostart/recovery.
/// The marker is deliberately checked synchronously by enforcement entry
/// points so a cold start cannot race an async preference load and reapply.
final class WindowsProtectionModePrefs {
  WindowsProtectionModePrefs._();
  static final WindowsProtectionModePrefs instance =
      WindowsProtectionModePrefs._();

  static String get _markerPath {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker', 'protection_disabled_v1.json');
  }

  static bool get isProtectionExplicitlyOff =>
      Platform.isWindows && File(_markerPath).existsSync();

  Future<bool> isProtectionEnabled() async => !isProtectionExplicitlyOff;

  Future<void> setProtectionEnabled(bool enabled) async {
    if (!Platform.isWindows) return;
    final File marker = File(_markerPath);
    if (enabled) {
      if (await marker.exists()) await marker.delete();
      return;
    }
    await marker.parent.create(recursive: true);
    await marker.writeAsString('{"protectionDisabled":true}', flush: true);
  }
}
