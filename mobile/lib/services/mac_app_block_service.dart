import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Bridge to the macOS native [AppBlockBridge] inside MainFlutterWindow.swift.
///
/// What it does:
///   * Push the current "active right now" target list to the native
///     enforcer via [setTargets]. Native side keeps the list in memory and
///     terminates matching apps every 2 s (and on every NSWorkspace launch
///     notification).
///   * Read back diagnostic state for the test screen via [status].
///
/// Why a method channel: keeping the data flow in one direction (Dart → Swift)
/// avoids native-side persistence — DB stays the single source of truth and
/// we just keep the enforcer's in-memory list synced.
final class MacAppBlockService {
  MacAppBlockService._();
  static final MacAppBlockService instance = MacAppBlockService._();

  static const MethodChannel _channel =
      MethodChannel('com.sixvpnblocker.app/app_block');

  Future<void> setTargets(List<String> names) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<Map<Object?, Object?>>(
        'setTargets',
        <String, Object?>{'targets': names},
      );
      AppLogger.instance.info(
          'mac_app_block.setTargets count=${names.length} → $names');
    } on PlatformException catch (e) {
      AppLogger.instance.error('mac_app_block.setTargets failed', error: e);
    } on MissingPluginException catch (e) {
      // Happens when running an older bundle that doesn't yet have the
      // native bridge. Surface in the log instead of crashing.
      AppLogger.instance.warn('mac_app_block bridge missing: $e');
    }
  }

  Future<Map<String, Object?>?> status() async {
    if (!Platform.isMacOS) return null;
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('getStatus');
      if (raw is Map) {
        return raw.map((Object? k, Object? v) =>
            MapEntry<String, Object?>(k.toString(), v));
      }
    } catch (e) {
      AppLogger.instance.warn('mac_app_block.getStatus failed: $e');
    }
    return null;
  }

  /// Force an immediate sweep on the native side — used by the test screen
  /// so the user can verify blocking without waiting up to 2 s for the
  /// monitor timer to tick.
  Future<void> kickNow() async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<bool>('kickNow');
    } catch (_) {/* best-effort diagnostic */}
  }
}
